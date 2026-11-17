import SwiftUI

private enum ConsoleTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case games = "My games"
    case discover = "Discover"
    case settings = "Settings"
    case account = "Account"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .games: return "square.grid.2x2.fill"
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

struct ContentView: View {
    @EnvironmentObject private var controllerManager: ControllerManager
    @EnvironmentObject private var authenticationService: XboxAuthenticationService
    @State private var selectedTab: ConsoleTab = .home
    @State private var showPlayerStatus = false
    @State private var showAuthenticationError = false
    @AppStorage("xcloudpro.haptics") private var hapticsEnabled = true
    @AppStorage("xcloudpro.showNetworkStats") private var showNetworkStats = true

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
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
            .background(ConsolePalette.background)
        }
        .background(ConsolePalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert("Native streaming is not connected yet", isPresented: $showPlayerStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Microsoft sign-in is being integrated. Gameplay will be enabled only after the native stream transport and controller input are validated.")
        }
        .alert("Microsoft sign-in", isPresented: $showAuthenticationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authenticationService.errorMessage ?? "Sign-in could not be completed.")
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
                Button { selectedTab = tab } label: {
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
            Button { selectedTab = .account } label: {
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
                Text("Your games.\nYour console.")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7).lineLimit(2)
                Text("A native Xbox-inspired home for cloud gaming.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.68))
                Button { showPlayerStatus = true } label: {
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
            heading("MY GAMES", subtitle: "Your Xbox cloud library will appear here when account and catalog services are connected.")
            statusPanel
            Button { showPlayerStatus = true } label: {
                Label("Streaming service not connected", systemImage: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ConsolePalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
        }
    }

    private var discoverPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("DISCOVER", subtitle: "Catalog browsing will be enabled after the Xbox service API integration.")
            statusPanel
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("MICROSOFT ACCOUNT", subtitle: "Sign in with the same account you use for Xbox Cloud Gaming in Safari.")

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
                            try await authenticationService.signIn()
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
                        Text(authenticationService.isAuthenticating ? "CONNECTING TO MICROSOFT…" : "SIGN IN WITH MICROSOFT")
                            .font(.system(size: 11, weight: .black)).tracking(0.8)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(ConsolePalette.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(authenticationService.isAuthenticating || authenticationService.account != nil)

                if authenticationService.account != nil {
                    Label("Xbox account connected", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ConsolePalette.green)
                    if !authenticationService.availableRegions.isEmpty {
                        Text("Available cloud regions: " + authenticationService.availableRegions.joined(separator: ", "))
                            .font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("SIGN OUT", role: .destructive) {
                        authenticationService.signOut()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.top, 2)
                } else {
                    Text("A secure Microsoft sign-in window will open. XCloudPro does not ask for or store your Microsoft password.")
                        .font(.system(size: 10)).foregroundStyle(ConsolePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 18))

            settingsInfo("Account provider", value: "Microsoft / Xbox", icon: "person.badge.key.fill")
            settingsInfo("Gamertag", value: authenticationService.account?.gamertag ?? "Not connected", icon: "person.text.rectangle")
            settingsInfo("Xbox user ID", value: authenticationService.account?.id ?? "Available after sign-in", icon: "number")
            settingsInfo("Cloud token", value: authenticationService.account == nil ? "Not available" : "Retrieved; refresh flow pending", icon: "key.horizontal")
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("SETTINGS", subtitle: "Native XCloudPro preferences")
            settingsToggle("Haptic feedback", detail: "Use haptics for supported interface actions", value: $hapticsEnabled, icon: "iphone.radiowaves.left.and.right")
            settingsToggle("Show network statistics", detail: "Display diagnostics in the player when available", value: $showNetworkStats, icon: "chart.xyaxis.line")
            settingsInfo("App version", value: appVersion, icon: "number")
            settingsInfo("Controller", value: controllerManager.statusText, icon: "gamecontroller")
            settingsInfo("Streaming engine", value: "Native integration in development", icon: "waveform.path")
            settingsInfo("Gameplay renderer", value: "No web player bundled", icon: "display")
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
                Text("Integration in progress — no gameplay stream is active.")
                    .font(.system(size: 11)).foregroundStyle(ConsolePalette.muted)
            }
            Spacer(minLength: 0)
            Circle().fill(.orange).frame(width: 8, height: 8)
        }
        .padding(16).background(ConsolePalette.surface, in: RoundedRectangle(cornerRadius: 16))
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
