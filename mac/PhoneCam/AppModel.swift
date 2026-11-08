import Foundation
import AppKit
import Combine
import SwiftUI
import ServiceManagement
import AVFoundation
@preconcurrency import UserNotifications
@preconcurrency import WebRTC
import os
import PhoneCamCore
import PhoneCamShared

@MainActor
final class AppModel: ObservableObject {
    typealias Connection = LinkPhase

    @Published private(set) var connection: Connection = .unpaired
    @Published private(set) var phoneName: String?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var pairingURL: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var pairingMessage: String?
    @Published private(set) var listenerError: String?
    @Published private(set) var stats = WebRTCReceiver.Stats()
    @Published private(set) var pipeline = VideoPipeline.Snapshot()
    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var activeCamera: String?
    /// The phone's "Light while live" setting; nil when the phone has no flash (or predates the setting).
    @Published private(set) var phoneTorch: Bool?
    @Published private(set) var phoneNote: String?
    @Published private(set) var phoneStatus: String?   // battery / heat / 720p step-down, from the phone
    @Published var showPairing = false
    @Published private(set) var isRunning = true
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    /// This Mac's "Phone microphone" switch: the PhoneCam Mic driver is installed and the phone sends its mic here.
    @Published private(set) var micEnabled = UserDefaults.standard.bool(forKey: "PhoneMicEnabled")
    @Published private(set) var micInUse = false
    @Published private(set) var micMessage: String?
    /// The phone can send its microphone (permission granted); nil for phones from before the microphone.
    @Published private(set) var phoneHasMic: Bool?
    /// Re-activating and relaunching didn't bring the camera device back: macOS needs a restart to swap extensions.
    @Published private(set) var extensionNeedsRestart = false

