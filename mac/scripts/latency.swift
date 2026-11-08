// latency: glass-to-glass estimate for Phone Camera .
// Flashes the main display black/white and times how long each change takes to show up in frames delivered by
// Phone Camera to an ordinary AVFoundation consumer (like a meeting app). The phone does not need to see the screen
// itself: the screen's light on your face or the room is enough, as long as the camera is pointed somewhere it lands.
// The figure includes the display's own output latency, so it is a slight overestimate of the camera path.
// With LATENCY_AUDIO=<output device name, e.g. "Speakers"> it also beeps on that output at each flip and times the beep
// through "PhoneCam Mic", which gives the lip-sync offset a meeting app sees (video latency minus audio latency).
// Esc aborts.
//
//   swiftc -O mac/scripts/latency.swift -o build/latency && [LATENCY_AUDIO=Speakers] build/latency [flips] [out.csv]
import AppKit
import AVFoundation
import CoreAudio
import QuartzCore

let flips = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20 : 20
let csvPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/phonecam-latency.csv"

guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
    .devices.first(where: { $0.localizedName == "Phone Camera" }) else {
    print("RESULT: Phone Camera NOT FOUND")
    exit(2)
}

final class Collector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var samples: [(t: CFTimeInterval, luma: Double)] = []
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var sum = 0, n = 0
        // Centre of the frame, where a face lit by the screen usually is; a bright window elsewhere would swamp the step.
        for y in stride(from: h * 3 / 10, to: h * 9 / 10, by: 4) {
            for x in stride(from: w * 3 / 10, to: w * 7 / 10, by: 4) {
                let o = y * row + x * 4  // BGRA
                sum += Int(p[o]) + 2 * Int(p[o + 1]) + Int(p[o + 2])
                n += 1
            }
        }
        lock.lock(); samples.append((now, Double(sum) / Double(n * 4))); lock.unlock()
    }
    func snapshot() -> [(t: CFTimeInterval, luma: Double)] { lock.lock(); defer { lock.unlock() }; return samples }
}

// MARK: Optional audio path: beep out of a speaker, hear it through PhoneCam Mic.

final class AudioCollector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var env: [(t: CFTimeInterval, rms: Double)] = []   // 5 ms windows, time of the window's last sample
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
              bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
              flags: 0, blockBufferOut: &block) == noErr, let data = abl.mBuffers.mData else { return }
        let n = Int(abl.mBuffers.mDataByteSize) / 4
        let p = data.assumingMemoryBound(to: Float.self)
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sampleBuffer)!)!.pointee.mSampleRate
        let win = Int(rate / 200)
        var out: [(CFTimeInterval, Double)] = []
        var i = 0
        while i + win <= n {
            var sq = 0.0
            for k in i..<(i + win) { sq += Double(p[k] * p[k]) }
            out.append((now - Double(n - i - win) / rate, (sq / Double(win)).squareRoot()))
            i += win
        }
        lock.lock(); env += out; lock.unlock()
    }
    func snapshot() -> [(t: CFTimeInterval, rms: Double)] { lock.lock(); defer { lock.unlock() }; return env }
}

func outputDevice(named part: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var name: CFString = "" as CFString
        var nsize = UInt32(MemoryLayout<CFString>.size)
        var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        AudioObjectGetPropertyData(id, &naddr, 0, nil, &nsize, &name)
        var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
        var ssize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize)
        if ssize > 0, (name as String).localizedCaseInsensitiveContains(part) { return id }
    }
    return nil
}

let audioOut = ProcessInfo.processInfo.environment["LATENCY_AUDIO"]
let audioCollector = AudioCollector()
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
var beep: AVAudioPCMBuffer?
let audioSession = AVCaptureSession()
if let audioOut {
    guard let outID = outputDevice(named: audioOut) else { print("RESULT: no output device matching \(audioOut)"); exit(2) }
    guard let mic = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        .devices.first(where: { $0.localizedName == "PhoneCam Mic" }) else { print("RESULT: PhoneCam Mic NOT FOUND"); exit(2) }
    var dev = outID
    AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
    let format = AVAudioFormat(standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate, channels: 1)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let frames = AVAudioFrameCount(format.sampleRate * 0.04)   // 40 ms, 2 kHz
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    b.frameLength = frames
    for i in 0..<Int(frames) { b.floatChannelData![0][i] = 0.8 * Float(sin(2 * Double.pi * 2000 * Double(i) / format.sampleRate)) }
    beep = b
    try engine.start()
    player.play()
    audioSession.addInput(try AVCaptureDeviceInput(device: mic))
    let out = AVCaptureAudioDataOutput()
    out.setSampleBufferDelegate(audioCollector, queue: DispatchQueue(label: "audio", qos: .userInteractive))
    audioSession.addOutput(out)
    audioSession.startRunning()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
window.level = .screenSaver
window.isOpaque = true
window.backgroundColor = .black
window.contentView!.wantsLayer = true
let layer = window.contentView!.layer!
layer.backgroundColor = NSColor.black.cgColor
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
NSCursor.hide()
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    if e.keyCode == 53 { print("RESULT: aborted"); exit(1) }
    return e
}

