import Combine
import Foundation

@MainActor
final class NativeStreamCoordinator: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String?

    let transport: NativeWebRTCTransport
    private var service: XboxCloudSessionService?

    init(transport: NativeWebRTCTransport = NativeWebRTCTransport()) {
        self.transport = transport
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
            isStreaming = true
            isStarting = false

            let pulse = max(30, configuration.keepAlivePulseInSeconds ?? 300)
            keepAliveTask = Task { [weak self, weak cloudService] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(pulse) * 1_000_000_000)
                        guard !Task.isCancelled else { break }
                        try await cloudService?.sendKeepAlive()
                    } catch {
                        await MainActor.run {
                            self?.lastError = "Cloud keepalive failed: \(error.localizedDescription)"
                        }
                        break
                    }
                }
            }
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
