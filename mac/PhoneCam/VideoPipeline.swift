import Foundation
@preconcurrency import AVFoundation
import CoreImage
import Accelerate
import CoreVideo
@preconcurrency import WebRTC
import os
import PhoneCamCore
import PhoneCamShared

/// Decoded phone frames -> upright 1920x1080 frames -> camera extension sink + menu preview.
/// When there is no live video it sends a placeholder describing why, so meeting apps never freeze on a stale image.
/// Thread confinement (checked by review, not the compiler): pipeline state lives on `queue`; the decode thread only
/// touches `pending` and the I420 pool; `previewVisible` is lock-protected.
final class VideoPipeline: NSObject, RTCVideoRenderer, @unchecked Sendable {
    struct Snapshot: Equatable {
        var sinkConnected = false
        var sinkError: String?
        var outputFPS: Double = 0
        var sourceWidth = 0
        var sourceHeight = 0
        var rotation = 0
        var live = false
        var consumers: Int?          // apps reading "Phone Camera"; nil if the extension doesn't say
        var droppedFrames = 0        // decoded frames skipped because compositing fell behind
    }

    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "pipeline")
    private let queue = DispatchQueue(label: "phonecam.pipeline", qos: .userInteractive)
    private let compositor = FrameCompositor()
    private let sink = CameraSink()
    private var timer: DispatchSourceTimer?
    private let pending = LatestFrameSlot<(CVPixelBuffer, Int)>()
    private var lastLiveFrame: TimeInterval = 0
    private var lastSinkAttempt: TimeInterval = 0
    private var lastSinkCheck: TimeInterval = 0
    private var lastConsumerPoll: TimeInterval = 0
    private var requestedCameraAccess = false
    private var placeholder = PlaceholderRenderer.Content(title: PhoneCamConstants.cameraName, subtitle: "Starting…")
    private var placeholderBuffer: CVPixelBuffer?
    private var frameTimes: [TimeInterval] = []
    private var snapshot = Snapshot()
    private var testPattern = UserDefaults.standard.bool(forKey: "PhoneCamTestPattern")
    private var testPhase = 0
    private var nv12Pool: CVPixelBufferPool?
    private var nv12Size = (0, 0)

    /// Receives composited frames on the main queue, only while the menu is open.
    weak var previewLayer: AVSampleBufferDisplayLayer?
    private let previewLock = NSLock()
    private var previewOn = false
    var onSnapshot: ((Snapshot) -> Void)?

    /// Set from the menu's window visibility; also counts as demand for the phone's camera (framing check).
    var previewVisible: Bool {
        get { previewLock.lock(); defer { previewLock.unlock() }; return previewOn }
        set { previewLock.lock(); previewOn = newValue; previewLock.unlock() }
    }

    func start() {
        CameraSink.watchDevices(queue: queue) { [weak self] in
            guard let self else { return }
            self.log.info("camera device list changed")
            if self.sink.state != .connected { self.lastSinkAttempt = 0 } else if !self.sink.isHealthy() { self.sink.disconnect(); self.lastSinkAttempt = 0 }
        }
        queue.async {
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / 15.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func setPlaceholder(_ content: PlaceholderRenderer.Content) {
        queue.async {
            guard content != self.placeholder else { return }
            self.placeholder = content
            self.placeholderBuffer = nil
        }
    }

    func setTestPattern(_ on: Bool) { queue.async { self.testPattern = on } }

    func reconnectSink() {
        queue.async {
            self.sink.disconnect()
            self.lastSinkAttempt = 0
        }
    }

    // MARK: RTCVideoRenderer (WebRTC decode thread)

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let rotation = frame.rotation.rawValue
        let pixelBuffer: CVPixelBuffer?
        if let cv = frame.buffer as? RTCCVPixelBuffer {
            pixelBuffer = cv.pixelBuffer
        } else {
            pixelBuffer = convertI420(frame.buffer.toI420())
        }
        guard let pixelBuffer else { return }
        logColorTags(pixelBuffer)
        // Keep only the newest frame if compositing falls behind; latency matters more than every frame.
        if pending.put((pixelBuffer, Int(rotation))) { queue.async { self.drainFrame() } }
    }

    private var lastColorTags = ""

    /// Logs the decoded frames' pixel format and colour tags whenever they change (decode thread only).
    private func logColorTags(_ buffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fourCC = String((0..<4).map { Character(UnicodeScalar(UInt8((format >> (24 - $0 * 8)) & 0xFF))) })
        func tag(_ key: CFString) -> String {
            (CVBufferCopyAttachment(buffer, key, nil) as? String).map { $0.replacingOccurrences(of: "ITU_R_", with: "") } ?? "none"
        }
        let tags = "\(fourCC) matrix=\(tag(kCVImageBufferYCbCrMatrixKey)) primaries=\(tag(kCVImageBufferColorPrimariesKey)) transfer=\(tag(kCVImageBufferTransferFunctionKey))"
        guard tags != lastColorTags else { return }
        lastColorTags = tags
        log.info("decoded frames: \(tags, privacy: .public)")
    }

    // MARK: Pipeline queue

    private func drainFrame() {
        guard let (pixelBuffer, rotation) = pending.take() else { return }
        lastLiveFrame = ProcessInfo.processInfo.systemUptime
        snapshot.sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        snapshot.sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        snapshot.rotation = rotation
        if let out = compositor.composite(pixelBuffer, rotation: rotation) { output(out) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // The extension can go away under us (crash, upgrade): reconnect instead of feeding a dead queue.
        if sink.state == .connected, now - lastSinkCheck > 2 {
            lastSinkCheck = now
            if !sink.isHealthy(now: now) {
                log.info("camera extension stopped consuming; reconnecting the sink")
                sink.disconnect()
                lastSinkAttempt = 0
            }
        }
        if now - lastConsumerPoll >= 1 {
            lastConsumerPoll = now
            snapshot.consumers = sink.consumerCount()
        }
        if sink.state != .connected, now - lastSinkAttempt > 2 {
            lastSinkAttempt = now
            // macOS hides camera devices, including our own extension's, from apps without camera permission.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                if !requestedCameraAccess {
                    requestedCameraAccess = true
                    AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in self?.queue.async { self?.lastSinkAttempt = 0 } }
                }
                snapshot.sinkError = "Allow PhoneCam to use the camera so it can feed “Phone Camera”."
                snapshot.sinkConnected = false
            case .denied, .restricted:
                snapshot.sinkError = "PhoneCam needs camera access to feed “Phone Camera”: System Settings › Privacy & Security › Camera › PhoneCam."
                snapshot.sinkConnected = false
            default:
                let state = sink.connect()
                if state != .connected { log.debug("sink not connected: \(String(describing: state))") }
                snapshot.sinkConnected = state == .connected
                if case .failed(let message) = state { snapshot.sinkError = message } else { snapshot.sinkError = nil }
            }
        }
        let live = now - lastLiveFrame < 0.5
        snapshot.live = live
        if !live {
            if testPattern {
                if let out = compositor.makeBuffer() { drawTestPattern(out); output(out) }
            } else {
                if placeholderBuffer == nil { placeholderBuffer = compositor.placeholder(placeholder) }
                if let p = placeholderBuffer { output(p) }
            }
        }
        publish(now)
    }

    private func publish(_ now: TimeInterval) {
        frameTimes.removeAll { now - $0 > 1 }
        snapshot.outputFPS = Double(frameTimes.count)
        snapshot.droppedFrames = pending.droppedCount
        let s = snapshot
        DispatchQueue.main.async { self.onSnapshot?(s) }
    }

    private var lastOutput: CVPixelBuffer?

    func writeSnapshot(to url: URL) {
        queue.async {
            guard let buffer = self.lastOutput else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            let ctx = CIContext()
            try? ctx.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)   // it's a camera frame
        }
    }

    private func output(_ pixelBuffer: CVPixelBuffer) {
        lastOutput = pixelBuffer
        guard let sbuf = compositor.sampleBuffer(for: pixelBuffer) else { return }
        frameTimes.append(ProcessInfo.processInfo.systemUptime)
        if sink.state == .connected { sink.enqueue(sbuf) }
        guard previewVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.previewLayer else { return }
            if layer.status == .failed { layer.flush() }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true) as? [NSMutableDictionary] {
                attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            layer.enqueue(sbuf)
        }
    }

    /// Moving bars + timestamp, used to verify the extension path without a phone (defaults write ... PhoneCamTestPattern -bool YES).
    private func drawTestPattern(_ buffer: CVPixelBuffer) {
        testPhase = (testPhase + 8) % CVPixelBufferGetWidth(buffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let colors: [CGColor] = [.white, CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
                                 CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
                                 CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
        let barW = CGFloat(w) / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: 0, width: barW, height: CGFloat(h)))
        }
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: CGFloat(testPhase), y: 0, width: 24, height: CGFloat(h)))
    }

    /// VP8/VP9 frames arrive as I420; repack them into a biplanar CVPixelBuffer for CoreImage.
    private func convertI420(_ i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let w = Int(i420.width), h = Int(i420.height)
        if nv12Pool == nil || nv12Size != (w, h) {
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &nv12Pool)
            nv12Size = (w, h)
        }
        guard let nv12Pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, nv12Pool, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let yDst = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        for row in 0..<h {
            memcpy(yDst + row * yStride, i420.dataY + row * Int(i420.strideY), w)
        }
        let uvDst = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        // Interleave U and V into the CbCr plane with vImage (SIMD) instead of a per-pixel loop.
        var u = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataU), height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: Int(i420.strideU))
        var v = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataV), height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: Int(i420.strideV))
        withUnsafePointer(to: &u) { up in
            withUnsafePointer(to: &v) { vp in
                var planes: [UnsafePointer<vImage_Buffer>?] = [up, vp]
                var dest: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(uvDst), UnsafeMutableRawPointer(uvDst + 1)]
                vImageConvert_PlanarToChunky8(&planes, &dest, 2, 2, vImagePixelCount(cw), vImagePixelCount(ch), uvStride, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }
}
