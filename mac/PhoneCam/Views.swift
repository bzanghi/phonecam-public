import SwiftUI
@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import PhoneCamCore

/// Flight Strip tokens, mapped to native SwiftUI.
enum Z {
    static let page = Color(hex: 0x13171B)
    static let well = Color(hex: 0x0D1013)
    static let holder = Color(hex: 0x1A1F24)
    static let ink1 = Color(hex: 0xEEEAE0)
    static let ink2 = Color(hex: 0xC4C0B4)
    static let ink3 = Color(hex: 0xA4A39B)
    static let pencil = Color(hex: 0xECDCB8)
    static let alert = Color(hex: 0xF0703F)
    static let alertText = Color(hex: 0xFF8F63)
    static let rule = Color(hex: 0xEEEAE0).opacity(0.15)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: ExtensionInstaller
    @State private var confirmForget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PreviewView(pipeline: model.video)
                .frame(width: 340, height: 191) // explicit size: an NSView has no intrinsic height and collapsed to 0
                .background(Z.well)
                .overlay(alignment: .bottomLeading) { if model.connection == .live { liveCaption } }
            extensionRow
            if model.showPairing || model.devices.isEmpty { pairingSection } else { phoneSection }
            if let error = model.listenerError { messageRow(error, needsUser: false) }
            footer
        }
        .frame(width: 340)
        .background(Z.page)
        .foregroundStyle(Z.ink1)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshPairingCode() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Phone Camera").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(statusText).font(.system(size: 12)).foregroundStyle(statusNeedsUser ? Z.alertText : Z.ink2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var statusText: String {
        switch model.connection {
        case .unpaired: return "Not paired"
        case .waiting: return "Waiting for phone"
        case .standby: return "Ready"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting…"
        case .paused: return "Paused"
        }
    }

    private var statusNeedsUser: Bool { model.needsAction }

    private var liveCaption: some View {
        let s = model.stats
        var parts: [String] = []
        if s.width > 0 { parts.append("\(s.width)×\(s.height)") }
        if s.fps > 0 { parts.append("\(Int(s.fps.rounded())) fps") }
        if !s.codec.isEmpty { parts.append(s.codec) }
        if let rtt = s.roundTripMs { parts.append("\(Int(rtt)) ms RTT") }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Z.page.opacity(0.8))
            .padding(6)
    }

    // MARK: Extension

    @ViewBuilder private var extensionRow: some View {
        switch installer.state {
        case .active:
            if !model.pipeline.sinkConnected, model.extensionNeedsRestart {
                messageRow("Restart this Mac to finish updating “Phone Camera”. Until then, apps can’t see it.", needsUser: true)
            } else if !model.pipeline.sinkConnected {
                messageRow(model.pipeline.sinkError ?? "Camera extension is active; connecting to it…", needsUser: false)
            } else {
                EmptyView()
            }
        case .unknown:
            EmptyView()
        case .notInstalled:
            actionRow(installer.lastError.map { "“Phone Camera” isn’t installed yet. (\($0))" } ?? "“Phone Camera” isn’t installed yet.",
                      button: "Install", needsUser: true) { installer.activate() }
        case .activating:
            messageRow("Installing camera extension…", needsUser: false)
        case .needsApproval:
            actionRow("Allow PhoneCam in System Settings › General › Login Items & Extensions › Camera Extensions.",
                      button: "Open Settings", needsUser: true) { installer.openSettings() }
        case .needsReboot:
            messageRow("Restart the Mac to finish installing the camera extension.", needsUser: true)
        case .failed(let message) where ExtensionInstaller.teamIdentifier() == nil:
            actionRow("“Phone Camera” needs a one-time developer signing step before meeting apps can see it. Your phone still streams to this preview.",
                      button: "How to fix", needsUser: true) { installer.openSigningHelp() }
            let _ = message
        case .failed(let message):
            actionRow(message, button: "Retry", needsUser: true) { installer.activate() }
        }
    }

    // MARK: Pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan with the PhoneCam app on your phone")
                .font(.system(size: 12)).foregroundStyle(Z.ink2)
            HStack(alignment: .top, spacing: 12) {
                if let url = model.pairingURL {
                    QRCodeView(text: url).frame(width: 150, height: 150)
                } else {
                    Rectangle().fill(Z.well).frame(width: 150, height: 150)
                        .overlay(Text("Starting…").font(.system(size: 11)).foregroundStyle(Z.ink3))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let expires = model.pairingExpiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = Int(expires.timeIntervalSince(ctx.date))
                            Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired")
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Z.ink3)
                                .onChange(of: left <= 0) { _, expired in if expired { model.refreshPairingCode() } }
                        }
                    }
                    Text("One use only. Same Wi-Fi as this Mac.")
                        .font(.system(size: 11)).foregroundStyle(Z.ink3).fixedSize(horizontal: false, vertical: true)
                    Button("New code") { model.refreshPairingCode(forceNew: true) }.controlSize(.small)
                    if !model.devices.isEmpty {
                        Button("Done") { model.showPairing = false }.controlSize(.small)
                    }
                }
            }
            if let msg = model.pairingMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(Z.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .overlay(alignment: .top) { Z.rule.frame(height: 1) }
    }

    // MARK: Phone

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.devices, id: \.deviceId) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.system(size: 12, weight: .medium))
                        if let note = model.phoneNote, model.phoneName == device.name {
                            Text(note).font(.system(size: 11)).foregroundStyle(Z.ink2)
                        }
                        if model.connection == .standby, model.phoneName == device.name {
                            Text("Camera off until an app uses Phone Camera").font(.system(size: 11)).foregroundStyle(Z.ink3)
                        }
                        if let status = model.phoneStatus, model.phoneName == device.name {
                            Text(status).font(.system(size: 11)).foregroundStyle(Z.ink3)
                        }
                    }
                    Spacer()
                    if model.canTakeOver, model.phoneName == device.name, confirmForget != device.deviceId {
                        Button("Use on this Mac") { model.takeOver() }.controlSize(.small)
                            .help("Move the phone's camera here. The other Mac gets it back when this one is done.")
                    }
                    if confirmForget == device.deviceId {
                        Button("Cancel") { confirmForget = nil }.controlSize(.small)
                        Button("Forget") { confirmForget = nil; model.forget(device) }.controlSize(.small)
                            .help("The phone must scan a new code to connect again.")
                    } else {
                        Button("Forget…") { confirmForget = device.deviceId }.controlSize(.small)
                            .help("Revoke trust. The phone must scan a new code to connect again.")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(alignment: .top) { Z.rule.frame(height: 1) }
            }
            if model.cameras.count > 1, model.phoneName != nil {
                HStack {
                    Text("Camera").font(.system(size: 12)).foregroundStyle(Z.ink2)
                    Spacer()
                    Picker("", selection: Binding(get: { model.activeCamera ?? "" }, set: { model.selectCamera($0) })) {
                        ForEach(model.cameras, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 150).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(alignment: .top) { Z.rule.frame(height: 1) }
            }
            if let torch = model.phoneTorch, model.phoneName != nil {
                HStack {
                    Text("Phone light while live").font(.system(size: 12)).foregroundStyle(Z.ink2)
                    Spacer()
                    Toggle("", isOn: Binding(get: { torch }, set: { model.setTorch($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Lights the phone's flash while it streams, so you can see the camera is on.")
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(alignment: .top) { Z.rule.frame(height: 1) }
            }
            // Per Mac: on adds a "PhoneCam Mic" input here; off keeps this Mac's own microphone (e.g. a USB mic).
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phone microphone").font(.system(size: 12)).foregroundStyle(Z.ink2)
                    Text(model.micEnabled ? (model.micInUse ? "“PhoneCam Mic” in use" : "Pick “PhoneCam Mic” in your meeting app")
                                          : "Off: this Mac uses its own microphone")
                        .font(.system(size: 11)).foregroundStyle(Z.ink3)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.micEnabled }, set: { model.setMicEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help("Adds a “PhoneCam Mic” input on this Mac, separate from Phone Camera. Switching it on or off asks for your password and restarts Mac audio for a moment.")
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(alignment: .top) { Z.rule.frame(height: 1) }
            if model.micEnabled, model.phoneHasMic == false, model.phoneName != nil {
                messageRow("Allow the microphone for PhoneCam on the phone (Settings › Apps › PhoneCam › Permissions).", needsUser: true)
            }
            if model.micEnabled, MicDriver.needsUpdate {
                actionRow("The PhoneCam Mic driver is out of date.", button: "Update…", needsUser: true) { model.updateMicDriver() }
            }
            if let message = model.micMessage { messageRow(message, needsUser: true) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.isRunning ? "Stop" : "Start") { model.setRunning(!model.isRunning) }
            if !model.devices.isEmpty && !model.showPairing {
                Button("Pair phone…") { model.showPairing = true; model.refreshPairingCode() }
            }
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                .toggleStyle(.checkbox).font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(12)
        .overlay(alignment: .top) { Z.rule.frame(height: 1) }
    }

    // MARK: Rows

    private func messageRow(_ text: String, needsUser: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if needsUser { Rectangle().fill(Z.alert).frame(width: 3) }
            Text(text).font(.system(size: 11)).foregroundStyle(needsUser ? Z.ink1 : Z.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { Z.rule.frame(height: 1) }
    }

    private func actionRow(_ text: String, button: String, needsUser: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if needsUser { Rectangle().fill(Z.alert).frame(width: 3) }
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { Z.rule.frame(height: 1) }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image).interpolation(.none).resizable()
        } else {
            Color.clear
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Shows exactly what the virtual camera receives. Frames flow to it only while the menu window is on screen.
struct PreviewView: NSViewRepresentable {
    let pipeline: VideoPipeline

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.wantsLayer = true
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        view.layer = layer
        pipeline.previewLayer = layer
        view.onVisible = { [weak pipeline] visible in pipeline?.previewVisible = visible }
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewHostView, coordinator: ()) {
        nsView.onVisible?(false)
        nsView.onVisible = nil
    }
}

/// Reports whether its window is actually visible (the menu bar window is hidden, not destroyed, when it closes).
final class PreviewHostView: NSView {
    var onVisible: ((Bool) -> Void)?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                              queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
        }
        report()
    }

    private func report() { onVisible?(window?.occlusionState.contains(.visible) == true) }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
