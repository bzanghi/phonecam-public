import Foundation

/// The "PhoneCam Mic" audio driver (mac/PhoneCamMic) and the app agree on these; keep them in step with PhoneCamMic.c.
/// Kept out of PhoneCamShared on purpose: that package is part of the camera extension's version hash.
public enum PhoneMicConstants {
    public static let deviceUID = "com.zanghi.phonecam.mic"
    public static let deviceName = "PhoneCam Mic"
    /// Loopback UDP port the driver listens on; packets are "PCM1", a sequence number, then 480 Float32 samples.
    public static let port: UInt16 = 47801
    public static let magic: UInt32 = 0x5043_4D31
    /// Frames the driver keeps buffered (20 ms at 48 kHz) to ride out timer jitter between the app and Core Audio.
    public static let targetFrames = 960
    public static let driverName = "PhoneCamMic.driver"
    public static let installDir = "/Library/Audio/Plug-Ins/HAL"
}
