import Foundation
@preconcurrency import CoreMediaIO
import CoreMedia
import CoreVideo
import IOKit.audio
import VideoToolbox
import os
import PhoneCamShared

// Based on Apple's Camera Extension template (Xcode > macOS > System Extension > Camera Extension),
// extended with a sink stream so the PhoneCam app can feed frames through CoreMediaIO.

private let log = Logger(subsystem: "com.zanghi.phonecam.camera-extension", category: "provider")

/// Frame state is confined to `queue`; the consumer count copy is lock-protected.
final class PhoneCamDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: PhoneCamStreamSource!
    private var sinkStream: PhoneCamSinkSource!

    /// All frame state is confined to this queue.
    private let queue = DispatchQueue(label: "phonecam.extension.frames", qos: .userInteractive)
    private var sourceTimer: DispatchSourceTimer?
    private var sinkTimer: DispatchSourceTimer?
    private var streamingCounter = 0
    private var sinkClient: CMIOExtensionClient?

    private var latestFrame: CVPixelBuffer?
    private var latestFrameHostTime: TimeInterval = 0
    private var lastSent: (frame: CVPixelBuffer, format: Int)?
    private var lastSendTime: TimeInterval = 0
    private let consumerCount = CMIOExtensionProperty(rawValue: PhoneCamConstants.consumerCountProperty)
    /// Copy of streamingCounter readable from CMIO's property queue without hopping onto `queue`.
    private let countLock = NSLock()
    private var publishedCount = 0
    private var formats: [(desc: CMFormatDescription, pool: CVPixelBufferPool, placeholder: CVPixelBuffer)] = []
    private var sinkFormat: CMFormatDescription!
    private var activeFormat = 0
    private var transfer: VTPixelTransferSession?

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: PhoneCamConstants.deviceID,
                                     legacyDeviceID: PhoneCamConstants.deviceID.uuidString, source: self)

        let placeholder = PlaceholderRenderer.Content(title: "Open PhoneCam on your Mac", subtitle: "")
        for dims in PhoneCamConstants.sourceDimensions {
            var desc: CMFormatDescription!
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: PhoneCamConstants.pixelFormat,
                                           width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &desc)
            let attrs: NSDictionary = [
                kCVPixelBufferWidthKey: dims.width,
                kCVPixelBufferHeightKey: dims.height,
                kCVPixelBufferPixelFormatTypeKey: PhoneCamConstants.pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            ]
            var pool: CVPixelBufferPool!
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
            var ph: CVPixelBuffer!
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &ph)
            PlaceholderRenderer.draw(placeholder, into: ph)
            formats.append((desc, pool, ph))
        }
        sinkFormat = formats[0].desc

        let frameDuration = CMTime(value: 1, timescale: PhoneCamConstants.frameRate)
        let streamFormats = formats.map {
            CMIOExtensionStreamFormat(formatDescription: $0.desc, maxFrameDuration: frameDuration, minFrameDuration: frameDuration, validFrameDurations: nil)
        }
        sourceStream = PhoneCamStreamSource(localizedName: "Phone Camera.Video", streamID: PhoneCamConstants.sourceStreamID,
                                            formats: streamFormats, device: device)
        sinkStream = PhoneCamSinkSource(localizedName: "Phone Camera.Sink", streamID: PhoneCamConstants.sinkStreamID,
                                        format: streamFormats[0], device: device)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, consumerCount] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = PhoneCamConstants.model }
        if properties.contains(consumerCount) {
            countLock.lock(); let n = publishedCount; countLock.unlock()
            p.setPropertyState(CMIOExtensionPropertyState(value: String(n) as NSString as AnyObject), forProperty: consumerCount)
        }
        return p
    }

    /// Tells the PhoneCam app (which polls the property) how many apps are reading the camera.
    private func publishConsumerCount() {
        countLock.lock(); publishedCount = streamingCounter; countLock.unlock()
        device.notifyPropertiesChanged([consumerCount: CMIOExtensionPropertyState(value: String(streamingCounter) as NSString as AnyObject)])
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source (what meeting apps read)

    func setActiveFormat(_ index: Int) { queue.async { self.activeFormat = min(max(index, 0), self.formats.count - 1) } }

    func startStreaming() {
        queue.async {
            self.streamingCounter += 1
            self.publishConsumerCount()
            guard self.sourceTimer == nil else { return }
            // Frames from the app are forwarded as they arrive (see consume). This timer is only a watchdog: it repeats
            // the last frame when the app is late, and switches to the placeholder when it has stopped sending.
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(PhoneCamConstants.frameRate), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.watchdog() }
            t.resume()
            self.sourceTimer = t
            log.info("source streaming started (\(self.streamingCounter) client(s))")
        }
    }

    func stopStreaming() {
        queue.async {
            self.streamingCounter = max(0, self.streamingCounter - 1)
            self.publishConsumerCount()
            if self.streamingCounter == 0 {
                self.sourceTimer?.cancel()
                self.sourceTimer = nil
                self.lastSent = nil
                log.info("source streaming stopped")
            }
        }
    }

    private var hostNow: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func watchdog() {
        let now = hostNow
        // Never show a stale image: without a fresh frame from the app, fall back to the placeholder.
        if latestFrame == nil || now - latestFrameHostTime >= PhoneCamConstants.staleFrameTimeout {
            send(formats[activeFormat].placeholder)
        } else if now - lastSendTime > 1.5 / Double(PhoneCamConstants.frameRate), let last = lastSent, last.format == activeFormat {
            send(last.frame)   // app is late: repeat rather than leave a gap
        }
    }

    /// Forwards a frame from the app to the meeting apps immediately, scaled to their chosen format.
    private func forward(_ frame: CVPixelBuffer) {
        guard sourceTimer != nil else { return }
        let fmt = formats[activeFormat]
        let out = scaled(frame, to: fmt) ?? fmt.placeholder
        lastSent = (out, activeFormat)
        send(out)
    }

    private func send(_ pixelBuffer: CVPixelBuffer) {
        let fmt = formats[activeFormat]
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lastSendTime = now.seconds
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: PhoneCamConstants.frameRate),
                                        presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
                                                     makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt.desc,
                                                     sampleTiming: &timing, sampleBufferOut: &sbuf)
        if err == noErr, let sbuf {
            sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
        }
    }

    private func scaled(_ frame: CVPixelBuffer, to fmt: (desc: CMFormatDescription, pool: CVPixelBufferPool, placeholder: CVPixelBuffer)) -> CVPixelBuffer? {
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.desc)
        if CVPixelBufferGetWidth(frame) == Int(dims.width), CVPixelBufferGetHeight(frame) == Int(dims.height) { return frame }
        guard let transfer else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, fmt.pool, &out)
        guard let out, VTPixelTransferSessionTransferImage(transfer, from: frame, to: out) == noErr else { return nil }
        return out
    }

    // MARK: Sink (what the PhoneCam app writes)

    func startSink(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.sinkTimer?.cancel()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(PhoneCamConstants.frameRate * 2), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.consume() }
            t.resume()
            self.sinkTimer = t
            log.info("sink started for client pid \(client.pid)")
        }
    }

    func stopSink() {
        queue.async {
            self.sinkTimer?.cancel()
            self.sinkTimer = nil
            self.sinkClient = nil
            self.latestFrame = nil
            log.info("sink stopped")
        }
    }

    private func consume() {
        guard let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, hasMore, _ in
            guard let self, let sbuf else { return }
            self.queue.async {
                if let image = CMSampleBufferGetImageBuffer(sbuf) {
                    self.latestFrame = image
                    self.latestFrameHostTime = self.hostNow
                    self.forward(image)
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: seq,
                                                          hostTimeInNanoseconds: UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC)))
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
                if hasMore { self.consume() }
            }
        }
    }
}

