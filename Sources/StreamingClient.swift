import Foundation

enum StreamingConnectionState: Equatable {
    case idle, authenticating, loadingCatalog, connecting, streaming, reconnecting
    case failed(String)
}

struct StreamPreferences: Codable, Equatable {
    var preferredResolution = "auto"
    var preferredFrameRate = 60
    var showNetworkStatistics = true
}

struct CloudGame: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let artworkURL: URL?
    let supportsCloudPlay: Bool
}

enum StreamingClientError: LocalizedError {
    case notImplemented, authenticationRequired, unsupportedSession, connectionFailed(String)
    var errorDescription: String? {
        switch self {
        case .notImplemented: return "The native streaming transport has not been integrated yet."
        case .authenticationRequired: return "Sign in is required before starting a cloud session."
        case .unsupportedSession: return "This streaming session type is not supported by the current client."
        case .connectionFailed(let reason): return reason
        }
    }
}

/// Native Xbox Cloud client boundary. Gameplay must not use a website wrapper or injected userscripts.
@MainActor
protocol XboxCloudStreamingClient: AnyObject {
    var connectionState: StreamingConnectionState { get }
    var games: [CloudGame] { get }
    func signIn() async throws
    func refreshCatalog() async throws
    func startCloudGame(id: String, preferences: StreamPreferences) async throws
    func stopStreaming() async
}
