import SwiftUI
import UIKit

private enum ConsoleTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case games = "My games"
    case console = "Console Remote Play"
    case discover = "Discover"
    case settings = "Settings"
    case account = "Account"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .games: return "square.grid.2x2.fill"
        case .console: return "tv.and.hifispeaker.fill"
        case .discover: return "sparkles"
        case .settings: return "gearshape.fill"
        case .account: return "person.crop.circle.fill"
        }
    }
}

private enum ConsolePalette {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.055)
    static let surface = Color(red: 0.085, green: 0.098, blue: 0.112)
    static let elevated = Color(red: 0.12, green: 0.135, blue: 0.15)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let muted = Color.white.opacity(0.56)
}


/// Uses the official Xbox Cloud Gaming web asset as a subtle dashboard wallpaper.
/// The dark overlays keep dashboard text/cards readable and the fallback is fully offline.
private struct XboxCloudBackdrop: View {
    private let imageURL = URL(string: "https://assets.play.xbox.com/playxbox/static/media/Byog_Bkg.141f84eb.jpg")!

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ConsolePalette.background
                AsyncImage(url: imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    case .empty, .failure:
                        ConsolePalette.background
                    @unknown default:
                        ConsolePalette.background
                    }
                }
                .overlay(Color.black.opacity(0.68))
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.28), ConsolePalette.background.opacity(0.68), ConsolePalette.background.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .background(ConsolePalette.background)
        .accessibilityHidden(true)
    }
}

