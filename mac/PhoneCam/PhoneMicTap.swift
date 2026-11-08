import Foundation
import AudioToolbox
import Darwin
import os
import PhoneCamCore

/// WebRTC's audio device on the Mac. It never touches real audio hardware: WebRTC would otherwise play the phone's
/// microphone through the speakers. Instead it pulls the decoded audio (48 kHz mono) every 10 ms on its own thread and
/// forwards it to the "PhoneCam Mic" driver over loopback UDP (see `PhoneCamMic/PhoneCamMic.c` for the packet format).
/// No recording side: this Mac never sends audio to the phone.
final class PhoneMicTap: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let framesPerChunk = 480   // 10 ms

    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "mic")
    private let lock = NSLock()
    private var delegate: RTCAudioDeviceDelegate?
    private var thread: Thread?
    private var playing = false
    private var initialized = false
    private var playoutInitialized = false
    private var forwardOn = false
    private var delayFrames = 0
    private let socket: Int32 = Darwin.socket(AF_INET, SOCK_DGRAM, 0)

    /// Only Macs with the phone microphone switched on forward audio to the driver.
    var forwarding: Bool {
        get { lock.lock(); defer { lock.unlock() }; return forwardOn }
        set { lock.lock(); forwardOn = newValue; lock.unlock() }
    }

    /// Extra delay before the driver, to line the voice up with the video (`defaults write … PhoneCamMicDelayMs`).
    func setDelay(ms: Int) {
        lock.lock(); delayFrames = max(0, min(ms, 500)) * Int(Self.sampleRate) / 1000; lock.unlock()
    }

    // MARK: RTCAudioDevice

    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    /// The driver's buffer; WebRTC's lip sync counts it as playout delay.
    var outputLatency: TimeInterval { Double(PhoneMicConstants.targetFrames) / Self.sampleRate }

    var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initialized }
    var isPlayoutInitialized: Bool { lock.lock(); defer { lock.unlock() }; return playoutInitialized }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock(); self.delegate = delegate; initialized = true; lock.unlock()
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        lock.lock(); delegate = nil; initialized = false; playoutInitialized = false; lock.unlock()
        return true
    }

    func initializePlayout() -> Bool { lock.lock(); playoutInitialized = true; lock.unlock(); return true }

    func startPlayout() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !playing, let delegate else { return playing }
        playing = true
        let t = Thread { [weak self] in self?.run(delegate) }
        t.name = "phonecam-mic"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        log.info("phone mic playout started")
        return true
    }

    func stopPlayout() -> Bool {
        lock.lock(); playing = false; thread = nil; lock.unlock()
        return true
    }

    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }

    // MARK: Pull loop

    private func run(_ delegate: RTCAudioDeviceDelegate) {
        let n = Self.framesPerChunk
        var pcm = [Int16](repeating: 0, count: n)
        var delayLine: [Float] = []
        var packet = [UInt8](repeating: 0, count: 8 + n * 4)
        var seq: UInt32 = 0
        var sampleTime = 0.0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let chunkTicks = UInt64(Double(n) / Self.sampleRate * 1e9 * Double(timebase.denom) / Double(timebase.numer))
        var next = mach_absolute_time()
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(PhoneMicConstants.port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let getPlayout = delegate.getPlayoutData

        while isPlaying {
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mHostTime = next
            ts.mFlags = [.sampleTimeValid, .hostTimeValid]
            let status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 2), mData: raw.baseAddress))
                return getPlayout(&flags, &ts, 0, UInt32(n), &abl)
            }
            sampleTime += Double(n)
            lock.lock(); let forward = forwardOn; let delay = delayFrames; lock.unlock()
            if status == noErr, forward {
                delayLine.append(contentsOf: pcm.map { Float($0) / 32768 })
                if delayLine.count > delay + n * 4 { delayLine.removeFirst(delayLine.count - delay - n) }   // delay lowered
                if delayLine.count >= delay + n {
                    packet.withUnsafeMutableBytes { p in
                        p.storeBytes(of: PhoneMicConstants.magic.bigEndian, toByteOffset: 0, as: UInt32.self)
                        p.storeBytes(of: seq, toByteOffset: 4, as: UInt32.self)
                        delayLine.withUnsafeBytes { src in
                            (p.baseAddress! + 8).copyMemory(from: src.baseAddress!, byteCount: n * 4)
                        }
                    }
                    delayLine.removeFirst(n)
                    seq &+= 1
                    _ = withUnsafePointer(to: &addr) { a in
                        a.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socket, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            } else if !forward {
                delayLine.removeAll(keepingCapacity: true)
            }
            next += chunkTicks
            let now = mach_absolute_time()
            if next > now { mach_wait_until(next) } else if now - next > chunkTicks * 10 { next = now }   // fell far behind: resync
        }
        log.info("phone mic playout stopped")
    }

    deinit { close(socket) }
}
