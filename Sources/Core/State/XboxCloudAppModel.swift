import Combine
import Foundation

/// Application-level state store, mirroring PeaSyo's centralized Redux store
/// with native ObservableObject state and Keychain-backed credentials.
@MainActor
final class XboxCloudAppModel: ObservableObject {
    @Published private(set) var cloudGames: [CloudGame] = []
    @Published private(set) var isLoadingGames = false
    @Published private(set) var isStartingGame = false
    @Published private(set) var gamesError: String?
    @Published private(set) var activeGame: CloudGame?

    let streamCoordinator: NativeStreamCoordinator

    private let authenticationService: XboxAuthenticationService
    private let controllerManager: ControllerManager

    init(
        authenticationService: XboxAuthenticationService,
        controllerManager: ControllerManager,
        streamCoordinator: NativeStreamCoordinator = NativeStreamCoordinator()
    ) {
        self.authenticationService = authenticationService
        self.controllerManager = controllerManager
        self.streamCoordinator = streamCoordinator
    }

    func attachControllerManager() {
        streamCoordinator.attachControllerManager(controllerManager)
    }

    func loadCloudGames() async {
        guard authenticationService.account != nil, !isLoadingGames else { return }
        isLoadingGames = true
        gamesError = nil
        defer { isLoadingGames = false }

        do {
            let credentials = try await authenticationService.cloudSessionCredentials()
            let catalog = try XboxCloudCatalogService(
                regionBaseURL: credentials.region.baseURI,
                gsToken: credentials.gsToken
            )
            cloudGames = try await catalog.fetchCloudGames()
            if cloudGames.isEmpty {
                gamesError = "Xbox returned no cloud titles for this account or region."
            }
        } catch {
            gamesError = error.localizedDescription
        }
    }

    func startCloudGame(
        _ game: CloudGame,
        targetResolution: String,
        preferredFPS: String
    ) async {
        guard !isStartingGame, authenticationService.account != nil else { return }
        isStartingGame = true
        activeGame = game
        gamesError = nil
        defer { isStartingGame = false }

        do {
            let credentials = try await authenticationService.cloudSessionCredentials()
            await streamCoordinator.start(
                titleID: game.id,
                regionBaseURL: credentials.region.baseURI,
                gsToken: credentials.gsToken,
                osName: "windows",
                deviceInfoHeader: makeDeviceInfoHeader(),
                videoWidth: targetResolution == "720p" ? 1280 : 1920,
                videoHeight: targetResolution == "720p" ? 720 : 1080,
                maxFPS: Int(preferredFPS) ?? 60,
                msalUserTokenProvider: { [authenticationService] in
                    try await authenticationService.cloudTransferToken()
                }
            )
            if let error = streamCoordinator.lastError {
                gamesError = error
            }
        } catch {
            gamesError = error.localizedDescription
        }
    }

    func clearActiveGame() {
        activeGame = nil
    }

    func stopStreaming() async {
        await streamCoordinator.stop()
        activeGame = nil
        isStartingGame = false
    }

    private func makeDeviceInfoHeader() -> String {
        // Keep the existing Xbox Cloud web-client compatibility profile unchanged
        // during this structural migration. Device-profile work is a separate
        // protocol-validation step, not a UI or architecture rewrite.
        let info: [String: Any] = [
            "appInfo": [
                "env": [
                    "clientAppId": "www.xbox.com",
                    "clientAppType": "browser",
                    "clientAppVersion": "26.1.97",
                    "clientSdkVersion": "10.3.7",
                    "httpEnvironment": "prod",
                    "sdkInstallId": ""
                ]
            ],
            "dev": [
                "hw": [
                    "make": "Microsoft",
                    "model": "unknown",
                    "sdktype": "web"
                ],
                "os": [
                    "name": "windows",
                    "ver": "22631.2715",
                    "platform": "desktop"
                ],
                "displayInfo": [
                    "dimensions": [
                        "widthInPixels": 1920,
                        "heightInPixels": 1080
                    ],
                    "pixelDensity": [
                        "dpiX": 1,
                        "dpiY": 1
                    ]
                ],
                "browser": [
                    "browserName": "chrome",
                    "browserVersion": "130.0"
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }
}