let session = AVCaptureSession()
session.addInput(try AVCaptureDeviceInput(device: device))
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
output.alwaysDiscardsLateVideoFrames = true
let collector = Collector()
output.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "frames", qos: .userInteractive))
session.addOutput(output)
session.startRunning()

var flipTimes: [(t: CFTimeInterval, white: Bool)] = []
var white = false

func setWhite(_ on: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.backgroundColor = (on ? NSColor.white : NSColor.black).cgColor
    CATransaction.commit()
    CATransaction.flush()
    flipTimes.append((CACurrentMediaTime(), on))
    if let beep { player.scheduleBuffer(beep, at: nil, options: .interrupts) }
}

/// Beep onset through PhoneCam Mic after each flip (ms), nil where no beep was found.
func audioLatencies() -> [Double?] {
    let env = audioCollector.snapshot()
    return flipTimes.enumerated().map { i, f in
        let next = i + 1 < flipTimes.count ? flipTimes[i + 1].t : f.t + 0.7
        let before = env.filter { $0.t > f.t - 0.15 && $0.t <= f.t }.map(\.rms)
        let after = env.filter { $0.t > f.t && $0.t < min(next, f.t + 0.7) }
        guard !before.isEmpty, let peak = after.map(\.rms).max() else { return nil }
        let base = before.sorted()[before.count / 2]
        guard peak > max(base * 4, 0.002) else { return nil }
        return after.first(where: { $0.rms >= base + (peak - base) / 2 }).map { ($0.t - f.t) * 1000 }
    }
}

func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

func analyse() -> Never {
    session.stopRunning()
    audioSession.stopRunning()
    let s = collector.snapshot()
    let audio = audioOut != nil ? audioLatencies() : []
    var csv = "flip,to_white,latency_ms,step,audio_ms\n"
    var lat: [Double] = []
    var offsets: [Double] = []
    for (i, f) in flipTimes.enumerated() {
        // Baseline: frames in the 200 ms before the flip. Response: frames up to 700 ms after (before the next flip).
        let next = i + 1 < flipTimes.count ? flipTimes[i + 1].t : f.t + 0.7
        let before = s.filter { $0.t > f.t - 0.2 && $0.t <= f.t }.map(\.luma)
        let after = s.filter { $0.t > f.t && $0.t < min(next, f.t + 0.7) }
        guard !before.isEmpty, !after.isEmpty else { continue }
        let base = median(before)
        let noise = before.map { abs($0 - base) }.max() ?? 0
        let dir: Double = f.white ? 1 : -1
        let peak = after.map { ($0.luma - base) * dir }.max() ?? 0
        let a = i < audio.count ? audio[i] : nil
        let aText = a.map { String(format: "%.1f", $0) } ?? ""
        guard peak > max(3 * noise, 1.5) else { csv += "\(i),\(f.white),,\(peak),\(aText)\n"; continue }
        // First frame past half the step: robust to auto-exposure pulling the level back afterwards.
        guard let hit = after.first(where: { ($0.luma - base) * dir >= peak / 2 }) else { continue }
        let ms = (hit.t - f.t) * 1000
        lat.append(ms)
        if let a { offsets.append(ms - a) }
        csv += String(format: "%d,%@,%.1f,%.2f,%@\n", i, f.white ? "true" : "false", ms, peak, aText)
    }
    try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)
    let fps = s.count > 1 ? Double(s.count - 1) / (s.last!.t - s.first!.t) : 0
    guard !lat.isEmpty else {
        print(String(format: "RESULT: no detectable flashes (frames=%d, %.1f fps). Point the camera where the screen's light lands.", s.count, fps))
        exit(1)
    }
    let sorted = lat.sorted()
    print(String(format: "RESULT: latency median %.0f ms, p90 %.0f ms, min %.0f ms, max %.0f ms over %d/%d flips (%.1f fps)",
                 median(lat), sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))], sorted.first!, sorted.last!,
                 lat.count, flipTimes.count, fps))
    if audioOut != nil {
        let heard = audio.compactMap { $0 }
        if heard.isEmpty { print("RESULT: audio: no beeps heard through PhoneCam Mic") } else {
            print(String(format: "RESULT: audio latency median %.0f ms over %d/%d beeps; video trails audio by median %.0f ms (min %.0f, max %.0f)",
                         median(heard), heard.count, flipTimes.count, median(offsets), offsets.min() ?? .nan, offsets.max() ?? .nan))
        }
    }
    print("per-flip: \(csvPath)")
    exit(0)
}

// Give the phone time to go from Ready to live, then flip at irregular intervals so nothing locks to the frame clock.
func step(_ remaining: Int) {
    guard remaining > 0 else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { analyse() }; return }
    white.toggle()
    setWhite(white)
    DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.9...1.4)) { step(remaining - 1) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    if collector.snapshot().isEmpty { print("RESULT: Phone Camera delivered no frames in 5 s (is the phone connected?)"); exit(1) }
    step(flips)
}
app.run()
