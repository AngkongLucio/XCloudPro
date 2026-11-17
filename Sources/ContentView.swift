import SwiftUI

private enum ConsoleSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case library = "My games"
    case discover = "Game Pass"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .discover: return "gamecontroller.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controllerManager: ControllerManager
    @State private var section: ConsoleSection = .home
    @State private var showStreamStatus = false

    private let background = Color(red: 0.035, green: 0.043, blue: 0.055)
    private let panel = Color(red: 0.075, green: 0.09, blue: 0.105)
    private let xboxGreen = Color(red: 0.20, green: 0.78, blue: 0.35)

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            consoleLayout
        }
        .preferredColorScheme(.dark)
        .alert("Native streaming is being integrated", isPresented: $showStreamStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The Xbox-style dashboard is ready as the app shell. Xbox account authentication, cloud catalog, and the native WebRTC player still need to be connected before games can launch.")
        }
    }

    private var consoleLayout: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: geometry.size.width < 700 ? 68 : 205)

                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    topBar
                    ScrollView(showsIndicators: false) {
                        Group {
                            switch section {
                            case .home: homePage
                            case .library: libraryPage
                            case .discover: gamePassPage
                            case .settings: settingsPage
                            }
                        }
                        .frame(maxWidth: 1160, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, geometry.size.width < 700 ? 16 : 30)
                        .padding(.top, 22)
                        .padding(.bottom, 36)
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "xbox.logo")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(xboxGreen)
                if wideSidebar {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("XCLOUD")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .tracking(1.1)
                        Text("GAMING")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.43))
                    }
                }
            }
            .padding(.horizontal, wideSidebar ? 18 : 0)
            .frame(maxWidth: .infinity, alignment: wideSidebar ? .leading : .center)
            .padding(.top, 25)
            .padding(.bottom, 35)

            ForEach(ConsoleSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 22)
                        if wideSidebar {
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(section == item ? .white : .white.opacity(0.57))
                    .padding(.horizontal, wideSidebar ? 13 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(xboxGreen.opacity(0.19))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(xboxGreen).frame(width: 3).padding(.vertical, 8)
                                }
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            Spacer(minLength: 12)

            if wideSidebar {
                HStack(spacing: 9) {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(xboxGreen)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CONTROLLER")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.4))
                        Text(controllerManager.statusText)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
            }
        }
    }

    private var wideSidebar: Bool { true }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(section.rawValue.uppercased())
                .font(.system(size: 11, weight: .black))
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(xboxGreen).frame(width: 6, height: 6)
                Text("XCloudPro")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: Capsule())
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(background.opacity(0.97))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 27) {
            heroTile

            HStack {
                sectionHeading("RECENTLY PLAYED", subtitle: "Your games will appear here")
                Spacer()
                Button("MY GAMES") { section = .library }
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(xboxGreen)
            }

            HStack(spacing: 13) {
                emptyGameTile(title: "No recent games", subtitle: "Sign in and connect your library", symbol: "gamecontroller")
                emptyGameTile(title: "Your collection", subtitle: "Cloud games will show here", symbol: "square.grid.2x2")
                emptyGameTile(title: "Controller", subtitle: controllerManager.statusText, symbol: "gamecontroller.fill")
            }

            HStack(spacing: 12) {
                quickAction(title: "Browse Game Pass", symbol: "rectangle.stack.fill") { section = .discover }
                quickAction(title: "Console settings", symbol: "gearshape.fill") { section = .settings }
            }
        }
    }

    private var heroTile: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.12, green: 0.38, blue: 0.22), Color(red: 0.055, green: 0.15, blue: 0.10), panel],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(xboxGreen.opacity(0.15))
                .frame(width: 260, height: 260)
                .blur(radius: 3)
                .offset(x: 440, y: 55)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 145, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.075))
                .rotationEffect(.degrees(-20))
                .offset(x: 500, y: 28)

            VStack(alignment: .leading, spacing: 14) {
                Text("XBOX CLOUD GAMING")
                    .font(.system(size: 10, weight: .black))
                    .tracking(2.3)
                    .foregroundStyle(xboxGreen)
                Text("Play your way.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text("Your Xbox gaming space, built around a console-style experience.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: 410, alignment: .leading)
                Button {
                    showStreamStatus = true
                } label: {
                    Label("PLAY", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .black))
                        .tracking(1.2)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 25)
                        .frame(height: 44)
                        .background(xboxGreen, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
            .padding(.horizontal, 27)
            .padding(.vertical, 28)
        }
        .frame(minHeight: 265)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeading("MY GAMES", subtitle: "Your Xbox cloud-playable collection")
            emptyState(
                title: "Your library is waiting",
                detail: "The native Xbox sign-in and cloud catalog connection are part of the streaming-engine migration.",
                symbol: "square.grid.2x2.fill"
            )
        }
    }

    private var gamePassPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeading("GAME PASS", subtitle: "Discover games available to play in the cloud")
            emptyState(
                title: "Discover your next game",
                detail: "Game artwork, titles, and availability will load here after the Xbox catalog API is connected.",
                symbol: "rectangle.stack.fill"
            )
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeading("CONSOLE SETTINGS", subtitle: "XCloudPro app and streaming preferences")
            settingsRow("App version", value: appVersion, symbol: "number")
            settingsRow("Streaming engine", value: "Native WebRTC · integration pending", symbol: "dot.radiowaves.left.and.right")
            settingsRow("Controller", value: controllerManager.statusText, symbol: "gamecontroller")
            settingsRow("Target device", value: "iPad · iPadOS 18.1+", symbol: "ipad")
            VStack(alignment: .leading, spacing: 8) {
                Text("STREAMING OPTIONS")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.4)
                    .foregroundStyle(xboxGreen)
                Text("Resolution, frame rate, and bitrate controls will be enabled only when the native streaming session reports that the option is supported.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .tracking(1)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func emptyGameTile(title: String, subtitle: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(xboxGreen)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(14)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func quickAction(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(panel, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func emptyState(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(xboxGreen)
            Text(title)
                .font(.system(size: 17, weight: .bold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 55)
        .padding(.horizontal, 20)
        .background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func settingsRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(xboxGreen)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.53))
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .background(panel, in: RoundedRectangle(cornerRadius: 13))
    }
}