struct ContentView: View {
    @EnvironmentObject private var controllerManager: ControllerManager
    @EnvironmentObject private var authenticationService: XboxAuthenticationService
    @EnvironmentObject private var appModel: XboxCloudAppModel
    @State private var selectedTab: ConsoleTab = .home
    @State private var showPlayerStatus = false
    @State private var showAuthenticationError = false
    @State private var microsoftEmail = ""
    @State private var showStreamPlayer = false
    @AppStorage("xcloudpro.haptics") private var hapticsEnabled = true
    @AppStorage("xcloudpro.showNetworkStats") private var showNetworkStats = true
    @AppStorage("xcloudpro.targetResolution") private var targetResolution = "1080p"
    @AppStorage("xcloudpro.preferredFPS") private var preferredFPS = "60"
    @AppStorage("xcloudpro.videoAspect") private var videoAspect = "fit"
    @AppStorage("xcloudpro.regionBypass") private var regionBypass = "off"

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Group {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar(compact: geometry.size.width < 700)
                    Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                    VStack(spacing: 0) {
                        topBar
                        ScrollView(showsIndicators: false) {
                            Group {
                                switch selectedTab {
                                case .home: homePage
                                case .games: gamesPage
                                case .console: consolePage
                                case .discover: discoverPage
                                case .settings: settingsPage
                                case .account: accountPage
                                }
                            }
                            .frame(maxWidth: 1120, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, geometry.size.width < 700 ? 18 : 34)
                            .padding(.top, 24)
                            .padding(.bottom, 42)
                        }
                    }
                }
                .background { XboxCloudBackdrop() }
            }
        }
        .background(XboxCloudBackdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            appModel.attachControllerManager()
        }
        .task(id: selectedTab) {
            if selectedTab == .games, authenticationService.account != nil, appModel.cloudGames.isEmpty {
                await loadCloudGames()
            }
            if selectedTab == .console, authenticationService.account != nil, appModel.consoles.isEmpty {
                await appModel.loadConsoles()
            }
        }
        .fullScreenCover(isPresented: $showStreamPlayer) {
            NativePlayerView(coordinator: appModel.streamCoordinator) {
                showStreamPlayer = false
                appModel.clearActiveGame()
            }
        }
        .fullScreenCover(item: $authenticationService.authorizationRequest) { request in
            XboxXALSignInView(
                authorizationURL: request.url,
                onRedirect: { authenticationService.completeMicrosoftSignIn($0) },
                onCancel: { authenticationService.cancelMicrosoftSignIn() }
            )
        }
        .alert("Native streaming", isPresented: $showPlayerStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Sign in to your Microsoft account, then open My Games to load the cloud catalog.")
        }
        .alert("Microsoft sign-in", isPresented: $showAuthenticationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authenticationService.errorMessage ?? "Sign-in could not be completed.")
        }
    }

    private var loginGate: some View {
        GeometryReader { geometry in
            ZStack {
                ConsolePalette.background.ignoresSafeArea()
                Circle()
                    .fill(ConsolePalette.green.opacity(0.10))
                    .frame(width: 360, height: 360)
                    .blur(radius: 90)
                    .offset(x: geometry.size.width * 0.28, y: -geometry.size.height * 0.30)

                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    Image(systemName: "xbox.logo")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(ConsolePalette.green)
                        .padding(.bottom, 14)
                    Text("XCLOUD PRO")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(.white)
                    Text("XSTREAMING-STYLE XAL AUTHENTICATION")
                        .font(.system(size: 10, weight: .black))
                        .tracking(1.5)
                        .foregroundStyle(ConsolePalette.muted)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Sign in through Microsoft's official authorization flow. XCloudPro does not ask for or store your Microsoft password.")
                            .font(.system(size: 12))
                            .foregroundStyle(ConsolePalette.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("Microsoft account email", text: $microsoftEmail)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(ConsolePalette.elevated, in: RoundedRectangle(cornerRadius: 11))
                            .foregroundStyle(.white)

                        Button {
                            Task {
                                do {
                                    try await authenticationService.signIn(email: microsoftEmail)
                                } catch {
                                    showAuthenticationError = true
                                }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                if authenticationService.isAuthenticating {
                                    ProgressView().tint(.black)
                                } else {
                                    Image(systemName: "xbox.logo")
                                }
                                Text(authenticationService.isAuthenticating ? "CONNECTING TO XBOX…" : "SIGN IN WITH MICROSOFT")
                                    .font(.system(size: 11, weight: .black))
                                    .tracking(0.8)
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(ConsolePalette.green, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(authenticationService.isAuthenticating || microsoftEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(authenticationService.isAuthenticating ? 0.7 : 1)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("XBOX AUTHENTICATION STATUS")
                                .font(.system(size: 9, weight: .black))
                                .tracking(1.0)
                                .foregroundStyle(ConsolePalette.muted)
                            HStack(spacing: 8) {
                                if authenticationService.isAuthenticating {
                                    ProgressView().tint(ConsolePalette.green).scaleEffect(0.8)
                                }
                                Text(authenticationService.statusMessage)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(ConsolePalette.elevated, in: RoundedRectangle(cornerRadius: 10))

                        Text("XCloudPro follows the XStreaming XAL sequence: device proof, Sisu, Microsoft OAuth, Xbox authorization and Cloud token validation. The app opens only after the Cloud session is ready.")
                            .font(.system(size: 10))
                            .foregroundStyle(ConsolePalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(maxWidth: 440)
                    .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.white.opacity(0.07), lineWidth: 1)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 30)

                    Spacer(minLength: 24)
                    Text("XBOX CLOUD GAMING • SECURE XAL SIGN-IN")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(ConsolePalette.muted.opacity(0.65))
                        .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "xbox.logo")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(ConsolePalette.green)
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("XCLOUD").font(.system(size: 17, weight: .black, design: .rounded)).tracking(1.4)
                        Text("PRO CONSOLE").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(ConsolePalette.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 0 : 22)
            .padding(.top, 28)
            .padding(.bottom, 38)

            ForEach(ConsoleTab.allCases) { tab in
                Button { selectTab(tab) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: tab.icon).font(.system(size: 17, weight: .semibold)).frame(width: 22)
                        if !compact {
                            Text(tab.rawValue).font(.system(size: 14, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? .white : ConsolePalette.muted)
                    .padding(.horizontal, compact ? 0 : 15)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(ConsolePalette.green.opacity(0.18))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(ConsolePalette.green).frame(width: 3).padding(.vertical, 9)
                                }
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
            }

            Spacer(minLength: 20)
            if !compact {
                VStack(alignment: .leading, spacing: 8) {
                    Label("CONTROLLER", systemImage: "gamecontroller.fill")
                        .font(.system(size: 9, weight: .black)).tracking(1.3)
                        .foregroundStyle(ConsolePalette.green)
                    Text(controllerManager.statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ConsolePalette.muted)
                        .lineLimit(2)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .frame(width: compact ? 68 : 218)
        .background(ConsolePalette.background)
    }

    private var topBar: some View {
        HStack {
            Text(selectedTab.rawValue.uppercased())
                .font(.system(size: 11, weight: .black)).tracking(2)
                .foregroundStyle(ConsolePalette.muted)
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(ConsolePalette.green).frame(width: 7, height: 7)
                Text("XCloudPro").font(.system(size: 10, weight: .bold)).tracking(0.8)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.06), in: Capsule())
            Button { selectTab(.account) } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 27)).foregroundStyle(selectedTab == .account ? ConsolePalette.green : .white.opacity(0.72))
                    .padding(.leading, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account")
        }
        .padding(.horizontal, 26)
        .frame(height: 66)
        .background(ConsolePalette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 27) {
            hero
            HStack(alignment: .bottom) {
                heading("JUMP BACK IN", subtitle: "Your gaming space")
                Spacer()
                Text("YOUR CONSOLE").font(.system(size: 9, weight: .black)).tracking(1.4).foregroundStyle(ConsolePalette.green)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                actionTile("My games", detail: "Your cloud game library", icon: "square.grid.2x2.fill", tint: ConsolePalette.green) { selectedTab = .games }
                actionTile("Console Remote Play", detail: "Stream your Xbox One or Series console", icon: "tv.and.hifispeaker.fill", tint: .cyan) { selectedTab = .console }
                actionTile("Discover", detail: "Explore available games", icon: "sparkles", tint: .cyan) { selectedTab = .discover }
                actionTile("Controller", detail: controllerManager.statusText, icon: "gamecontroller.fill", tint: .orange) { selectedTab = .settings }
                actionTile("Settings", detail: "Console preferences", icon: "slider.horizontal.3", tint: .purple) { selectedTab = .settings }
            }
            statusPanel
        }
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.34, blue: 0.20), Color(red: 0.055, green: 0.13, blue: 0.095), ConsolePalette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            GeometryReader { proxy in
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: min(190, proxy.size.width * 0.30), weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.075))
                    .rotationEffect(.degrees(-18))
                    .position(x: proxy.size.width * 0.83, y: proxy.size.height * 0.55)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("WELCOME TO XCLOUDPRO")
                    .font(.system(size: 10, weight: .black)).tracking(2.2).foregroundStyle(ConsolePalette.green)
                Text("Your games.\nYour cloud.")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7).lineLimit(2)
                Text("A native Xbox-inspired home for cloud gaming.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.68))
                Button { selectTab(.games) } label: {
                    Label("START PLAYING", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .black)).tracking(1)
                        .foregroundStyle(.black).padding(.horizontal, 21).frame(height: 45)
                        .background(ConsolePalette.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
            .padding(28)
        }
        .frame(minHeight: 285)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var gamesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("MY GAMES", subtitle: "Xbox Cloud Gaming titles available to this account")
            if authenticationService.account == nil {
                statusPanel
                Button { selectedTab = .account } label: {
                    Label("Connect Microsoft account", systemImage: "person.crop.circle.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(16)
                        .background(ConsolePalette.green, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            } else {
                HStack {
                    if let region = authenticationService.availableRegions.first(where: { $0.name == authenticationService.selectedRegionName }) {
                        Label(region.name, systemImage: "globe")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ConsolePalette.muted)
                    }
                    Spacer()
                    Button {
                        Task { await loadCloudGames() }
                    } label: {
                        Label(appModel.isLoadingGames ? "LOADING…" : "REFRESH", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(ConsolePalette.green)
                    }
                    .disabled(appModel.isLoadingGames || appModel.isStartingGame)
                }
                if appModel.isLoadingGames {
                    ProgressView("Loading Xbox cloud catalog…")
                        .tint(ConsolePalette.green)
                        .frame(maxWidth: .infinity).padding(32)
                } else if let gamesError = appModel.gamesError {
                    Text(gamesError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    Button("TRY AGAIN") { Task { await loadCloudGames() } }
                        .font(.system(size: 10, weight: .black))
                } else if appModel.cloudGames.isEmpty {
                    Text("Tap refresh to load titles available through Xbox Cloud Gaming.")
                        .font(.system(size: 11)).foregroundStyle(ConsolePalette.muted)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        ForEach(appModel.cloudGames) { game in
                            Button {
                                Task { await startCloudGame(game) }
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    AsyncImage(url: game.artworkURL) { phase in
                                        Group {
                                            if let image = phase.image {
                                                image.resizable().scaledToFill()
                                            } else {
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(LinearGradient(colors: [ConsolePalette.elevated, ConsolePalette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                    .overlay {
                                                        Image(systemName: "gamecontroller.fill")
                                                            .font(.system(size: 32)).foregroundStyle(ConsolePalette.green.opacity(0.8))
                                                    }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(game.title)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    Text("PLAY IN CLOUD")
                                        .font(.system(size: 9, weight: .black)).tracking(0.8)
                                        .foregroundStyle(ConsolePalette.green)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .disabled(appModel.isStartingGame)
                        }
                    }
                }
                if appModel.isStartingGame {
                    ProgressView("Starting \(appModel.activeGame?.title ?? "game")…")
                        .tint(ConsolePalette.green)
                }
            }
        }
    }

    private var consolePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("XBOX CONSOLE REMOTE PLAY", subtitle: "Stream a registered Xbox One or Xbox Series S/X console to this iPad")
            if authenticationService.account == nil {
                statusPanel
                Button { selectedTab = .account } label: {
                    Label("CONNECT MICROSOFT ACCOUNT", systemImage: "person.crop.circle.badge.plus")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(15)
                        .background(ConsolePalette.green, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Text("Remote Play discovery needs an Xbox account. You can still browse the app and change settings without signing in.")
                    .font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
            } else {
            HStack {
                Label("Xbox Home Streaming", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ConsolePalette.muted)
                Spacer()
                Button {
                    Task { await appModel.loadConsoles() }
                } label: {
                    Label(appModel.isLoadingConsoles ? "LOADING…" : "REFRESH", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(ConsolePalette.green)
                }
                .disabled(appModel.isLoadingConsoles || appModel.isStartingGame)
            }
            if appModel.isLoadingConsoles {
                ProgressView("Finding consoles registered to your Xbox account…")
                    .tint(ConsolePalette.green)
                    .frame(maxWidth: .infinity).padding(30)
            } else if let error = appModel.gamesError, appModel.consoles.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
                Button("TRY AGAIN") { Task { await appModel.loadConsoles() } }
                    .font(.system(size: 10, weight: .black))
            } else if appModel.consoles.isEmpty {
                Text("Tap Refresh to discover Xbox consoles registered to this Microsoft account.")
                    .font(.system(size: 11)).foregroundStyle(ConsolePalette.muted)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(appModel.consoles) { console in
                    Button {
                        Task {
                            await appModel.startConsoleRemotePlay(
                                console,
                                targetResolution: targetResolution,
                                preferredFPS: preferredFPS
                            )
                            if appModel.streamCoordinator.lastError == nil {
                                showStreamPlayer = true
                            }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "xbox.logo")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(ConsolePalette.green)
                                .frame(width: 48, height: 48)
                                .background(ConsolePalette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(console.displayName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(console.consoleType ?? "Xbox console")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(ConsolePalette.muted)
                                Text(console.powerState ?? "Power state unavailable")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(ConsolePalette.green)
                            }
                            Spacer()
                            if appModel.isStartingGame {
                                ProgressView().tint(ConsolePalette.green)
                            } else {
                                Image(systemName: "play.fill").foregroundStyle(ConsolePalette.green)
                            }
                        }
                        .padding(15)
                        .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    .disabled(appModel.isStartingGame)
                }
            }
            Text("Console must be registered to this Xbox account and configured for Remote features. Network reachability and console power state are controlled by Xbox.")
                .font(.system(size: 10))
                .foregroundStyle(ConsolePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var discoverPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("DISCOVER", subtitle: "Browse the Xbox Cloud Gaming catalog available to your account")
            if appModel.cloudGames.isEmpty {
                statusPanel
                Button("LOAD CATALOG") { selectedTab = .games }
                    .font(.system(size: 10, weight: .black))
            } else {
                ForEach(appModel.cloudGames.prefix(12)) { game in
                    Button { Task { await startCloudGame(game) } } label: {
                        HStack {
                            Image(systemName: "gamecontroller.fill").foregroundStyle(ConsolePalette.green)
                            Text(game.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "play.fill").foregroundStyle(ConsolePalette.green)
                        }
                        .padding(14).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("MICROSOFT ACCOUNT", subtitle: "Sign in with the same account you use for Xbox Cloud Gaming in Safari.")
            accountCard
            settingsInfo("Account provider", value: "Microsoft / Xbox", icon: "person.badge.key.fill")
            settingsInfo("Gamertag", value: authenticationService.account?.gamertag ?? "Not connected", icon: "person.text.rectangle")
            settingsInfo("Xbox user ID", value: authenticationService.account?.id ?? "Available after sign-in", icon: "number")
            settingsInfo("Cloud token", value: authenticationService.account == nil ? "Not available" : "Refresh supported when needed", icon: "key.horizontal")
        }
    }

    private var accountCard: some View {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(ConsolePalette.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authenticationService.account?.gamertag ?? "Xbox account")
                            .font(.system(size: 16, weight: .bold))
                        Text(authenticationService.statusMessage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ConsolePalette.muted)
                    }
                    Spacer()
                    Circle()
                        .fill(authenticationService.account == nil ? .orange : ConsolePalette.green)
                        .frame(width: 9, height: 9)
                }

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

                Button {
                    Task {
                        do {
                            try await authenticationService.signInWithDeviceCode()
                        } catch {
                            showAuthenticationError = true
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        if authenticationService.isAuthenticating {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "number")
                        }
                        Text(authenticationService.isAuthenticating ? "WAITING FOR MICROSOFT…" : "SIGN IN WITH DEVICE CODE")
                            .font(.system(size: 11, weight: .black)).tracking(0.8)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(ConsolePalette.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(authenticationService.isAuthenticating || authenticationService.account != nil)

                if let challenge = authenticationService.deviceCodeRequest {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("YOUR MICROSOFT CODE")
                            .font(.system(size: 9, weight: .black)).tracking(1.1)
                            .foregroundStyle(ConsolePalette.muted)
                        HStack {
                            Text(challenge.userCode)
                                .font(.system(size: 25, weight: .black, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(ConsolePalette.green)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = challenge.userCode
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(ConsolePalette.green)
                            }
                            .buttonStyle(.plain)
                        }
                        Link(destination: challenge.verificationURL) {
                            Label("OPEN MICROSOFT DEVICE LOGIN", systemImage: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(ConsolePalette.green)
                        }
                        Text("Ilagay ang code sa Microsoft page at aprubahan ang sign-in. Awtomatikong magpapatuloy ang app.")
                            .font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
                        Button("CANCEL SIGN-IN", role: .cancel) {
                            authenticationService.cancelDeviceCodeSignIn()
                        }
                        .font(.system(size: 10, weight: .bold))
                    }
                    .padding(14)
                    .background(ConsolePalette.elevated, in: RoundedRectangle(cornerRadius: 13))
                }

                Text("LEGACY XAL SIGN-IN (FALLBACK)")
                    .font(.system(size: 9, weight: .black)).tracking(1.1)
                    .foregroundStyle(ConsolePalette.muted)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 7) {
                    Text("MICROSOFT EMAIL")
                        .font(.system(size: 9, weight: .black)).tracking(1.1)
                        .foregroundStyle(ConsolePalette.muted)
                    TextField("name@example.com", text: $microsoftEmail)
                        .font(.system(size: 14, weight: .medium))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 13)
                        .frame(height: 46)
                        .background(ConsolePalette.elevated, in: RoundedRectangle(cornerRadius: 11))
                        .disabled(authenticationService.isAuthenticating || authenticationService.account != nil)
                }

                Button {
                    Task {
                        do {
                            try await authenticationService.signIn(email: microsoftEmail)
                        } catch {
                            showAuthenticationError = true
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        if authenticationService.isAuthenticating {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "xbox.logo")
                        }
                        Text(authenticationService.isAuthenticating ? "CONNECTING TO MICROSOFT…" : "SIGN IN WITH XAL")
                            .font(.system(size: 11, weight: .black)).tracking(0.8)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(ConsolePalette.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(
                    authenticationService.isAuthenticating ||
                    authenticationService.account != nil ||
                    !microsoftEmail.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
                )

                if authenticationService.account != nil {
                    Label("Xbox account connected", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ConsolePalette.green)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("CLOUD REGION")
                            .font(.system(size: 9, weight: .black)).tracking(1.1)
                            .foregroundStyle(ConsolePalette.muted)
                        if !authenticationService.availableRegions.isEmpty {
                            Picker("Cloud region", selection: $authenticationService.selectedRegionName) {
                                Text("Automatic (Xbox default)").tag(String?.none)
                                ForEach(authenticationService.regionContinents, id: \.self) { continent in
                                    Section(continent) {
                                        ForEach(authenticationService.availableRegions.filter { $0.continentName == continent }) { region in
                                            Text("\(region.pickerTitle)\(region.isDefault ? " · Default" : "")")
                                                .tag(Optional(region.name))
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(ConsolePalette.green)
                            .onChange(of: authenticationService.selectedRegionName) { _ in
                                Task { await loadCloudGames() }
                            }
                            Text("Choose a server returned by Xbox, or use Automatic (Xbox default). The selection applies to the catalog and new cloud sessions.")
                                .font(.system(size: 9)).foregroundStyle(ConsolePalette.muted)
                        } else {
                            Text(authenticationService.cloudAvailabilityMessage ?? "No Cloud Gaming regions have been returned by Xbox yet.")
                                .font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task {
                                    do {
                                        try await authenticationService.retryMSALCloudCredentials()
                                        await loadCloudGames()
                                    } catch {
                                        authenticationService.errorMessage = error.localizedDescription
                                        showAuthenticationError = true
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if authenticationService.isAuthenticating {
                                        ProgressView().tint(.black)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text("RETRY CLOUD TOKEN / LOAD REGIONS")
                                        .font(.system(size: 10, weight: .black)).tracking(0.5)
                                }
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity).frame(height: 42)
                                .background(ConsolePalette.green, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(authenticationService.isAuthenticating)
                        }
                    }
                    Button("SIGN OUT", role: .destructive) {
                        authenticationService.signOut()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.top, 2)
                } else {
                    Text("Enter your email first. Microsoft will securely ask for your password and any required verification in its official sign-in window. XCloudPro never receives or stores your password.")
                        .font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("SETTINGS", subtitle: "Native XCloudPro preferences")
            settingsPicker(
                "Bypass region restriction",
                detail: "Better xCloud-style forwarded-IP hint. Xbox may still deny Cloud Gaming access.",
                selection: $regionBypass,
                options: [
                    ("off", "Off"),
                    ("br", "Brazil"),
                    ("jp", "Japan"),
                    ("kr", "Korea"),
                    ("pl", "Poland"),
                    ("us", "United States")
                ],
                icon: "globe"
            )
            settingsToggle("Haptic feedback", detail: "Use a light haptic when changing app sections", value: $hapticsEnabled, icon: "iphone.radiowaves.left.and.right")
            settingsToggle("Show stream status badge", detail: "Show the connection badge in the native player", value: $showNetworkStats, icon: "chart.xyaxis.line")
            settingsPicker("Preferred resolution", detail: "Requests a stream size; Xbox may apply its own limits", selection: $targetResolution, options: [("1080p", "1080p"), ("720p", "720p")], icon: "display")
            settingsPicker("Preferred frame rate", detail: "Requests the maximum frame rate for the session", selection: $preferredFPS, options: [("60", "60 FPS"), ("30", "30 FPS")], icon: "speedometer")
            settingsPicker("Video scaling", detail: "Fit preserves the full image; Fill crops to fill the screen", selection: $videoAspect, options: [("fit", "Fit"), ("fill", "Fill")], icon: "aspectratio")
            settingsInfo("App version", value: appVersion, icon: "number")
            settingsInfo("Controller", value: controllerManager.statusText, icon: "gamecontroller")
            settingsInfo("Streaming engine", value: "Xbox Cloud API + native WebRTC", icon: "waveform.path")
            settingsInfo("Gameplay renderer", value: "Native Metal-backed video surface", icon: "display")
            Text("Resolution, bitrate, codec, and frame-rate controls will be shown only when the native streaming backend exposes and supports them.")
                .font(.system(size: 11)).foregroundStyle(ConsolePalette.muted)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 13) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 22)).foregroundStyle(ConsolePalette.green)
                .frame(width: 42, height: 42).background(ConsolePalette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("NATIVE STREAMING ENGINE")
                    .font(.system(size: 10, weight: .black)).tracking(1.1)
                Text("Browse your gaming space. Connect a Microsoft account from Account when you want to load games or start streaming.")
                    .font(.system(size: 11)).foregroundStyle(ConsolePalette.muted)
            }
            Spacer(minLength: 0)
            Circle().fill(.orange).frame(width: 8, height: 8)
        }
        .padding(16).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func selectTab(_ tab: ConsoleTab) {
        if hapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        selectedTab = tab
    }

    private func loadCloudGames() async {
        await appModel.loadCloudGames()
    }

    private func startCloudGame(_ game: CloudGame) async {
        guard !appModel.isStartingGame else { return }
        await appModel.startCloudGame(
            game,
            targetResolution: targetResolution,
            preferredFPS: preferredFPS
        )
        // Present the native player only after the cloud session and initial
        // WebRTC signaling setup succeed. Failed launches remain on Library
        // so the user can read the reported error and retry safely.
        if appModel.streamCoordinator.lastError == nil {
            switch appModel.streamCoordinator.transport.state {
            case .idle, .failed:
                break
            case .preparing, .connecting, .connected:
                showStreamPlayer = true
            }
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 18, weight: .black, design: .rounded)).tracking(1)
            Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(ConsolePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionTile(_ title: String, detail: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(ConsolePalette.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .padding(16).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func settingsToggle(_ title: String, detail: String, value: Binding<Bool>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(ConsolePalette.green).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
            }
            Spacer()
            Toggle(title, isOn: value).labelsHidden().tint(ConsolePalette.green)
        }
        .padding(16).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    // Shared native picker row for persistent Better xCloud-inspired preferences.
    private func settingsPicker(_ title: String, detail: String, selection: Binding<String>, options: [(String, String)], icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(ConsolePalette.green).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
            }
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
            .pickerStyle(.menu)
            .tint(ConsolePalette.green)
            .labelsHidden()
        }
        .padding(16).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func settingsInfo(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(ConsolePalette.green).frame(width: 28)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(ConsolePalette.muted).multilineTextAlignment(.trailing)
        }
        .padding(16).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
