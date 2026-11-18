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

    init(transport: NativeWebRTCTransport? = nil) {
        self.transport = transport ?? NativeWebRTCTransport()
        self.transportObservation = self.transport.$state.sink { [weak self] state in
            Task { @MainActor in
                self?.isStreaming = state == .connected
                if case .failed(let message) = state {
                    self?.lastError = message
                    Task { @MainActor in await self?.stop() }
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
        videoWidth: Int = 1920,
        videoHeight: Int = 1080,
        maxFPS: Int = 60,
        msalUserTokenProvider: @escaping () async throws -> String
    ) async {
        guard !isStarting, !isStreaming, service == nil else { return }
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

            transport.setVideoPreference(width: videoWidth, height: videoHeight, maxFPS: maxFPS)
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

    func attachControllerManager(_ manager: ControllerManager) {
        transport.attachControllerManager(manager)
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
