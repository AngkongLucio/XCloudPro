import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controllerManager: ControllerManager
    @State private var isPlaying = false
    @State private var reloadToken = UUID()

    private let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    private let green = Color(red: 0.20, green: 0.78, blue: 0.35)

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if isPlaying {
                XboxWebView(reloadToken: reloadToken)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button { isPlaying = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.black.opacity(0.65), in: Circle())
                        }
                        .padding()
                        .accessibilityLabel("Close game")
                    }
            } else {
                dashboard
            }
        }
        .statusBarHidden(isPlaying)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(green)
                Text("XCloud")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("PRO")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(green, in: Capsule())
                Spacer()
                Image(systemName: "wifi").foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 14) {
                Text("YOUR GAMES. YOUR CLOUD.")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(green)
                Text("Play beyond\nthe console.")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                Text("Launch Xbox Cloud Gaming from one clean, controller-ready experience.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: 540, alignment: .leading)

                Button { isPlaying = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                        Text("PLAY NOW").tracking(1.2)
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 17)
                    .background(green, in: Capsule())
                }
                .padding(.top, 8)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Image(systemName: "gamecontroller").foregroundStyle(green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CONTROLLER")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(controllerManager.statusText)
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer()
                Text("iPadOS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(18)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
    }
}
