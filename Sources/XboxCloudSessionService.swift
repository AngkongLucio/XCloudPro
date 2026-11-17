import Foundation

struct CloudSessionConfiguration: Decodable {
    let keepAlivePulseInSeconds: Int?
    let serverDetails: ServerDetails

    struct ServerDetails: Decodable {
        let ipAddress: String?
        let port: Int?
        let ipV4Address: String?
        let ipV4Port: Int?
        let ipV6Address: String?
        let ipV6Port: Int?
        let iceExchangePath: String?
        let stunServerAddress: String?
        let srtp: SRTP?

        struct SRTP: Decodable {
            let key: String?
        }
    }
}

enum CloudSessionServiceError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, String)
    case missingSessionID
    case sessionFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The cloud streaming region URL is invalid."
        case .invalidResponse: return "The Xbox cloud service returned an invalid response."
        case .httpStatus(let code, let message): return "Xbox cloud request failed (HTTP \(code)): \(message)"
        case .missingSessionID: return "The Xbox cloud service did not return a session ID."
        case .sessionFailed(let reason): return "Xbox cloud session failed: \(reason)"
        case .timedOut: return "The Xbox cloud session did not become ready in time."
        }
    }
}

/// Native REST lifecycle for Xbox Cloud Gaming sessions.
/// This intentionally targets /sessions/cloud and never the console Remote Play /home path.
/// WebRTC media negotiation/rendering is a separate layer.
@MainActor
final class XboxCloudSessionService {
    private let baseURL: URL
    private let gsToken: String
    private let urlSession: URLSession
    private(set) var activeSessionID: String?

    init(baseURL: URL, gsToken: String, urlSession: URLSession = .shared) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw CloudSessionServiceError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.gsToken = gsToken
        self.urlSession = urlSession
    }

    /// Starts a cloud game by Xbox title ID, waits for provisioning, and returns
    /// the server configuration needed by the native WebRTC transport.
    ///
    /// The device-info header is supplied by the caller so the app does not
    /// silently impersonate a different device profile. The user-token provider
    /// is called only when the service reports ReadyToConnect.
    func startCloudGame(
        titleID: String,
        locale: String = Locale.current.identifier,
        timezoneOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60,
        osName: String,
        deviceInfoHeader: String,
        userTokenProvider: () async throws -> String
    ) async throws -> CloudSessionConfiguration {
        guard !titleID.isEmpty else {
            throw CloudSessionServiceError.invalidResponse
        }

        let payload = StartCloudSessionRequest(
            clientSessionId: "",
            titleId: titleID,
            systemUpdateGroup: "",
            settings: .init(
                nanoVersion: "V3;WebrtcTransport.dll",
                enableTextToSpeech: false,
                highContrast: 0,
                locale: locale,
                useIceConnection: false,
                timezoneOffsetMinutes: timezoneOffsetMinutes,
                sdkType: "web",
                osName: osName
            ),
            serverId: "",
            fallbackRegionNames: []
        )

        var request = makeRequest(path: "v5/sessions/cloud/play", method: "POST")
        request.setValue(deviceInfoHeader, forHTTPHeaderField: "X-MS-Device-Info")
        request.httpBody = try JSONEncoder().encode(payload)

        let started: StartCloudSessionResponse = try await send(request)
        let sessionID = started.sessionPath?
            .split(separator: "/")
            .last
            .map(String.init) ?? started.sessionId
        guard let sessionID, !sessionID.isEmpty else {
            throw CloudSessionServiceError.missingSessionID
        }
        activeSessionID = sessionID

        try await waitUntilProvisioned(
            sessionID: sessionID,
            userTokenProvider: userTokenProvider
        )

        return try await fetchConfiguration(sessionID: sessionID)
    }

    func sendKeepAlive() async throws {
        guard let sessionID = activeSessionID else { return }
        let request = makeRequest(
            path: "v5/sessions/cloud/\(sessionID)/keepalive",
            method: "POST",
            body: Data("{}".utf8)
        )
        let _: EmptyResponse = try await send(request)
    }

    func stopCloudGame() async throws {
        guard let sessionID = activeSessionID else { return }
        defer { activeSessionID = nil }
        let request = makeRequest(
            path: "v5/sessions/cloud/\(sessionID)",
            method: "DELETE"
        )
        let _: EmptyResponse = try await send(request)
    }

    private func waitUntilProvisioned(
        sessionID: String,
        userTokenProvider: () async throws -> String
    ) async throws {
        var didConnectUserToken = false

        for _ in 0..<90 {
            try Task.checkCancellation()
            let request = makeRequest(
                path: "v5/sessions/cloud/\(sessionID)/state",
                method: "GET"
            )
            let state: CloudSessionStateResponse = try await send(request)

            switch state.state {
            case "Provisioned":
                return
            case "Provisioning", "WaitingForResources":
                try await Task.sleep(nanoseconds: 1_000_000_000)
            case "ReadyToConnect":
                if !didConnectUserToken {
                    let userToken = try await userTokenProvider()
                    let body = try JSONEncoder().encode(ConnectCloudSessionRequest(userToken: userToken))
                    let connect = makeRequest(
                        path: "v5/sessions/cloud/\(sessionID)/connect",
                        method: "POST",
                        body: body
                    )
                    let _: EmptyResponse = try await send(connect)
                    didConnectUserToken = true
                } else {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            case "Failed":
                throw CloudSessionServiceError.sessionFailed(
                    state.errorDetails?.message ?? "The service reported a failed session."
                )
            default:
                throw CloudSessionServiceError.sessionFailed(
                    "Unexpected session state: \(state.state)"
                )
            }
        }

        throw CloudSessionServiceError.timedOut
    }

    private func fetchConfiguration(sessionID: String) async throws -> CloudSessionConfiguration {
        let request = makeRequest(
            path: "v5/sessions/cloud/\(sessionID)/configuration",
            method: "GET"
        )
        return try await send(request)
    }

    private func makeRequest(path: String, method: String, body: Data? = nil) -> URLRequest {
        let url = path.split(separator: "/").reduce(baseURL) {
            $0.appendingPathComponent(String($1))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSessionServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error details"
            throw CloudSessionServiceError.httpStatus(http.statusCode, message)
        }
        if T.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudSessionServiceError.invalidResponse
        }
    }
}

private struct StartCloudSessionRequest: Encodable {
    let clientSessionId: String
    let titleId: String
    let systemUpdateGroup: String
    let settings: Settings
    let serverId: String
    let fallbackRegionNames: [String]

    struct Settings: Encodable {
        let nanoVersion: String
        let enableTextToSpeech: Bool
        let highContrast: Int
        let locale: String
        let useIceConnection: Bool
        let timezoneOffsetMinutes: Int
        let sdkType: String
        let osName: String
    }
}

private struct StartCloudSessionResponse: Decodable {
    let sessionPath: String?
    let sessionId: String?
}

private struct CloudSessionStateResponse: Decodable {
    let state: String
    let errorDetails: ErrorDetails?

    struct ErrorDetails: Decodable {
        let code: String?
        let message: String?
    }
}

private struct ConnectCloudSessionRequest: Encodable {
    let userToken: String
}

private struct EmptyResponse: Decodable {
    init() {}
}
