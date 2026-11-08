import Foundation
import SystemExtensions
import AppKit
import os

/// Activates the bundled camera extension through OSSystemExtensionManager and reports its state in plain language.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject {
    enum State: Equatable {
        case unknown
        case notInstalled
        case activating
        case needsApproval
        case active
        case needsReboot
        case failed(String)
    }

    static let identifier = "com.zanghi.phonecam.camera-extension"
    @Published private(set) var state: State = .unknown
    @Published private(set) var lastError: String?
    /// Set at launch: replace an outdated active extension automatically, unless an app is using the camera.
    var autoUpdateUnlessInUse: (() -> Bool)?
    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "extension")

    /// Ask the system for the extension's current state without changing anything.
    func refresh() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func activate() {
        if let problem = Self.preflight() {
            state = .failed(problem)
            return
        }
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func openSigningHelp() {
        let alert = NSAlert()
        alert.messageText = "Sign PhoneCam with your Apple Developer team"
        alert.informativeText = """
        macOS only loads camera extensions from apps signed by a paid Apple Developer team.

        1. Put your team ID in mac/Local.xcconfig as DEVELOPMENT_TEAM = XXXXXXXXXX.
        2. Run mac/scripts/install.sh.
        3. Click Install in this menu, then allow PhoneCam in System Settings › General › Login Items & Extensions › Camera Extensions.

        The README's Signing section has the details.
        """
        alert.runModal()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks the conditions macOS enforces before it will even consider the request.
    nonisolated static func preflight() -> String? {
        let path = Bundle.main.bundlePath
        if !path.hasPrefix("/Applications/") {
            return "Move PhoneCam to the Applications folder, then open it again. macOS only installs camera extensions from there."
        }
        if teamIdentifier() == nil {
            return "This build is not signed with an Apple Developer team, so macOS will not load the camera extension. See README › Signing."
        }
        return nil
    }

    nonisolated static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: ns.code) else {
            return ns.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return "Move PhoneCam to the Applications folder and open it again."
        case .codeSignatureInvalid:
            return "macOS rejected the extension's signature. Rebuild with your Apple Developer team (README › Signing)."
        case .validationFailed:
            // Not always signing: sysextd also fails validation for bundle problems (e.g. a missing version key).
            return "macOS couldn't validate the camera extension (error \(ns.code)). Details: log show --predicate 'process == \"sysextd\"' --last 5m"
        case .missingEntitlement:
            return "The build lacks the System Extension entitlement. Enable it for your team (README › Signing)."
        case .extensionNotFound:
            return "The camera extension is missing from the app bundle. Rebuild PhoneCam."
        case .requestCanceled:
            return "Activation was cancelled."
        case .requestSuperseded:
            return "A newer activation request replaced this one."
        case .authorizationRequired:
            return "Approve the extension in System Settings › General › Login Items & Extensions › Camera Extensions."
        default:
            return "Camera extension error \(ns.code): \(ns.localizedDescription)"
        }
    }
}

extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed: self.state = .active
            case .willCompleteAfterReboot: self.state = .needsReboot
            @unknown default: self.state = .active
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = Self.describe(error)
        Task { @MainActor in
            self.log.error("extension request failed: \(message)")
            // A failed status check means "not installed" for the UI, but keep the reason in the log and the row.
            if self.state == .unknown { self.state = .notInstalled; self.lastError = message } else { self.state = .failed(message) }
        }
    }

    /// CFBundleVersion of the extension inside this app bundle.
    nonisolated static var bundledVersion: String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension/Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String)
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let active = properties.first(where: { $0.isEnabled && !$0.isUninstalling })
        let activeVersion = active?.bundleVersion
        Task { @MainActor in
            if active != nil {
                self.state = .active
                // A newer app carries a newer extension; macOS keeps running the old one until it is activated again.
                if let bundled = Self.bundledVersion, let activeVersion, bundled != activeVersion, let check = self.autoUpdateUnlessInUse {
                    self.autoUpdateUnlessInUse = nil
                    if check() {
                        self.log.info("extension \(activeVersion) is outdated (bundled \(bundled)) but in use; not replacing now")
                    } else {
                        self.log.info("updating camera extension \(activeVersion) → \(bundled)")
                        self.activate()
                    }
                }
            } else if properties.contains(where: { $0.isAwaitingUserApproval }) {
                self.state = .needsApproval
            } else {
                self.state = .notInstalled
            }
        }
    }
}
