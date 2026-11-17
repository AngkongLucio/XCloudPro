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
    private var keepAliveTask: Task<Void, Never>?
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
        locale: String = "en-US",
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

        do {
            try await waitUntilProvisioned(
                sessionID: sessionID,
                userTokenProvider: userTokenProvider
            )
            return try await fetchConfiguration(sessionID: sessionID)
        } catch {
            // Do not leave a provisioned/partially provisioned session running after failure.
            try? await stopCloudGame()
            throw error
        }
    }


    /// Exchanges a native WebRTC SDP offer with the Xbox Cloud session and
    /// returns the remote SDP answer. The peer connection itself is owned by
    /// the native media transport layer.
    func exchangeSDPOffer(_ sdp: String) async throws -> CloudSDPAnswer {
        guard let sessionID = activeSessionID else {
            throw CloudSessionServiceError.missingSessionID
        }
        let payload = CloudSDPOfferRequest(
            messageType: "offer",
            sdp: sdp,
            configuration: .init()
        )
        let body = try JSONEncoder().encode(payload)
        let post = makeRequest(
            path: "v5/sessions/cloud/\(sessionID)/sdp",
            method: "POST",
            body: body
        )
        let _: EmptyResponse = try await send(post)

        for _ in 0..<60 {
            try Task.checkCancellation()
            if let exchange = try await fetchExchangeResponse(
                path: "v5/sessions/cloud/\(sessionID)/sdp"
            ), let data = exchange.data(using: .utf8) {
                do {
                    return try JSONDecoder().decode(CloudSDPAnswer.self, from: data)
                } catch {
                    throw CloudSessionServiceError.invalidResponse
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CloudSessionServiceError.timedOut
    }

    /// Sends local ICE candidates and polls the exchange endpoint for the
    /// remote candidates returned by the Xbox Cloud host.
    func exchangeLocalICECandidates(
        _ candidates: [CloudICECandidate]
    ) async throws -> [CloudICECandidate] {
        guard let sessionID = activeSessionID else {
            throw CloudSessionServiceError.missingSessionID
        }
        let payload = CloudICEPostRequest(iceCandidates: candidates)
        let body = try JSONEncoder().encode(payload)
        let post = makeRequest(
            path: "v5/sessions/cloud/\(sessionID)/ice",
            method: "POST",
            body: body
        )
        let _: EmptyResponse = try await send(post)

        for _ in 0..<60 {
            try Task.checkCancellation()
            if let exchange = try await fetchExchangeResponse(
                path: "v5/sessions/cloud/\(sessionID)/ice"
            ), let data = exchange.data(using: .utf8) {
                if let candidates = try decodeICECandidates(from: data) {
                    return candidates
                }
                throw CloudSessionServiceError.invalidResponse
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CloudSessionServiceError.timedOut
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

    func startKeepAlive(pulseIntervalSeconds: Int) {
        keepAliveTask?.cancel()
        guard activeSessionID != nil, pulseIntervalSeconds > 0 else { return }
        let interval = max(15, pulseIntervalSeconds)
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    try await self?.sendKeepAlive()
                } catch {
                    break
                }
            }
            self?.keepAliveTask = nil
        }
    }

    func stopCloudGame() async throws {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        guard let sessionID = activeSessionID else { return }
        let request = makeRequest(
            path: "v5/sessions/cloud/\(sessionID)",
            method: "DELETE"
        )
        let _: EmptyResponse = try await send(request)
        activeSessionID = nil
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


    private func fetchExchangeResponse(path: String) async throws -> String? {
        let request = makeRequest(path: path, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSessionServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error details"
            throw CloudSessionServiceError.httpStatus(http.statusCode, message)
        }
        guard !data.isEmpty else { return nil }
        if let envelope = try? JSONDecoder().decode(CloudExchangeEnvelope.self, from: data) {
            guard let value = envelope.exchangeResponse, !value.isEmpty else { return nil }
            return value
        }
        if let emptyString = try? JSONDecoder().decode(String.self, from: data), emptyString.isEmpty {
            return nil
        }
        throw CloudSessionServiceError.invalidResponse
    }

    private func decodeICECandidates(from data: Data) throws -> [CloudICECandidate]? {
        let root = try JSONSerialization.jsonObject(with: data)

        func decodeCandidate(_ value: Any) -> CloudICECandidate? {
            let candidateData: Data?
            if let dictionary = value as? [String: Any],
               JSONSerialization.isValidJSONObject(dictionary) {
                candidateData = try? JSONSerialization.data(withJSONObject: dictionary)
            } else if let text = value as? String {
                candidateData = text.data(using: .utf8)
            } else {
                candidateData = nil
            }
            guard let candidateData else { return nil }
            return try? JSONDecoder().decode(CloudICECandidate.self, from: candidateData)
        }

        func unwrap(_ value: Any) -> [CloudICECandidate]? {
            if let text = value as? String, let nested = text.data(using: .utf8) {
                return try? decodeICECandidates(from: nested)
            }
            if let array = value as? [Any] {
                let decoded = array.compactMap(decodeCandidate)
                return decoded.count == array.count ? decoded : nil
            }
            if let dictionary = value as? [String: Any] {
                for key in ["exchangeResponse", "iceCandidates", "candidates"] {
                    if let nested = dictionary[key], let result = unwrap(nested) {
                        return result
                    }
                }
                if let single = decodeCandidate(dictionary) {
                    return [single]
                }
                let values = dictionary.keys.sorted().compactMap { dictionary[$0] }
                if !values.isEmpty {
                    let decoded = values.compactMap(decodeCandidate)
                    return decoded.count == values.count ? decoded : nil
                }
            }
            return nil
        }

        return unwrap(root)
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


    /// The Xbox exchange endpoints may return an empty response while signaling
    /// is pending. Decode only once exchangeResponse is actually present.
    private func sendExchange(_ request: URLRequest) async throws -> String? {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSessionServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error details"
            throw CloudSessionServiceError.httpStatus(http.statusCode, message)
        }
        guard !data.isEmpty else { return nil }
        let envelope = try JSONDecoder().decode(CloudExchangeEnvelope.self, from: data)
        guard let exchange = envelope.exchangeResponse, !exchange.isEmpty else { return nil }
        return exchange
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
        let message: String?
    }
}

private struct ConnectCloudSessionRequest: Encodable {
    let userToken: String
}

private struct EmptyResponse: Decodable {
    init() {}
}

private struct CloudSDPOfferRequest: Encodable {
    let messageType: String
    let sdp: String
    let configuration: SignalingConfiguration

    struct SignalingConfiguration: Encodable {
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

            struct AudioFormat: Encodable {
                let codec = "opus"
                let container = "webm"
            }
        }

        struct VersionRange: Encodable {
            let minVersion: Int
            let maxVersion: Int
        }
    }
}

struct CloudSDPAnswer: Decodable {
    let sdp: String
    let sdpType: String?
}

struct CloudICECandidate: Codable {
    let candidate: String
    let sdpMLineIndex: Int32
    let sdpMid: String?

    private enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMLineIndex
        case sdpMid
    }

    init(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        self.candidate = candidate
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidate = try container.decode(String.self, forKey: .candidate)
        sdpMid = try container.decodeIfPresent(String.self, forKey: .sdpMid)
        if let index = try? container.decode(Int32.self, forKey: .sdpMLineIndex) {
            sdpMLineIndex = index
        } else if let rawIndex = try? container.decode(String.self, forKey: .sdpMLineIndex),
                  let index = Int32(rawIndex) {
            sdpMLineIndex = index
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .sdpMLineIndex,
                in: container,
                debugDescription: "Invalid SDP media-line index."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidate, forKey: .candidate)
        try container.encode(sdpMLineIndex, forKey: .sdpMLineIndex)
        try container.encodeIfPresent(sdpMid, forKey: .sdpMid)
    }
}

private struct CloudICEPostRequest: Encodable {
    let iceCandidates: [CloudICECandidate]
}

private struct CloudExchangeEnvelope: Decodable {
    let exchangeResponse: String?
}
