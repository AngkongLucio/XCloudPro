import Foundation

/// Common signaling contract consumed by the native WebRTC transport.
/// Cloud Gaming and Console Remote Play use different Xbox session paths,
/// but share the SDP/ICE exchange shape.
@MainActor
protocol XboxStreamingSessionSignaling: AnyObject {
    func exchangeSDPOffer(_ sdp: String) async throws -> CloudSDPAnswer
    func exchangeLocalICECandidates(_ candidates: [CloudICECandidate]) async throws -> [CloudICECandidate]
}

extension XboxCloudSessionService: XboxStreamingSessionSignaling {}

struct XboxConsoleDevice: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let consoleType: String?
    let powerState: String?

    var displayName: String { name?.isEmpty == false ? name! : (consoleType ?? "Xbox console") }
}

private struct XboxConsoleListResponse: Decodable {
    let result: [XboxConsoleDevice]
}

private struct HomeSessionStartRequest: Encodable {
    let clientSessionId = ""
    let titleId = ""
    let systemUpdateGroup = ""
    let settings = Settings()
    let serverId: String
    let fallbackRegionNames: [String] = []

    struct Settings: Encodable {
        let nanoVersion = "V3;WebrtcTransport.dll"
        let enableTextToSpeech = false
        let highContrast = 0
        let locale = "en-US"
        let useIceConnection = false
        let timezoneOffsetMinutes = TimeZone.current.secondsFromGMT() / 60
        let sdkType = "web"
        let osName = "windows"
    }
}

private struct HomeSessionStartResponse: Decodable {
    let sessionId: String?
    let sessionPath: String?
}

private struct HomeSessionState: Decodable {
    let state: String
    let errorDetails: ErrorDetails?

    struct ErrorDetails: Decodable {
        let message: String?
    }
}

private struct HomeSessionEmptyResponse: Decodable {}

/// Xbox Console Remote Play REST lifecycle.
///
/// Supply the *home-streaming* GS token and the Xbox web token separately.
/// Do not reuse the xCloud catalog token unless the authentication exchange
/// explicitly produced it for the home-streaming relying party.
@MainActor
final class XboxConsoleRemotePlayService: XboxStreamingSessionSignaling {
    private let baseURL: URL
    private let homeGS: String
    private let webAuthorization: String
    private let userHash: String
    private let http: XboxHTTPClient
    private(set) var activeSessionID: String?

    init(
        baseURL: URL,
        homeGSToken: String,
        webToken: String,
        userHash: String,
        urlSession: URLSession = .shared
    ) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              !homeGSToken.isEmpty, !webToken.isEmpty, !userHash.isEmpty else {
            throw CloudSessionServiceError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.homeGS = homeGSToken
        self.webAuthorization = "XBL3.0 x=\(userHash);\(webToken)"
        self.userHash = userHash
        self.http = XboxHTTPClient(session: urlSession)
    }

