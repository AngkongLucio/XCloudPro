import Combine
import Foundation
import SwiftUI
import UIKit
import WebRTC

enum NativeWebRTCState: Equatable {
    case idle
    case preparing
    case connecting
    case connected
    case failed(String)
}

/// Native receive-only WebRTC transport for an Xbox Cloud session.
/// It owns the peer connection and renders remote video through RTCMTLVideoView.
@MainActor
final class NativeWebRTCTransport: NSObject, ObservableObject {
    @Published private(set) var state: NativeWebRTCState = .idle
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var peerConnection: RTCPeerConnection?
    private var localCandidates: [RTCIceCandidate] = []
    private var iceGatheringContinuation: CheckedContinuation<[RTCIceCandidate], Error>?
    private var renderers: [RTCVideoRenderer] = []

    func start(using service: XboxCloudSessionService) async throws {
        guard peerConnection == nil else { return }
        state = .preparing
        localCandidates.removeAll()

        do {
            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            configuration.iceServers = []
            configuration.continualGatheringPolicy = .gatherOnce

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                    kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
                ],
                optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
            )

            guard let connection = Self.factory.peerConnection(
                with: configuration,
                constraints: constraints,
                delegate: self
            ) else {
                throw CloudSessionServiceError.invalidResponse
            }
            peerConnection = connection

            state = .connecting
            let offer = try await createOffer(on: connection, constraints: constraints)
            try await setLocalDescription(offer, on: connection)

            let answer = try await service.exchangeSDPOffer(offer.sdp)
            let remoteDescription = RTCSessionDescription(type: .answer, sdp: answer.sdp)
            try await setRemoteDescription(remoteDescription, on: connection)

            let gathered = try await waitForLocalICE()
            let outgoing = gathered.map {
                CloudICECandidate(
                    candidate: $0.sdp,
                    sdpMLineIndex: String($0.sdpMLineIndex),
                    sdpMid: $0.sdpMid ?? "0"
                )
            }
            let incoming = try await service.exchangeLocalICECandidates(outgoing)

            for item in incoming {
                if item.candidate == "a=end-of-candidates" { continue }
                let candidateText = item.candidate.hasPrefix("a=")
                    ? String(item.candidate.dropFirst(2))
                    : item.candidate
                let candidate = RTCIceCandidate(
                    sdp: candidateText,
                    sdpMLineIndex: Int32(item.sdpMLineIndex) ?? 0,
                    sdpMid: item.sdpMid
                )
                connection.add(candidate)
            }
        } catch {
            state = .failed(error.localizedDescription)
            closePeerConnection()
            throw error
        }
    }

    func stop() {
        closePeerConnection()
        state = .idle
    }

    func attach(renderer: RTCVideoRenderer) {
        if !renderers.contains(where: { $0 === renderer }) {
            renderers.append(renderer)
        }
        remoteVideoTrack?.add(renderer)
    }

    func detach(renderer: RTCVideoRenderer) {
        remoteVideoTrack?.remove(renderer)
        renderers.removeAll { $0 === renderer }
    }

    private func closePeerConnection() {
        iceGatheringContinuation?.resume(throwing: CancellationError())
        iceGatheringContinuation = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        remoteVideoTrack = nil
        localCandidates.removeAll()
    }

    private func createOffer(
        on connection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: CloudSessionServiceError.invalidResponse)
                }
            }
        }
    }

    private func setLocalDescription(
        _ description: RTCSessionDescription,
        on connection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemoteDescription(
        _ description: RTCSessionDescription,
        on connection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func waitForLocalICE() async throws -> [RTCIceCandidate] {
        guard let connection = peerConnection else {
            throw CloudSessionServiceError.invalidResponse
        }
        if connection.iceGatheringState == .complete {
            return localCandidates
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[RTCIceCandidate], Error>) in
            iceGatheringContinuation = continuation
            if connection.iceGatheringState == .complete {
                iceGatheringContinuation?.resume(returning: localCandidates)
                iceGatheringContinuation = nil
            }
        }
    }

    private func updateRemoteVideoTrack(_ track: RTCVideoTrack?) {
        if let oldTrack = remoteVideoTrack {
            renderers.forEach(oldTrack.remove)
        }
        remoteVideoTrack = track
        if let track {
            renderers.forEach(track.add)
        }
    }
}

extension NativeWebRTCTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let track = stream.videoTracks.first
        Task { @MainActor in self.updateRemoteVideoTrack(track) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in self.updateRemoteVideoTrack(nil) }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed:
                self.state = .connected
            case .failed:
                self.state = .failed("WebRTC ICE connection failed.")
            case .disconnected:
                self.state = .failed("WebRTC connection was disconnected.")
            case .closed:
                self.state = .idle
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in
            self.iceGatheringContinuation?.resume(returning: self.localCandidates)
            self.iceGatheringContinuation = nil
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in self.localCandidates.append(candidate) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        let track = transceiver.receiver.track as? RTCVideoTrack
        Task { @MainActor in self.updateRemoteVideoTrack(track) }
    }
}

struct NativeWebRTCVideoSurface: UIViewRepresentable {
    @ObservedObject var transport: NativeWebRTCTransport

    final class Coordinator {
        weak var transport: NativeWebRTCTransport?
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.transport = transport
        return coordinator
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        transport.attach(renderer: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.transport = transport
        transport.attach(renderer: uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.transport?.detach(renderer: uiView)
    }
}
