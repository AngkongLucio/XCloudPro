import Combine
import Foundation

@MainActor
final class NativeStreamCoordinator: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String?

    let transport: NativeWebRTCTransport
    private var service: XboxCloudSessionService?
    private var transportObservation: AnyCancellable?

    init(transport: NativeWebRTCTransport = NativeWebRTCTransport()) {
        self.transport = transport
        self.transportObservation = transport.$state.sink { [weak self] state in
            Task { @MainActor in
                self?.isStreaming = state == .connected
                if case .failed(let message) = state {
                    self?.lastError = message
                }
            }
        }
    }

    /// Starts a true Xbox Cloud Gaming session. The caller must provide tokens
    /// obtained through the supported Microsoft sign-in flow; never pass a password.
    func start(
        titleID: String,
        regionBaseURL: URL,
        gsToken: String,
        osName: String,
        deviceInfoHeader: String,
        msalUserTokenProvider: @escaping () async throws -> String
    ) async {
        guard !isStarting, !isStreaming else { return }
        isStarting = true
        lastError = nil

        do {
            let cloudService = try XboxCloudSessionService(
                baseURL: regionBaseURL,
                gsToken: gsToken
            )
            service = cloudService

            let configuration = try await cloudService.startCloudGame(
                titleID: titleID,
                osName: osName,
                deviceInfoHeader: deviceInfoHeader,
                userTokenProvider: msalUserTokenProvider
            )

            try await transport.start(using: cloudService)
            isStarting = false
            cloudService.startKeepAlive(
                pulseIntervalSeconds: max(30, configuration.keepAlivePulseInSeconds ?? 300)
            )
        } catch {
            lastError = error.localizedDescription
            isStarting = false
            isStreaming = false
            transport.stop()
            try? await service?.stopCloudGame()
            service = nil
        }
    }

    func stop() async {
        transport.stop()
        if let service {
            try? await service.stopCloudGame()
        }
        service = nil
        isStarting = false
        isStreaming = false
    }
}
