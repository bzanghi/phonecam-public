import Foundation
@preconcurrency import WebRTC
import os
import PhoneCamCore

/// Receive-only WebRTC peer. The phone offers a video track (plus its microphone when this Mac asked for it); we answer
/// and hand decoded frames to the pipeline and decoded audio to [PhoneMicTap].
/// Host candidates only: no STUN/TURN servers, so media never leaves the local network.
/// All state is main-thread confined: public methods are called on main, and WebRTC's delegate callbacks hop to main
/// and are ignored unless they come from the current peer connection (a late callback from a closed one is stale).
final class WebRTCReceiver: NSObject, @unchecked Sendable {
    struct Stats: Equatable {
        var width = 0, height = 0
        var fps: Double = 0
        var codec = ""
        var bitrateKbps = 0
        var jitterBufferMs: Double = 0
        var decodeMs: Double = 0
        var packetsLost = 0
        var framesDropped = 0
        var freezes = 0
        var keyframeRequests = 0
        var roundTripMs: Double?
    }

    enum State: Equatable { case idle, connecting, connected, disconnected, failed }

    /// WebRTC's audio device: forwards the phone's mic to the PhoneCam Mic driver instead of playing it out loud.
    static let micTap = PhoneMicTap()

    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory(), audioDevice: micTap)
    }()

    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "webrtc")
    private var pc: RTCPeerConnection?
    private weak var renderer: RTCVideoRenderer?
    private var track: RTCVideoTrack?
    private var lastBytes: Int = 0
    private var lastStatsTime: TimeInterval = 0

    var onCandidate: ((RTCIceCandidate) -> Void)?
    var onState: ((State) -> Void)?

    init(renderer: RTCVideoRenderer) {
        self.renderer = renderer
    }

    func handleOffer(_ sdp: String, completion: @escaping (Result<String, Error>) -> Void) {
        close()
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.candidateNetworkPolicy = .all
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return completion(.failure(NSError(domain: "PhoneCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create peer connection"])))
        }
        self.pc = pc
        onState?(.connecting)
        // Only the connection that is still current may complete: a newer offer supersedes an in-flight answer.
        let finish: (Result<String, Error>) -> Void = { [weak self, weak pc] result in
            DispatchQueue.main.async {
                guard let self, let pc, pc === self.pc else { return }
                completion(result)
            }
        }
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak pc] error in
            guard let pc else { return }
            if let error { return finish(.failure(error)) }
            pc.answer(for: constraints) { [weak pc] answer, error in
                guard let pc else { return }
                guard let answer else { return finish(.failure(error ?? NSError(domain: "PhoneCam", code: 2))) }
                pc.setLocalDescription(answer) { error in
                    if let error { return finish(.failure(error)) }
                    finish(.success(answer.sdp))
                }
            }
        }
    }

    func addCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        guard LanAddress.isLANCandidate(sdp) else { return log.info("ignored non-LAN candidate") }
        pc?.add(RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)) { [weak self] error in
            if let error { self?.log.error("addCandidate: \(error.localizedDescription)") }
        }
    }

    func close() {
        if let track, let renderer { track.remove(renderer) }
        track = nil
        pc?.close()
        pc = nil
        lastBytes = 0
    }

    /// Inbound video stats for the menu and the stats log.
    func stats(_ completion: @escaping (Stats?) -> Void) {
        guard let pc else { return completion(nil) }
        pc.statistics { [weak self, weak pc] report in
            DispatchQueue.main.async {
                guard let self, let pc, pc === self.pc else { return completion(nil) }
                completion(self.parse(report))
            }
        }
    }

    private func parse(_ report: RTCStatisticsReport) -> Stats {
        var s = Stats()
        var codecs: [String: String] = [:]
        for (_, st) in report.statistics where st.type == "codec" {
            codecs[st.id] = (st.values["mimeType"] as? String)?.replacingOccurrences(of: "video/", with: "")
        }
        for (_, st) in report.statistics {
            let v = st.values
            if st.type == "inbound-rtp", (v["kind"] as? String) == "video" {
                s.width = (v["frameWidth"] as? NSNumber)?.intValue ?? 0
                s.height = (v["frameHeight"] as? NSNumber)?.intValue ?? 0
                s.fps = (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0
                s.packetsLost = (v["packetsLost"] as? NSNumber)?.intValue ?? 0
                s.framesDropped = (v["framesDropped"] as? NSNumber)?.intValue ?? 0
                s.freezes = (v["freezeCount"] as? NSNumber)?.intValue ?? 0
                s.keyframeRequests = (v["pliCount"] as? NSNumber)?.intValue ?? 0
                if let id = v["codecId"] as? String { s.codec = codecs[id] ?? "" }
                let emitted = (v["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue ?? 0
                if emitted > 0 { s.jitterBufferMs = ((v["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0) / emitted * 1000 }
                let decoded = (v["framesDecoded"] as? NSNumber)?.doubleValue ?? 0
                if decoded > 0 { s.decodeMs = ((v["totalDecodeTime"] as? NSNumber)?.doubleValue ?? 0) / decoded * 1000 }
                let bytes = (v["bytesReceived"] as? NSNumber)?.intValue ?? 0
                let now = st.timestamp_us / 1_000_000
                if self.lastStatsTime > 0, now > self.lastStatsTime, bytes >= self.lastBytes {
                    s.bitrateKbps = Int(Double(bytes - self.lastBytes) * 8 / 1000 / (now - self.lastStatsTime))
                }
                self.lastBytes = bytes
                self.lastStatsTime = now
            }
            if st.type == "candidate-pair", (v["nominated"] as? NSNumber)?.boolValue == true,
               let rtt = (v["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                s.roundTripMs = rtt * 1000
            }
        }
        return s
    }
}

extension WebRTCReceiver: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.info("ice state \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async { self.connectionChanged(peerConnection, newState) }
    }

    private func connectionChanged(_ peerConnection: RTCPeerConnection, _ newState: RTCPeerConnectionState) {
        guard peerConnection === pc else { return }
        let mapped: State
        switch newState {
        case .connected: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .idle
        default: mapped = .connecting
        }
        onState?(mapped)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async {
            // LAN only: never offer VPN-tunnel or global IPv6 candidates to the phone.
            guard peerConnection === self.pc, LanAddress.isLANCandidate(candidate.sdp) else { return }
            self.onCandidate?(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        DispatchQueue.main.async {
            if peerConnection === self.pc, rtpReceiver.track is RTCAudioTrack { self.log.info("audio track received") }
            guard peerConnection === self.pc, let video = rtpReceiver.track as? RTCVideoTrack, let renderer = self.renderer else { return }
            self.log.info("video track received")
            self.track = video
            video.add(renderer)
        }
    }
}