    let installer = ExtensionInstaller()
    let video = VideoPipeline()
    private let server: SignalingServer
    private var receiver: WebRTCReceiver!
    private var session: PhoneSession?
    private var hadLiveVideo = false
    private var notLiveSince: Date?
    private var demand = CameraDemand()
    private var phoneSaidBye = false
    /// The phone streams to another Mac it is paired with; this Mac gets it when that one lets go.
    private var phoneBusyWith: String?
    /// Phones from before camera-on-demand ignore "idle" and keep streaming; closing their video would leave a meeting
    /// app without video until they renegotiate. Newer phones announce themselves by reporting `thermal` in `state`.
    private var phoneHandlesIdle = false
    private var notifiedForDemand = false
    private var installerWatch: Any?
    private var deviceMissingSince: Date?
    private var repairedExtension = false
    /// defaults write com.zanghi.phonecam PhoneCamAlwaysOn -bool YES keeps the phone camera running (soak tests).
    private var alwaysOn: Bool { UserDefaults.standard.bool(forKey: "PhoneCamAlwaysOn") }
    private var statsTimer: Timer?
    private var statsLog: FileHandle?
    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "app")
    private(set) var port: UInt16 = 0

    static weak var shared: AppModel?

    func renderMenuSnapshot() {
        let renderer = ImageRenderer(content: MenuView(model: self, installer: installer))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.debugDir.appendingPathComponent("menu.png"))
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let macId = defaults.string(forKey: "macId") ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: "macId")
            return id
        }()
        let name = Host.current().localizedName ?? "Mac"
        server = SignalingServer(macId: macId, macName: name, pairing: PairingManager(store: KeychainDeviceStore.preferred()))
        receiver = WebRTCReceiver(renderer: video)
        devices = server.sync { $0.devices }
        server.setAdvertising(!devices.isEmpty)
        connection = devices.isEmpty ? .unpaired : .waiting
        showPairing = devices.isEmpty
        wire()
        // Checked before our own sink starts (which also counts as "running"): never swap the extension under a call.
        let inUseAtLaunch = CameraSink.deviceIsRunningSomewhere()
        installer.autoUpdateUnlessInUse = { inUseAtLaunch }
        video.start()
        server.start()
        installer.refresh()
        updatePlaceholder()
        startStatsTimer()
        observeSleep()
        if micEnabled, !MicDriver.isInstalled { micEnabled = false; UserDefaults.standard.set(false, forKey: "PhoneMicEnabled") }
        WebRTCReceiver.micTap.forwarding = micEnabled
        WebRTCReceiver.micTap.setDelay(ms: UserDefaults.standard.integer(forKey: "PhoneCamMicDelayMs"))
        Self.shared = self
        // The extension may be replaced or (re)activated while we run: reconnect the sink to the new process.
        installerWatch = installer.$state.removeDuplicates().dropFirst().sink { [weak self] state in
            if state == .active { self?.video.reconnectSink() }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PhoneCamDebugPairingFile") {
            // Debug only: lets automated tests revoke trust without clicking Forget.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.zanghi.phonecam.debug.forget-all"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devices.forEach { self?.forget($0) } }
            }
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.zanghi.phonecam.debug.select-camera"), object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { if let id = note.object as? String { self?.selectCamera(id) } }
            }
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.zanghi.phonecam.debug.toggle-running"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.setRunning(!self.isRunning) } }
            }
        }
        #endif
    }

    // MARK: Wiring

    private func wire() {
        video.onSnapshot = { [weak self] s in
            guard let self else { return }
            if self.pipeline != s { self.pipeline = s }
            if s.live, self.connection == .connecting || self.connection == .reconnecting { self.setConnection(.live) }
            // Frames stopped (Wi-Fi drop, phone locked by another camera app): say so now rather than after the signaling timeout.
            if s.live { self.notLiveSince = nil } else if self.notLiveSince == nil { self.notLiveSince = Date() }
            if let since = self.notLiveSince, Date().timeIntervalSince(since) > 1, self.connection == .live { self.setConnection(.reconnecting) }
            self.updateDemand(consumers: s.consumers)
            self.repairExtensionIfMissing(s)
        }
        receiver.onCandidate = { [weak self] candidate in
            Task { @MainActor in
                var body = SignalBody(t: "candidate")
                body.candidate = candidate.sdp
                body.sdpMid = candidate.sdpMid
                body.sdpMLineIndex = Int(candidate.sdpMLineIndex)
                self?.session?.send(body)
            }
        }
        receiver.onState = { [weak self] state in
            Task { @MainActor in self?.handlePeerState(state) }
        }
        server.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: SignalingServer.Event) {
        switch event {
        case .listening(let port):
            self.port = port
            listenerError = nil
            refreshPairingCode()
        case .listenerFailed(let message):
            listenerError = "Can’t accept connections: \(message)"
        case .paired(let device):
            log.info("paired \(device.name)")
            let first = devices.isEmpty
            devices = server.sync { $0.devices }
            server.setAdvertising(true)
            pairingMessage = nil
            showPairing = false
            refreshPairingCode()
            if first { offerOpenAtLogin() }
        case .pairingRejected(let code, let name):
            pairingMessage = "\(name): \(Self.pairingError(code))"
            if code == .tokenUsed || code == .tokenExpired { refreshPairingCode() }
        case .authRejected(let code, _):
            if code == .unknownDevice { pairingMessage = "A phone that is no longer trusted tried to connect. Pair it again." }
        case .authenticated(let s):
            session = s
            phoneName = s.deviceName
            phoneNote = nil
            phoneSaidBye = false
            phoneBusyWith = nil
            phoneHandlesIdle = false
            notifiedForDemand = false
            // The phone waits for this before it opens its camera.
            applyRunState()
        case .received(let s, let body):
            guard s === session else { return }
            handle(body)
        case .closed(let s, let reason):
            guard s === session else { return }
            log.info("session closed: \(reason)")
            session = nil
            phoneBusyWith = nil
            receiver.close()
            phoneStatus = nil
            if phoneSaidBye {
                // Stopped on the phone on purpose: don't claim to be reconnecting.
                phoneNote = "Stopped on the phone"
                hadLiveVideo = false
                setConnection(.waiting)
            } else if connection != .paused {
                setConnection(hadLiveVideo ? .reconnecting : .waiting)
            }
        }
    }

    private func handle(_ body: SignalBody) {
        switch body.t {
        case "offer":
            guard let sdp = body.sdp else { return }
            receiver.handleOffer(sdp) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let answer):
                        var reply = SignalBody(t: "answer")
                        reply.sdp = SDPTuning.withBitrateHints(LanAddress.filterSDP(answer))
                        self.session?.send(reply)
                    case .failure(let error):
                        self.log.error("offer failed: \(error.localizedDescription)")
                        self.phoneNote = "Video setup failed: \(error.localizedDescription)"
                    }
                }
            }
        case "candidate":
            if let c = body.candidate { receiver.addCandidate(sdp: c, sdpMid: body.sdpMid, sdpMLineIndex: Int32(body.sdpMLineIndex ?? 0)) }
        case "state":
            if let cams = body.cameras { cameras = cams }
            activeCamera = body.camera ?? activeCamera
            phoneTorch = body.torch
            phoneHasMic = body.mic
            phoneBusyWith = CameraHandover.busyName(body.busy)
            phoneNote = CameraHandover.note(busy: phoneBusyWith, phoneNote: body.note)
            phoneStatus = Self.describePhone(body)
            if body.thermal != nil, !phoneHandlesIdle {
                phoneHandlesIdle = true
                if isRunning, !demand.wanted { applyRunState() }
            }
            if body.streaming == false,
               let next = CameraHandover.phaseWhenNotStreaming(connection, busy: phoneBusyWith, running: isRunning, wanted: demand.wanted) {
                setConnection(next)
            }
            updatePlaceholder()
        case "bye":
            phoneSaidBye = true
        default:
            break
        }
    }

    private func handlePeerState(_ state: WebRTCReceiver.State) {
        switch state {
        case .connected:
            break // .live is set when frames actually arrive
        case .disconnected, .failed:
            if connection == .live { setConnection(.reconnecting) }
        default:
            break
        }
    }

    private func setConnection(_ c: Connection) {
        guard connection != c else { return }
        if c == .live { hadLiveVideo = true }
        if c == .waiting || c == .unpaired { hadLiveVideo = false }
        connection = c
        updatePlaceholder()
    }

    /// Meeting apps mirror your self-view, so the placeholder carries a few words only; details live in the menu.
    private func updatePlaceholder() {
        let title = CameraHandover.placeholderTitle(connection, busy: phoneBusyWith, saidBye: phoneSaidBye)
        video.setPlaceholder(.init(title: title, subtitle: ""))
    }

    /// After an extension update macOS sometimes fails to start the new process ("Operation already in progress" while
    /// the old one exits), leaving no Phone Camera at all. Activating again registers it; done once per launch.
    private func repairExtensionIfMissing(_ s: VideoPipeline.Snapshot) {
        let missing = installer.state == .active && !s.sinkConnected && s.sinkError == nil
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard missing else { deviceMissingSince = nil; extensionNeedsRestart = false; return }
        if deviceMissingSince == nil { deviceMissingSince = Date() }
        guard let since = deviceMissingSince else { return }
        if !repairedExtension, Date().timeIntervalSince(since) > 10 {
            repairedExtension = true
            log.info("camera extension is active but its device is missing; activating it again")
            installer.activate()
        } else if repairedExtension, Date().timeIntervalSince(since) > 18 {
            // This process doesn't see a camera device published after it started; a fresh process does.
            // At most once per installed extension build, so a broken extension can't cause a relaunch loop.
            let build = ExtensionInstaller.bundledVersion ?? "?"
            guard UserDefaults.standard.string(forKey: "SelfRelaunchBuild") != build else {
                if !extensionNeedsRestart { log.info("camera device still missing after relaunch; asking for a restart") }
                extensionNeedsRestart = true
                return
            }
            UserDefaults.standard.set(build, forKey: "SelfRelaunchBuild")
            log.info("relaunching to pick up the restarted camera extension")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    // MARK: Camera demand

    /// Runs the phone's camera only while an app reads "Phone Camera" or the menu preview is open.
    private func updateDemand(consumers: Int?) {
        pollMic()
        // Unknown (older extension): keep the camera on, the pre-demand behaviour. An app recording from PhoneCam Mic
        // also needs the phone streaming (camera included, for now).
        let n = (consumers ?? 1) + (micEnabled && micInUse ? 1 : 0)
        let was = demand.wanted
        let wanted = demand.update(consumers: n, previewVisible: video.previewVisible, alwaysOn: alwaysOn,
                                   now: ProcessInfo.processInfo.systemUptime)
        if wanted != was {
            log.info("camera demand \(wanted ? "on" : "off") (consumers \(n), preview \(self.video.previewVisible))")
            if session != nil { applyRunState() }
        }
        if n > 0, session == nil, isRunning, !devices.isEmpty, !notifiedForDemand {
            notifiedForDemand = true
            notifyPhoneNeeded()
        }
        if n == 0 { notifiedForDemand = false }
    }

    /// Tells the phone what to do now: stream, stay connected with the camera off, or pause.
    private func applyRunState() {
        guard session != nil else { return }
        if !isRunning {
            sendControl("stop")
            setConnection(.paused)
        } else if demand.wanted {
            var body = SignalBody(t: "control")
            body.action = "start"
            body.mic = micEnabled
            session?.send(body)
            if connection != .live { setConnection(.connecting) }
        } else {
            sendControl("idle")
            if phoneHandlesIdle {
                receiver.close()
                setConnection(.standby)
            } else if connection != .live {
                setConnection(.connecting)   // an older phone streams regardless; .live follows its first frames
            }
        }
    }

    private func notifyPhoneNeeded() {
        let phone = devices.last?.name ?? "your phone"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "An app wants Phone Camera"
            content.body = "Open PhoneCam on \(phone) to start the camera."
            center.add(UNNotificationRequest(identifier: "phone-needed", content: content, trigger: nil))
        }
    }

    static func describePhone(_ body: SignalBody) -> String? {
        var parts: [String] = []
        if let b = body.battery { parts.append("Battery \(b)%") }
        switch body.thermal {
        case "moderate": parts.append("warm")
        case "severe", "critical", "emergency", "shutdown": parts.append("hot")
        default: break
        }
        switch body.limited {
        case "network": parts.append("720p (weak Wi-Fi)")
        case "thermal": parts.append("720p (cooling down)")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Phone microphone

    private var lastMicPoll: TimeInterval = 0

    private func pollMic() {
        let now = ProcessInfo.processInfo.systemUptime
        guard micEnabled, now - lastMicPoll >= 1 else { return }
        lastMicPoll = now
        let inUse = MicDriver.isInUse()
        if inUse != micInUse {
            micInUse = inUse
            log.info("PhoneCam Mic \(inUse ? "in use" : "idle")")
        }
    }

    /// Switches the phone microphone on or off for this Mac (installs or removes the driver; macOS asks for a password).
    func setMicEnabled(_ on: Bool) {
        guard on != micEnabled else { return }
        micMessage = nil
        do {
            if on {
                if !MicDriver.isInstalled || MicDriver.needsUpdate { try MicDriver.install() }
            } else if MicDriver.isInstalled {
                try MicDriver.uninstall()
            }
        } catch MicDriver.Failure.cancelled {
            return
        } catch {
            micMessage = error.localizedDescription
            return
        }
        micEnabled = on
        micInUse = false
        UserDefaults.standard.set(on, forKey: "PhoneMicEnabled")
        WebRTCReceiver.micTap.forwarding = on
        log.info("phone microphone \(on ? "on" : "off")")
        // Streaming now: renegotiate so the phone adds or drops its mic.
        if demand.wanted { applyRunState() }
    }

    func updateMicDriver() {
        do { try MicDriver.install(); micMessage = nil } catch MicDriver.Failure.cancelled {} catch { micMessage = error.localizedDescription }
    }

    // MARK: Login item

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// After the first pairing, open at login by default so meeting apps find the phone after a restart. Done once;
    /// the menu has the switch to turn it off.
    private func offerOpenAtLogin() {
        guard !UserDefaults.standard.bool(forKey: "OpenAtLoginOffered") else { return }
        UserDefaults.standard.set(true, forKey: "OpenAtLoginOffered")
        if SMAppService.mainApp.status == .notRegistered { setOpenAtLogin(true) }
    }

    // MARK: Actions

    func refreshPairingCode(forceNew: Bool = false) {
        guard port != 0 else { return }
        let token = server.sync { forceNew ? $0.issueToken() : $0.activeToken() }
        let hosts = LocalAddresses.ipv4()
        pairingURL = PairingPayload(macId: server.macId, macName: server.macName, hosts: hosts, port: port, token: token.value).url
        pairingExpiresAt = token.expiresAt
        if hosts.isEmpty { pairingMessage = "This Mac has no local network address. Connect it to Wi-Fi or Ethernet." }
        // Debug only (defaults write com.zanghi.phonecam PhoneCamDebugPairingFile -bool YES): lets automated tests
        // hand the code to a phone over adb instead of a camera. The token is single-use and expires in 2 minutes.
        if UserDefaults.standard.bool(forKey: "PhoneCamDebugPairingFile"), let url = pairingURL {
            FileManager.default.createFile(atPath: Self.debugDir.appendingPathComponent("pairing-url.txt").path,
                                           contents: Data(url.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    func forget(_ device: PairedDevice) {
        server.revoke(deviceId: device.deviceId)
        devices.removeAll { $0.deviceId == device.deviceId }
        if session?.deviceId == device.deviceId { session = nil; receiver.close(); phoneName = nil }
        if devices.isEmpty {
            server.setAdvertising(false)
            setConnection(.unpaired); showPairing = true; refreshPairingCode(forceNew: true)
        }
        else if session == nil { setConnection(.waiting) }
    }

    func setRunning(_ running: Bool) {
        isRunning = running
        if session != nil {
            if !running { receiver.close() }
            applyRunState()
        } else {
            setConnection(running ? (devices.isEmpty ? .unpaired : .waiting) : .paused)
        }
    }

    func selectCamera(_ id: String) {
        var body = SignalBody(t: "control")
        body.action = "camera"
        body.camera = id
        session?.send(body)
    }

    /// Turns the phone's live-indicator light on or off (saved on the phone, same as its own switch).
    func setTorch(_ on: Bool) {
        var body = SignalBody(t: "control")
        body.action = "torch"
        body.torch = on
        phoneTorch = on
        session?.send(body)
    }

    /// The phone's camera is in use on another Mac: move it here (that Mac waits until this one lets go).
    var canTakeOver: Bool { CameraHandover.canTakeOver(busy: phoneBusyWith, connected: session != nil) }

    func takeOver() {
        guard canTakeOver else { return }
        sendControl("takeover")
        phoneNote = "Switching the camera to this Mac…"
    }

    private func sendControl(_ action: String) {
        var body = SignalBody(t: "control")
        body.action = action
        session?.send(body)
    }

    // MARK: Stats

    private func startStatsTimer() {
        let dir = Self.debugDir
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)   // may hold camera frames
        let url = dir.appendingPathComponent("stats.csv")
        let header = "time,state,width,height,fps,codec,kbps,jitter_ms,decode_ms,rtt_ms,lost,dropped,out_fps,sink,cpu_pct,rss_mb,consumers,pipe_drop,freezes,pli,phone\n"
        // Start a new file when the columns changed or it passed 5 MB; keep one previous file.
        let existing = (try? FileHandle(forReadingFrom: url)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 512) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if let existing, !String(decoding: existing, as: UTF8.self).hasPrefix(header) || size > 5_000_000 {
            let prev = dir.appendingPathComponent("stats.prev.csv")
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: url, to: prev)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        }
        statsLog = try? FileHandle(forWritingTo: url)
        statsLog?.seekToEndOfFile()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStats() }
        }
    }

    private func pollStats() {
        receiver.stats { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                if let s { self.stats = s } else { self.stats = .init() }
                let usage = ProcessUsage.sample()
                let p = self.pipeline
                let line = String(format: "%@,%@,%d,%d,%.1f,%@,%d,%.1f,%.1f,%@,%d,%d,%.0f,%@,%.1f,%.0f,%@,%d,%d,%d,%@\n",
                                  ISO8601DateFormatter().string(from: Date()), "\(self.connection)", self.stats.width, self.stats.height,
                                  self.stats.fps, self.stats.codec, self.stats.bitrateKbps, self.stats.jitterBufferMs, self.stats.decodeMs,
                                  self.stats.roundTripMs.map { String(format: "%.1f", $0) } ?? "", self.stats.packetsLost,
                                  self.stats.framesDropped, p.outputFPS, p.sinkConnected ? "yes" : "no", usage.cpu, usage.rssMB,
                                  p.consumers.map(String.init) ?? "", p.droppedFrames, self.stats.freezes, self.stats.keyframeRequests,
                                  (self.phoneStatus ?? "").replacingOccurrences(of: ",", with: ";"))
                self.statsLog?.write(Data(line.utf8))
                if UserDefaults.standard.bool(forKey: "PhoneCamDebugSnapshots") {
                    self.video.writeSnapshot(to: Self.debugDir.appendingPathComponent("frame.png"))
                }
            }
        }
    }

    static var debugDir: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/PhoneCam")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    // MARK: Sleep

    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.info("Mac going to sleep; dropping session")
                self.session?.close()
                self.receiver.close()
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.server.restartListener()
                self?.video.reconnectSink()
            }
        }
    }

    static func pairingError(_ code: WireMessage.ErrorCode) -> String {
        switch code {
        case .tokenExpired: return "that code had expired. Scan the new one."
        case .tokenUsed: return "that code was already used. Scan the new one."
        case .tokenInvalid: return "that code isn’t valid. Scan the code shown here."
        case .version: return "app versions differ. Update both apps."
        case .storage: return "this Mac couldn’t save the pairing (Keychain error). Try again."
        default: return "pairing failed."
        }
    }
}

enum ProcessUsage {
    nonisolated(unsafe) private static var last: (cpu: Double, wall: TimeInterval)?   // main thread only

    /// CPU % of this process since the previous sample, and resident memory.
    static func sample() -> (cpu: Double, rssMB: Double) {
        var info = proc_taskinfo()
        let size = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        guard size == MemoryLayout<proc_taskinfo>.size else { return (0, 0) }
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let cpuSeconds = Double(info.pti_total_user + info.pti_total_system) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        let now = ProcessInfo.processInfo.systemUptime
        defer { last = (cpuSeconds, now) }
        let pct = last.map { (cpuSeconds - $0.cpu) / max(now - $0.wall, 0.001) * 100 } ?? 0
        return (pct, Double(info.pti_resident_size) / 1_048_576)
    }
}
