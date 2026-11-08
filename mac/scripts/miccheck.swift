// miccheck: records from "PhoneCam Mic" like a meeting app would and prints the level once a second. Nothing is saved.
// Recording from it also makes the phone stream (camera included), so expect the phone to go live.
//
//   swiftc -O mac/scripts/miccheck.swift -o build/miccheck && build/miccheck [seconds]
import AVFoundation
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 10 : 10

let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
print("Audio inputs: " + mics.map(\.localizedName).joined(separator: ", "))
guard let device = mics.first(where: { $0.localizedName == "PhoneCam Mic" }) else {
    print("RESULT: PhoneCam Mic NOT FOUND (driver not installed, or Core Audio not restarted)")
    exit(2)
}

let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .audio) { ok in
    if !ok { print("RESULT: microphone permission denied for this process"); exit(3) }
    sem.signal()
}
sem.wait()

final class Meter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var sumSquares = 0.0, count = 0, peak: Float = 0, total = 0, nonSilent = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
              bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
              flags: 0, blockBufferOut: &block) == noErr, let data = abl.mBuffers.mData else { return }
        let n = Int(abl.mBuffers.mDataByteSize) / 4
        let p = data.assumingMemoryBound(to: Float.self)
        lock.lock()
        for i in 0..<n { let v = p[i]; sumSquares += Double(v * v); peak = max(peak, abs(v)); if abs(v) > 1e-4 { nonSilent += 1 } }
        count += n; total += n
        lock.unlock()
    }
    func take() -> (rmsDB: Double, peak: Float, frames: Int, nonSilent: Int) {
        lock.lock(); defer { sumSquares = 0; count = 0; peak = 0; nonSilent = 0; lock.unlock() }
        let rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
        return (rms > 0 ? 20 * log10(rms) : -.infinity, peak, count, nonSilent)
    }
}

let session = AVCaptureSession()
session.addInput(try AVCaptureDeviceInput(device: device))
let output = AVCaptureAudioDataOutput()
let meter = Meter()
output.setSampleBufferDelegate(meter, queue: DispatchQueue(label: "audio"))
session.addOutput(output)
NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { n in
    print("session error: \(String(describing: n.userInfo?[AVCaptureSessionErrorKey]))")
}
session.startRunning()
var heard = 0
for s in 1...Int(seconds) {
    Thread.sleep(forTimeInterval: 1)
    let m = meter.take()
    if m.nonSilent > m.frames / 10 { heard += 1 }
    print(String(format: "%2ds  level %6.1f dBFS  peak %.3f  frames %5d  %@", s, m.rmsDB, m.peak, m.frames,
                 m.nonSilent > m.frames / 10 ? "sound" : "silence"))
}
session.stopRunning()
print("RESULT: \(heard)/\(Int(seconds)) seconds with sound from PhoneCam Mic")
exit(heard > 0 ? 0 : 1)
