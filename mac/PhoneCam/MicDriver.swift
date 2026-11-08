import Foundation
import AppKit
import CoreAudio
import PhoneCamCore

/// The "PhoneCam Mic" audio driver on this Mac. It lives in /Library/Audio/Plug-Ins/HAL, so installing or removing it
/// takes an administrator password (macOS asks) and restarts Core Audio, which interrupts sound for a second or two.
enum MicDriver {
    static var installedURL: URL {
        URL(fileURLWithPath: PhoneMicConstants.installDir).appendingPathComponent(PhoneMicConstants.driverName)
    }
    static var bundledURL: URL? { Bundle.main.url(forResource: "PhoneCamMic", withExtension: "driver") }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// The installed copy differs from the one in this app (an app update changed the driver).
    static var needsUpdate: Bool {
        guard isInstalled, let bundled = bundledURL else { return false }
        return version(at: installedURL) != version(at: bundled)
    }

    private static func version(at url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    enum Failure: Error, LocalizedError {
        case notBundled, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .notBundled: return "This build of PhoneCam has no microphone driver."
            case .cancelled: return "Cancelled."
            case .failed(let message): return message
            }
        }
    }

    /// Copies the driver into place and restarts Core Audio. Runs the macOS administrator prompt (blocks until answered).
    @MainActor
    static func install() throws {
        guard let src = bundledURL else { throw Failure.notBundled }
        let dst = installedURL.path
        try runAsAdmin("/bin/rm -rf \(quoted(dst)) && /bin/mkdir -p \(quoted(PhoneMicConstants.installDir)) && " +
                       "/bin/cp -R \(quoted(src.path)) \(quoted(dst)) && /usr/sbin/chown -R root:wheel \(quoted(dst)) && " +
                       "/usr/bin/killall coreaudiod")
    }

    @MainActor
    static func uninstall() throws {
        try runAsAdmin("/bin/rm -rf \(quoted(installedURL.path)) && /usr/bin/killall coreaudiod")
    }

    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @MainActor
    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
        throw Failure.failed(error[NSAppleScript.errorMessage] as? String ?? "Could not install the microphone driver.")
    }

    // MARK: Core Audio

    /// The driver's device, if Core Audio has loaded it.
    static func deviceID() -> AudioObjectID? {
        var uid = PhoneMicConstants.deviceUID as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// An app (meeting app, recorder) is reading "PhoneCam Mic" right now.
    static func isInUse() -> Bool {
        guard let id = deviceID() else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}
