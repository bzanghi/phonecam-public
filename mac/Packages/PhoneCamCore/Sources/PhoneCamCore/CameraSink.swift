import Foundation
import CoreMediaIO
import CoreMedia
import os
import PhoneCamShared

/// Feeds frames into the PhoneCam camera extension through its sink stream, the CoreMediaIO-supported
/// path from an app to a camera extension (CMIOStreamCopyBufferQueue + CMSimpleQueueEnqueue).
/// No App Groups, shared memory or custom XPC is involved.
public final class CameraSink {
    public enum State: Equatable {
        case deviceNotFound      // extension not installed/activated, or not yet published by the system
        case connected
        case failed(String)
    }

    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "sink")
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    public private(set) var state: State = .deviceNotFound
    public private(set) var enqueued = 0
    public private(set) var dropped = 0
    private var fullSince: TimeInterval?

    public init() {}

    /// Locate the extension's device and start its sink stream. Safe to call repeatedly.
    @discardableResult
    public func connect() -> State {
        if state == .connected { return state }
        guard let device = Self.findDevice(uid: PhoneCamConstants.deviceID.uuidString) else {
            state = .deviceNotFound
            return state
        }
        let streams = Self.streams(of: device)
        // The extension registers the source first and the sink second. A sink is an output stream (direction 0).
        guard let sink = streams.first(where: { Self.direction(of: $0) == 0 }) ?? (streams.count > 1 ? streams[1] : nil) else {
            state = .failed("Camera extension has no sink stream (\(streams.count) streams)")
            return state
        }
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let err = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
        guard err == noErr, let q = unmanagedQueue?.takeRetainedValue() else {
            state = .failed("CMIOStreamCopyBufferQueue failed (\(err))")
            return state
        }
        let startErr = CMIODeviceStartStream(device, sink)
        guard startErr == noErr else {
            state = .failed("CMIODeviceStartStream failed (\(startErr))")
            return state
        }
        deviceID = device
        streamID = sink
        queue = q
        state = .connected
        log.info("sink connected: device \(device) stream \(sink)")
        return state
    }

    public func disconnect() {
        if state == .connected { CMIODeviceStopStream(deviceID, streamID) }
        if let queue {
            // Release frames the extension never consumed.
            while let element = CMSimpleQueueDequeue(queue) { Unmanaged<CMSampleBuffer>.fromOpaque(element).release() }
        }
        queue = nil
        fullSince = nil
        state = .deviceNotFound
    }

    /// False when the extension went away (crash, upgrade, deactivation): its device vanished or got a new ID, or it
    /// stopped draining the queue. The caller should `disconnect()` and connect again.
    public func isHealthy(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard state == .connected else { return false }
        if let since = fullSince, now - since > 1 { return false }
        return Self.findDevice(uid: PhoneCamConstants.deviceID.uuidString) == deviceID
    }

    /// How many clients (meeting apps) are reading the extension's camera stream, published by the extension as a
    /// custom device property. Nil if unknown (extension too old or not found).
    public func consumerCount() -> Int? {
        let device = state == .connected ? deviceID : (Self.findDevice(uid: PhoneCamConstants.deviceID.uuidString) ?? 0)
        guard device != 0 else { return nil }
        var addr = CMIOObjectPropertyAddress(mSelector: PhoneCamConstants.consumerCountSelector,
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(device, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == noErr,
              let s = value?.takeRetainedValue() as String? else { return nil }
        return Int(s)
    }

    /// Enqueue a frame; drops it when the extension has not consumed the previous ones yet.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let queue else { return }
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) {
            dropped += 1
            if fullSince == nil { fullSince = ProcessInfo.processInfo.systemUptime }
            return
        }
        fullSince = nil
        let status = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        if status != noErr {
            Unmanaged.passUnretained(sampleBuffer).release()
            dropped += 1
        } else {
            enqueued += 1
        }
    }

    // MARK: CoreMediaIO helpers

    static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func objectIDs(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    /// Calls `onChange` on `queue` whenever CoreMediaIO's device list changes. Registering also keeps this process's
    /// device list current: without a listener, a device published after launch (a freshly started extension) stays
    /// invisible to the app until it relaunches.
    public static func watchDevices(queue: DispatchQueue, onChange: @escaping () -> Void) {
        var addr = address(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, queue) { _, _ in onChange() }
    }

    /// True if any client (a meeting app, or a PhoneCam sink) has a stream running on the Phone Camera device.
    public static func deviceIsRunningSomewhere() -> Bool {
        guard let device = findDevice(uid: PhoneCamConstants.deviceID.uuidString) else { return false }
        var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return false }
        return value != 0
    }

    public static func findDevice(uid: String) -> CMIOObjectID? {
        for device in objectIDs(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) {
            var addr = address(kCMIODevicePropertyDeviceUID)
            var value: Unmanaged<CFString>?
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == noErr,
               let s = value?.takeRetainedValue() as String?, s == uid {
                return device
            }
        }
        return nil
    }

    static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        objectIDs(device, kCMIODevicePropertyStreams)
    }

    static func direction(of stream: CMIOStreamID) -> UInt32? {
        var addr = address(kCMIOStreamPropertyDirection)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return nil }
        return value
    }
}