    /// Lists consoles registered to the signed-in Xbox account.
    func fetchConsoles() async throws -> [XboxConsoleDevice] {
        var components = URLComponents(string: "https://xccs.xboxlive.com/lists/devices")!
        components.queryItems = [
            URLQueryItem(name: "queryCurrentDevice", value: "false"),
            URLQueryItem(name: "includeStorageDevices", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(webAuthorization, forHTTPHeaderField: "Authorization")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("2", forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("XboxApp", forHTTPHeaderField: "x-xbl-client-name")
        request.setValue("UWA", forHTTPHeaderField: "x-xbl-client-type")
        request.setValue("39.39.22001.0", forHTTPHeaderField: "x-xbl-client-version")
        let response: XboxConsoleListResponse = try await send(request)
        return response.result
    }

    /// Starts a home-streaming session for a registered console ID.
    func startConsoleSession(consoleID: String) async throws -> CloudSessionConfiguration {
        guard !consoleID.isEmpty, activeSessionID == nil else {
            throw CloudSessionServiceError.missingSessionID
        }
        let body = try JSONEncoder().encode(HomeSessionStartRequest(serverId: consoleID))
        let request = makeHomeRequest(path: "v5/sessions/home/play", method: "POST", body: body)
        let started: HomeSessionStartResponse = try await send(request)
        let sessionID = started.sessionId ?? started.sessionPath?.split(separator: "/").last.map(String.init)
        guard let sessionID, !sessionID.isEmpty else {
            throw CloudSessionServiceError.missingSessionID
        }
        activeSessionID = sessionID

        do {
            try await waitUntilProvisioned(sessionID)
            return try await send(makeHomeRequest(
                path: "v5/sessions/home/\(sessionID)/configuration",
                method: "GET"
            ))
        } catch {
            try? await stopConsoleSession()
            throw error
        }
    }

    func exchangeSDPOffer(_ sdp: String) async throws -> CloudSDPAnswer {
        guard let sessionID = activeSessionID else {
            throw CloudSessionServiceError.missingSessionID
        }
        let body = try JSONEncoder().encode(HomeSDPOffer(messageType: "offer", sdp: sdp, configuration: .init()))
        let path = "v5/sessions/home/\(sessionID)/sdp"
        _ = try await send(makeHomeRequest(path: path, method: "POST", body: body)) as HomeSessionEmptyResponse
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let envelope: HomeExchangeEnvelope = try? await send(makeHomeRequest(path: path, method: "GET")),
               let raw = envelope.exchangeResponse, let data = raw.data(using: .utf8) {
                guard let answer = try? JSONDecoder().decode(CloudSDPAnswer.self, from: data) else {
                    throw CloudSessionServiceError.invalidResponse
                }
                return answer
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CloudSessionServiceError.timedOut
    }

    func exchangeLocalICECandidates(_ candidates: [CloudICECandidate]) async throws -> [CloudICECandidate] {
        guard let sessionID = activeSessionID else {
            throw CloudSessionServiceError.missingSessionID
        }
        let path = "v5/sessions/home/\(sessionID)/ice"
        let body = try JSONEncoder().encode(HomeICEPost(iceCandidates: candidates))
        _ = try await send(makeHomeRequest(path: path, method: "POST", body: body)) as HomeSessionEmptyResponse
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let envelope: HomeExchangeEnvelope = try? await send(makeHomeRequest(path: path, method: "GET")),
               let raw = envelope.exchangeResponse, let data = raw.data(using: .utf8) {
                if let direct = try? JSONDecoder().decode([CloudICECandidate].self, from: data) { return direct }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let values = object.values
                    let decoded = values.compactMap { value -> CloudICECandidate? in
                        guard let candidateData = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                        return try? JSONDecoder().decode(CloudICECandidate.self, from: candidateData)
                    }
                    if !decoded.isEmpty { return decoded }
                }
                throw CloudSessionServiceError.invalidResponse
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CloudSessionServiceError.timedOut
    }

    func stopConsoleSession() async throws {
        guard let sessionID = activeSessionID else { return }
        _ = try await send(makeHomeRequest(path: "v5/sessions/home/\(sessionID)", method: "DELETE")) as HomeSessionEmptyResponse
        activeSessionID = nil
    }

    private func waitUntilProvisioned(_ sessionID: String) async throws {
        for _ in 0..<90 {
            try Task.checkCancellation()
            let state: HomeSessionState = try await send(makeHomeRequest(
                path: "v5/sessions/home/\(sessionID)/state", method: "GET"
            ))
            switch state.state {
            case "Provisioned": return
            case "Provisioning", "WaitingForResources":
                try await Task.sleep(nanoseconds: 1_000_000_000)
            case "Failed":
                throw CloudSessionServiceError.sessionFailed(
                    state.errorDetails?.message ?? "Xbox console session failed."
                )
            default:
                throw CloudSessionServiceError.sessionFailed("Unexpected console session state: \(state.state)")
            }
        }
        throw CloudSessionServiceError.timedOut
    }

    private func makeHomeRequest(path: String, method: String, body: Data? = nil) -> URLRequest {
        let url = path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(homeGS)", forHTTPHeaderField: "Authorization")
        request.setValue(homeDeviceInfo, forHTTPHeaderField: "X-MS-Device-Info")
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private var homeDeviceInfo: String {
        let value: [String: Any] = [
            "appInfo": ["env": [
                "clientAppId": "Microsoft.GamingApp",
                "clientAppType": "native",
                "clientAppVersion": "2203.1001.4.0",
                "clientSdkVersion": "8.5.2",
                "httpEnvironment": "prod",
                "sdkInstallId": ""
            ]],
            "dev": [
                "hw": ["make": "Apple", "model": "iPad", "sdktype": "native"],
                "os": ["name": "iPadOS", "ver": UIDevice.current.systemVersion, "platform": "mobile"],
                "displayInfo": ["dimensions": ["widthInPixels": 1920, "heightInPixels": 1080],
                                "pixelDensity": ["dpiX": 1, "dpiY": 1]]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let result = try await http.execute(request)
        guard (200..<300).contains(result.response.statusCode) else {
            throw CloudSessionServiceError.httpStatus(
                result.response.statusCode,
                String(data: result.data, encoding: .utf8) ?? "No error details"
            )
        }
        if result.data.isEmpty, let empty = HomeSessionEmptyResponse() as? T { return empty }
        do { return try JSONDecoder().decode(T.self, from: result.data) }
        catch { throw CloudSessionServiceError.invalidResponse }
    }
}

private struct HomeExchangeEnvelope: Decodable { let exchangeResponse: String? }
private struct HomeICEPost: Encodable { let iceCandidates: [CloudICECandidate] }
private struct HomeSDPOffer: Encodable {
    let messageType: String
    let sdp: String
    let configuration: Configuration
    struct Configuration: Encodable {
        let chatConfiguration = ChatConfiguration()
        let chat = VersionRange(minVersion: 1, maxVersion: 1)
        let control = VersionRange(minVersion: 1, maxVersion: 3)
        let input = VersionRange(minVersion: 1, maxVersion: 8)
        let message = VersionRange(minVersion: 1, maxVersion: 1)
        struct ChatConfiguration: Encodable {
            let bytesPerSample = 2
            let expectedClipDurationMs = 20
            let format = AudioFormat()
            let numChannels = 1
            let sampleFrequencyHz = 24_000
            struct AudioFormat: Encodable { let codec = "opus"; let container = "webm" }
        }
        struct VersionRange: Encodable { let minVersion: Int; let maxVersion: Int }
    }
}
