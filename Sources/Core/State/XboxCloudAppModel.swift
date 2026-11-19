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
    @Published private(set) var consoles: [XboxConsoleDevice] = []
    @Published private(set) var isLoadingConsoles = false

    let streamCoordinator: NativeStreamCoordinator

    private let authenticationService: XboxAuthenticationService
    private let controllerManager: ControllerManager

    init(
        authenticationService: XboxAuthenticationService,
        controllerManager: ControllerManager,
        streamCoordinator: NativeStreamCoordinator? = nil
    ) {
        self.authenticationService = authenticationService
        self.controllerManager = controllerManager
        self.streamCoordinator = streamCoordinator ?? NativeStreamCoordinator()
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
        preferredFPS: String,
        clientProfile: String = "ipad"
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
                osName: clientProfile == "xbox-series-x" ? "xbox" : "windows",
                deviceInfoHeader: makeDeviceInfoHeader(for: clientProfile),
                userAgent: makeUserAgent(for: clientProfile),
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

    func loadConsoles() async {
        guard authenticationService.account != nil, !isLoadingConsoles else { return }
        isLoadingConsoles = true
        gamesError = nil
        defer { isLoadingConsoles = false }
        do {
            let credentials = try await authenticationService.consoleRemotePlayCredentials()
            guard let region = credentials.regions.first(where: { $0.isDefault }) ?? credentials.regions.first else {
                throw XboxAuthenticationError.missingValue("Xbox home-streaming region")
            }
            let service = try XboxConsoleRemotePlayService(
                baseURL: region.baseURI,
                homeGSToken: credentials.homeGSToken,
                webToken: credentials.webToken,
                userHash: credentials.userHash
            )
            consoles = try await service.fetchConsoles()
            if consoles.isEmpty {
                gamesError = "No Xbox consoles are registered to this Microsoft account."
            }
        } catch {
            gamesError = error.localizedDescription
        }
    }

    func startConsoleRemotePlay(
        _ console: XboxConsoleDevice,
        targetResolution: String,
        preferredFPS: String
    ) async {
        guard !isStartingGame, authenticationService.account != nil else { return }
        isStartingGame = true
        gamesError = nil
        defer { isStartingGame = false }
        do {
            let credentials = try await authenticationService.consoleRemotePlayCredentials()
            guard let region = credentials.regions.first(where: { $0.isDefault }) ?? credentials.regions.first else {
                throw XboxAuthenticationError.missingValue("Xbox home-streaming region")
            }
            let service = try XboxConsoleRemotePlayService(
                baseURL: region.baseURI,
                homeGSToken: credentials.homeGSToken,
                webToken: credentials.webToken,
                userHash: credentials.userHash
            )
            await streamCoordinator.startConsoleRemotePlay(
                using: service,
                consoleID: console.id,
                videoWidth: targetResolution == "720p" ? 1280 : 1920,
                videoHeight: targetResolution == "720p" ? 720 : 1080,
                maxFPS: Int(preferredFPS) ?? 60
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

    private func makeUserAgent(for profile: String) -> String {
        if profile == "xbox-series-x" {
            return "Mozilla/5.0 (Xbox; Xbox Series X) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"
        }
        return "Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
    }

    private func makeDeviceInfoHeader(for profile: String) -> String {
        let isXboxSeriesX = profile == "xbox-series-x"
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
                    "model": isXboxSeriesX ? "Xbox Series X" : "iPad",
                    "sdktype": "web"
                ],
                "os": [
                    "name": isXboxSeriesX ? "Xbox" : "windows",
                    "ver": isXboxSeriesX ? "10.0" : "22631.2715",
                    "platform": isXboxSeriesX ? "console" : "desktop"
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
                    "browserName": isXboxSeriesX ? "Edge" : "Chrome",
                    "browserVersion": "130.0"
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }}