// MARK: - Streams

final class PhoneCamStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    let formats: [CMIOExtensionStreamFormat]
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, formats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self.formats = formats
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: PhoneCamConstants.frameRate) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index >= 0, index < formats.count {
            activeFormatIndex = index
            (device.source as? PhoneCamDeviceSource)?.setActiveFormat(index)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { (device.source as? PhoneCamDeviceSource)?.startStreaming() }

    func stopStream() throws { (device.source as? PhoneCamDeviceSource)?.stopStreaming() }
}

final class PhoneCamSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    let format: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.format = format
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: PhoneCamConstants.frameRate) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// One feeder at a time: while a client is feeding, a different process is refused, so nothing can take over the
    /// feed of a running PhoneCam app. Verifying *which* app connects isn't possible from here: CMIO reports
    /// signingID "unknown" for the (unsandboxed) app, and the extension's sandbox blocks reading another process's
    /// code signature (SecCodeCopyGuestWithAttributes → 100001).
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if let current = self.client, current.pid != client.pid, Self.isAlive(current.pid) {
            log.error("refused second sink client pid \(client.pid) while pid \(current.pid) is feeding")
            return false
        }
        self.client = client
        log.info("sink client pid \(client.pid) signingID \(client.signingID ?? "none", privacy: .public)")
        return true
    }

    func startStream() throws {
        guard let client else { return }
        (device.source as? PhoneCamDeviceSource)?.startSink(client: client)
    }

    /// kill(pid, 0) reports EPERM (not ESRCH) for a live process owned by another user, which the app is.
    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    func stopStream() throws {
        client = nil
        (device.source as? PhoneCamDeviceSource)?.stopSink()
    }
}

// MARK: - Provider

final class PhoneCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: PhoneCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = PhoneCamDeviceSource(localizedName: PhoneCamConstants.cameraName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = PhoneCamConstants.manufacturer }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
