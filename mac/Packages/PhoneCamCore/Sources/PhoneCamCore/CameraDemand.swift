import Foundation

/// Decides whether the phone's camera should run: only while a Mac app reads "Phone Camera" or the menu preview is
/// open (unless "always on" is set). Turning on is immediate; turning off waits `offDelay` because apps briefly stop
/// and restart the camera when they switch formats or windows.
public struct CameraDemand: Equatable {
    public var offDelay: TimeInterval
    public private(set) var wanted = false
    private var lastDemand: TimeInterval?

    public init(offDelay: TimeInterval = 10) { self.offDelay = offDelay }

    /// Feed the current inputs; returns the new `wanted` value.
    @discardableResult
    public mutating func update(consumers: Int, previewVisible: Bool, alwaysOn: Bool, now: TimeInterval) -> Bool {
        let demand = alwaysOn || previewVisible || consumers > 0
        if demand {
            lastDemand = now
            wanted = true
        } else if wanted, let last = lastDemand, now - last >= offDelay {
            wanted = false
        } else if lastDemand == nil {
            wanted = false
        }
        return wanted
    }
}
