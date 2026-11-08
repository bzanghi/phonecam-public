import SwiftUI

@main
struct PhoneCamApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Debug only: defaults write com.zanghi.phonecam PhoneCamDebugRenderMenu -bool YES renders the menu to
        // ~/Library/Logs/PhoneCam/menu.png every few seconds (no screen-recording permission needed).
        if UserDefaults.standard.bool(forKey: "PhoneCamDebugRenderMenu") {
            Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
                MainActor.assumeIsolated { AppModel.shared?.renderMenuSnapshot() }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, installer: model.installer)
        } label: {
            Image(systemName: model.menuSymbol)
                .accessibilityLabel("PhoneCam: \(model.menuStatus)")
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppModel {
    /// Something only the user can fix: extension not installed/approved, camera permission, sink error, no phone paired.
    var needsAction: Bool {
        if connection == .unpaired { return true }
        switch installer.state {
        case .active: return !pipeline.sinkConnected && pipeline.sinkError != nil
        case .unknown, .activating: return false
        default: return true
        }
    }

    var menuSymbol: String {
        if needsAction { return "exclamationmark.triangle" }
        switch connection {
        case .live: return (pipeline.consumers ?? 0) > 0 ? "video.fill" : "video"
        case .paused: return "video.slash"
        case .reconnecting, .connecting: return "video.badge.ellipsis"
        default: return "video"
        }
    }

    var menuStatus: String {
        if needsAction { return "needs attention" }
        switch connection {
        case .unpaired: return "not paired"
        case .waiting: return "waiting for phone"
        case .standby: return "ready"
        case .connecting: return "connecting"
        case .live: return (pipeline.consumers ?? 0) > 0 ? "live, in use" : "live"
        case .reconnecting: return "reconnecting"
        case .paused: return "paused"
        }
    }
}
