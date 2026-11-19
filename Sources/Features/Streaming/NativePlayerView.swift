import SwiftUI

struct NativePlayerView: View {
    @ObservedObject var coordinator: NativeStreamCoordinator
    let onExit: () -> Void

    @State private var showQuickMenu = false
    @AppStorage("xcloudpro.showNetworkStats") private var showStats = true
    @AppStorage("xcloudpro.videoAspect") private var videoAspect = "16:9"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                let viewport = videoViewport(for: proxy.size)
                NativeWebRTCVideoSurface(transport: coordinator.transport)
                    .frame(width: viewport.width, height: viewport.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        showQuickMenu.toggle()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    Spacer()
                    if showStats {
                        Text(coordinator.isStreaming ? "CLOUD STREAM" : "CONNECTING")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(coordinator.isStreaming ? Color.green : Color.orange)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                }
                Spacer()
                if let error = coordinator.lastError {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)

            if showQuickMenu {
                quickMenu
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .statusBarHidden()
    }

    private func videoViewport(for size: CGSize) -> CGSize {
        guard videoAspect != "fill" else { return size }
        let ratioParts = videoAspect.split(separator: ":").compactMap { Double($0) }
        guard ratioParts.count == 2, ratioParts[1] > 0 else {
            let ratio = 16.0 / 9.0
            if size.width / size.height > ratio {
                return CGSize(width: size.height * ratio, height: size.height)
            }
            return CGSize(width: size.width, height: size.width / ratio)
        }
        let ratio = ratioParts[0] / ratioParts[1]
        if size.width / size.height > ratio {
            return CGSize(width: size.height * ratio, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / ratio)
    }

    private var quickMenu: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("QUICK MENU")
                    .font(.system(size: 11, weight: .black))
                    .tracking(1.6)
                Spacer()
                Button {
                    showQuickMenu = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                }
            }

            Toggle("Connection status", isOn: $showStats)
                .font(.system(size: 13, weight: .medium))
                .tint(Color.green)

            Text(coordinator.transport.state == .connected ? "WebRTC connected" : "WebRTC not connected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))

            VStack(alignment: .leading, spacing: 6) {
                Text("MEDIA DIAGNOSTICS")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(Color.green)
                Text(coordinator.transport.mediaDiagnostics)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Audio: \(coordinator.transport.remoteAudioTrackPresent ? "TRACK" : "NONE")  •  Video: \(coordinator.transport.remoteVideoTrackPresent ? "TRACK" : "NONE")")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            Button(role: .destructive) {
                Task {
                    await coordinator.stop()
                    onExit()
                }
            } label: {
                Label("End stream", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 280)
        .background(Color(red: 0.075, green: 0.085, blue: 0.10).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 18)
    }
}
