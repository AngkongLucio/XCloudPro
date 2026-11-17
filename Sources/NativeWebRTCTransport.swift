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
    private var inputDataChannel: RTCDataChannel?
    private var controlDataChannel: RTCDataChannel?
    private var messageDataChannel: RTCDataChannel?
    private var inputSequence: UInt32 = 0
    private var latestGamepadState = XboxGamepadState.neutral
    private var inputTask: Task<Void, Never>?
    private var localCandidates: [RTCIceCandidate] = []
    private var iceGatheringContinuation: CheckedContinuation<[RTCIceCandidate], Error>?
    private var renderers: [RTCVideoRenderer] = []
    private var openedDataChannels = Set<ObjectIdentifier>()

    func attachControllerManager(_ manager: ControllerManager) {
        manager.onGamepadStateChanged = { [weak self] state in
            self?.sendGamepadState(state)
        }
    }

    func start(using service: XboxCloudSessionService) async throws {
        guard peerConnection == nil else { return }
        state = .preparing
        localCandidates.removeAll()

        do {
            let configuration = RTCConfiguration()
            // Xbox exchanges ICE candidates through its own HTTPS signaling API.
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
            try createXboxDataChannels(on: connection)

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
                try await connection.add(candidate)
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
        inputTask?.cancel()
        inputTask = nil
        inputDataChannel?.delegate = nil
        controlDataChannel?.delegate = nil
        messageDataChannel?.delegate = nil
        inputDataChannel = nil
        controlDataChannel = nil
        messageDataChannel = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        remoteVideoTrack = nil
        localCandidates.removeAll()
        openedDataChannels.removeAll()
    }

    /// The Xbox offer must include the ordered control/input/message/chat
    /// channels before SDP is created; otherwise the server cannot negotiate them.
    private func createXboxDataChannels(on connection: RTCPeerConnection) throws {
        let definitions: [(String, String)] = [
            ("control", "controlV1"),
            ("input", "1.0"),
            ("message", "messageV1"),
            ("chat", "chatV1")
        ]
        for (label, protocolName) in definitions {
            let configuration = RTCDataChannelConfiguration()
            configuration.isOrdered = true
            configuration.`protocol` = protocolName
            guard let channel = connection.dataChannel(forLabel: label, configuration: configuration) else {
                throw CloudSessionServiceError.invalidResponse
            }
            channel.delegate = self
            switch label {
            case "input": inputDataChannel = channel
            case "control": controlDataChannel = channel
            case "message": messageDataChannel = channel
            default: break
            }
        }
    }

    private func handleOpenedDataChannel(_ channel: RTCDataChannel) {
        guard channel.readyState == .open,
              openedDataChannels.insert(ObjectIdentifier(channel)).inserted else { return }
        channel.delegate = self
        switch channel.label.lowercased() {
        case "input":
            inputDataChannel = channel
            sendClientMetadata()
            startInputLoop()
        case "control":
            controlDataChannel = channel
            sendControlMessage([
                "message": "authorizationRequest",
                "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"
            ])
            sendControlMessage([
                "message": "gamepadChanged",
                "gamepadIndex": 0,
                "wasAdded": true
            ])
            sendControlMessage([
                "message": "gamepadChanged",
                "gamepadIndex": 0,
                "wasAdded": false
            ])
            sendControlMessage([
                "message": "VideoPreference",
                "type": "VideoPreference",
                "resolution": ["width": 1920, "height": 1080],
                "dimensions": ["width": 1920, "height": 1080],
                "maxFPS": 60
            ])
        case "message":
            messageDataChannel = channel
            sendMessageHandshake()
        case "chat":
            _ = channel.sendData(RTCDataBuffer(data: Data(#"{"message":"chatReady"}"#.utf8), isBinary: false))
        default:
            break
        }
    }

    private func sendMessageHandshake() {
        guard let channel = messageDataChannel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: [
                "type": "Handshake",
                "version": "messageV1",
                "id": "be0bfc6d-1e83-4c8a-90ed-fa8601c5a179",
                "cv": "0"
              ]) else { return }
        _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func sendControlMessage(_ object: [String: Any]) {
        guard let channel = controlDataChannel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8),
              let textData = text.data(using: .utf8) else { return }
        _ = channel.sendData(RTCDataBuffer(data: textData, isBinary: false))
    }

    private func sendClientMetadata() {
        guard let channel = inputDataChannel, channel.readyState == .open else { return }
        var packet = Data()
        packet.appendLittleEndian(UInt16(8)) // ClientMetadata report
        packet.appendLittleEndian(inputSequence)
        var timestamp = Double(ProcessInfo.processInfo.systemUptime * 1_000)
        Swift.withUnsafeBytes(of: &timestamp) { packet.append(contentsOf: $0) }
        packet.append(1) // Maximum simultaneous touch points
        inputSequence &+= 1
        _ = channel.sendData(RTCDataBuffer(data: packet, isBinary: true))
    }

    private func sendGamepadState(_ state: XboxGamepadState) {
        latestGamepadState = state
    }

    /// Xbox input is sent at 125 Hz. Controller callbacks only update the latest
    /// snapshot; this loop coalesces changes instead of queueing stale button events.
    private func startInputLoop() {
        inputTask?.cancel()
        inputTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sendGamepadPacket(self.latestGamepadState)
                do {
                    try await Task.sleep(nanoseconds: 8_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func sendGamepadPacket(_ state: XboxGamepadState) {
        guard let channel = inputDataChannel, channel.readyState == .open else { return }
        var packet = Data()
        packet.appendLittleEndian(UInt16(2)) // Gamepad report
        packet.appendLittleEndian(inputSequence)
        var timestamp = Double(ProcessInfo.processInfo.systemUptime * 1_000)
        Swift.withUnsafeBytes(of: &timestamp) { packet.append(contentsOf: $0) }
        packet.append(1) // One gamepad frame
        packet.append(0) // Primary controller index
        packet.appendLittleEndian(state.buttons)
        packet.appendLittleEndian(state.leftX)
        packet.appendLittleEndian(state.leftY)
        packet.appendLittleEndian(state.rightX)
        packet.appendLittleEndian(state.rightY)
        packet.appendLittleEndian(state.leftTrigger)
        packet.appendLittleEndian(state.rightTrigger)
        packet.appendLittleEndian(UInt32(1)) // Physical controller (little-endian)
        packet.appendBigEndian(UInt32(1)) // Virtual controller (big-endian)
        inputSequence &+= 1
        _ = channel.sendData(RTCDataBuffer(data: packet, isBinary: true))
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

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in self.handleOpenedDataChannel(dataChannel) }
    }

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


extension NativeWebRTCTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor in self.handleOpenedDataChannel(dataChannel) }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
