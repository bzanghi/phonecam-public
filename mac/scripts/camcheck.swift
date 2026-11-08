// camcheck: a minimal real camera consumer (AVFoundation), like a meeting app.
// Lists video devices; if "Phone Camera" exists, captures for N seconds and reports resolution, frame rate,
// whether frames changed, and writes the last frame as PNG.
//
//   swiftc -O mac/scripts/camcheck.swift -o build/camcheck && build/camcheck [seconds] [out.png]
import AVFoundation
import CoreImage
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 5 : 5
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/phonecam-camcheck.png"

let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                 mediaType: .video, position: .unspecified)
print("Video devices:")
for d in discovery.devices { print("  - \(d.localizedName) [\(d.uniqueID)] model=\(d.modelID)") }
guard let device = discovery.devices.first(where: { $0.localizedName == "Phone Camera" }) else {
    print("RESULT: Phone Camera NOT FOUND")
    exit(2)
}
for f in device.formats {
    let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    print("  format \(dims.width)x\(dims.height) \(f.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" })")
}

let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { ok in
    if !ok { print("RESULT: camera permission denied for this process"); exit(3) }
    sem.signal()
}
sem.wait()

final class Collector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var count = 0
    var first: CFTimeInterval = 0
    var last: CFTimeInterval = 0
    var size = CGSize.zero
    var lastBuffer: CVPixelBuffer?
    var distinctChecksums = Set<Int>()
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        if count == 0 { first = now }
        last = now
        count += 1
        size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        lastBuffer = pb
        // Cheap content fingerprint: sample a row of bytes.
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let p = base.assumingMemoryBound(to: UInt8.self)
            var h = 0
            let stride = CVPixelBufferGetBytesPerRow(pb)
            for i in Swift.stride(from: 0, to: min(stride * CVPixelBufferGetHeight(pb), 4_000_000), by: 4093) { h = h &* 31 &+ Int(p[i]) }
            distinctChecksums.insert(h)
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
}

let session = AVCaptureSession()
let input = try AVCaptureDeviceInput(device: device)
session.addInput(input)
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
let collector = Collector()
output.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "frames"))
session.addOutput(output)
session.startRunning()
Thread.sleep(forTimeInterval: seconds)
session.stopRunning()

let fps = collector.count > 1 ? Double(collector.count - 1) / (collector.last - collector.first) : 0
print(String(format: "RESULT: frames=%d size=%dx%d fps=%.1f distinct=%d", collector.count, Int(collector.size.width),
             Int(collector.size.height), fps, collector.distinctChecksums.count))
if let pb = collector.lastBuffer {
    let ctx = CIContext()
    try ctx.writePNGRepresentation(of: CIImage(cvPixelBuffer: pb), to: URL(fileURLWithPath: outPath), format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("snapshot: \(outPath)")
}
exit(collector.count > 0 ? 0 : 1)
