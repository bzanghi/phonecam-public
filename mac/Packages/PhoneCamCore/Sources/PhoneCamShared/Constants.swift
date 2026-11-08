import Foundation
import CoreMedia

public enum PhoneCamConstants {
    /// Name meeting apps show in their camera menus.
    public static let cameraName = "Phone Camera"
    public static let manufacturer = "PhoneCam"
    public static let model = "PhoneCam Wireless"

    /// Fixed IDs so the app can find the extension's device and streams through CoreMediaIO.
    public static let deviceID = UUID(uuidString: "6B1E3C2A-4F5D-4E7B-9A0C-5D2F8E1B7A10")!
    public static let sourceStreamID = UUID(uuidString: "6B1E3C2A-4F5D-4E7B-9A0C-5D2F8E1B7A11")!
    public static let sinkStreamID = UUID(uuidString: "6B1E3C2A-4F5D-4E7B-9A0C-5D2F8E1B7A12")!

    /// The extension's sink accepts frames at this size; the app composites everything to it.
    public static let width: Int32 = 1920
    public static let height: Int32 = 1080
    public static let frameRate: Int32 = 30
    public static let pixelFormat: OSType = kCVPixelFormatType_32BGRA

    /// Source formats offered to meeting apps (first is the default).
    public static let sourceDimensions: [CMVideoDimensions] = [
        CMVideoDimensions(width: 1920, height: 1080),
        CMVideoDimensions(width: 1280, height: 720),
    ]

    /// Custom device property ("4cc_pcus_glob_0000") through which the extension publishes how many apps are reading
    /// the camera, as a decimal string. The app turns the phone's camera on only while this is above zero.
    public static let consumerCountProperty = "4cc_pcus_glob_0000"
    public static let consumerCountSelector: UInt32 = 0x70637573   // 'pcus'

    /// If the extension receives nothing newer than this, it shows its own placeholder instead of a stale frame.
    public static let staleFrameTimeout: TimeInterval = 1.0
}
