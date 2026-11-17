import SwiftUI

private enum ConsoleSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case library = "My games"
    case discover = "Discover"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .discover: return "safari.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controllerManager: ControllerManager
    @State private var section: ConsoleSection = .home
    @State private var isPlaying = false
    @State private var reloadToken = UUID()

    private let background = Color(red: 0.035, green: 0.043, blue: 0.055)
    private let panel = Color(red: 0.075, green: 0.09, blue: 0.105)
    private let xboxGreen = Color(red: 0.20, green: 0.78, blue: 0.35)

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if isPlaying {
                XboxWebView(reloadToken: reloadToken)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isPlaying = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.black.opacity(0.72), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                        .accessibilityLabel("Close Xbox Cloud Gaming")
                    }
            } else {
                consoleLayout
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(isPlaying)
    }

    private var consoleLayout: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: geometry.size.width < 700 ? 76 : 218)

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
                            case .discover: discoverPage
                            case .settings: settingsPage
                            }
                        }
                        .frame(maxWidth: 1120, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, geometry.size.width < 700 ? 20 : 34)
                        .padding(.top, 22)
                        .padding(.bottom, 34)
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "xbox.logo")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(xboxGreen)
                if horizontalLabels {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("XCLOUD")
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .tracking(1.2)
                        Text("PRO CONSOLE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .padding(.horizontal, horizontalLabels ? 22 : 0)
            .frame(maxWidth: .infinity, alignment: horizontalLabels ? .leading : .center)
            .padding(.top, 28)
            .padding(.bottom, 38)

            ForEach(ConsoleSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 22)
                        if horizontalLabels {
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(section == item ? .white : .white.opacity(0.58))
                    .padding(.horizontal, horizontalLabels ? 15 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(xboxGreen.opacity(0.18))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(xboxGreen).frame(width: 3).padding(.vertical, 9)
                                }
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }

            Spacer()

            if horizontalLabels {
                HStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(xboxGreen)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CONTROLLER")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.4))
                        Text(controllerManager.statusText)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }

    private var horizontalLabels: Bool { true }

    private var topBar: some View {
        HStack {
            Text(section.rawValue.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(xboxGreen).frame(width: 7, height: 7)
                Text("CLOUD READY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.06), in: Capsule())
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 27))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.leading, 8)
        }
        .padding(.horizontal, 28)
        .frame(height: 70)
        .background(background.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 26) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.10, green: 0.34, blue: 0.20), Color(red: 0.055, green: 0.13, blue: 0.095), panel],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .fill(xboxGreen.opacity(0.14))
                    .frame(width: 300, height: 300)
                    .blur(radius: 2)
                    .offset(x: 420, y: 60)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 150, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.08))
                    .rotationEffect(.degrees(-18))
                    .offset(x: 510, y: 30)

                VStack(alignment: .leading, spacing: 16) {
                    Text("XBOX CLOUD GAMING")
                        .font(.system(size: 11, weight: .black))
                        .tracking(2.4)
                        .foregroundStyle(xboxGreen)
                    Text("Your next game\nis one click away.")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                    Text("Jump into your cloud library and pick up where you left off.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(maxWidth: 420, alignment: .leading)
                    Button {
                        launchCloud()
                    } label: {
                        Label("PLAY NOW", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .black))
                            .tracking(1)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 23)
                            .frame(height: 48)
                            .background(xboxGreen, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 30)
            }
            .frame(minHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24))

            HStack {
                sectionHeading("JUMP BACK IN", subtitle: "Continue with Xbox Cloud Gaming")
                Spacer()
                Button("OPEN LIBRARY") { section = .library }
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(xboxGreen)
            }

            HStack(spacing: 14) {
                quickTile(title: "Cloud Library", detail: "Browse playable games", symbol: "square.grid.2x2.fill") {
                    launchCloud()
                }
                quickTile(title: "Better xCloud", detail: "Stream enhancements", symbol: "slider.horizontal.3") {
                    launchCloud()
                }
                quickTile(title: "Controller", detail: controllerManager.statusText, symbol: "gamecontroller.fill") {
                    section = .settings
                }
            }
        }
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeading("MY GAMES", subtitle: "Your Xbox Cloud Gaming library")
            Button { launchCloud() } label: {
                HStack(spacing: 18) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(xboxGreen)
                        .frame(width: 82, height: 82)
                        .background(xboxGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Open Xbox game library")
                            .font(.system(size: 18, weight: .bold))
                        Text("Sign in to view your cloud-playable games.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(xboxGreen)
                }
                .padding(20)
                .background(panel, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
    }

    private var discoverPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeading("DISCOVER", subtitle: "Explore games on Xbox Cloud Gaming")
            Button { launchCloud() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EXPLORE XBOX")
                            .font(.system(size: 10, weight: .black))
                            .tracking(2)
                            .foregroundStyle(xboxGreen)
                        Text("Find your next\nfavorite game.")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Text("Open the official Xbox Cloud Gaming catalog.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(xboxGreen.opacity(0.8))
                }
                .padding(26)
                .background(
                    LinearGradient(colors: [Color(red: 0.10, green: 0.25, blue: 0.16), panel], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeading("SETTINGS", subtitle: "XCloud Pro console and app information")
            settingsRow("App version", value: appVersion, symbol: "number")
            settingsRow("Web engine", value: "Apple WKWebView", symbol: "globe")
            settingsRow("Controller", value: controllerManager.statusText, symbol: "gamecontroller")
            settingsRow("Better xCloud", value: "Injected userscript · experimental", symbol: "slider.horizontal.3")
            VStack(alignment: .leading, spacing: 8) {
                Text("STREAMING")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.5)
                    .foregroundStyle(xboxGreen)
                Text("Xbox Cloud Gaming handles your account, game catalog, and stream quality. Better xCloud options appear inside the Xbox player when the script initializes successfully.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .tracking(1.1)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func quickTile(title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(xboxGreen)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func settingsRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(xboxGreen)
                .frame(width: 30)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.trailing)
        }
        .padding(17)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func launchCloud() {
        reloadToken = UUID()
        isPlaying = true
    }
}
