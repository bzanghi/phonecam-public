import Foundation
import Network
import CryptoKit
import os

/// Local WebSocket signaling server (Network.framework) advertised over Bonjour as _phonecam._tcp.
/// Handles pairing and challenge-response auth, then relays HMAC-sealed signaling between the Mac app and one phone.
public final class SignalingServer: @unchecked Sendable {
    public static let serviceType = "_phonecam._tcp"
    public static let preferredPort: UInt16 = 47800

    public enum Event {
        case listening(port: UInt16)
        case listenerFailed(String)
        case paired(PairedDevice)
        case pairingRejected(WireMessage.ErrorCode, deviceName: String)
        case authenticated(PhoneSession)
        case authRejected(WireMessage.ErrorCode, deviceId: String)
        case received(PhoneSession, SignalBody)
        case closed(PhoneSession, reason: String)
    }

    public let macId: String
    public let macName: String
    public let pairing: PairingManager
    public var onEvent: ((Event) -> Void)?
    public var eventQueue: DispatchQueue = .main
    /// Seconds without any message (phone pings every 2 s) before a session is considered dead.
    public var idleTimeout: TimeInterval = 7
    public var preAuthTimeout: TimeInterval = 5

    let queue = DispatchQueue(label: "phonecam.signaling")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var activeSession: PhoneSession?
    private var watchdog: DispatchSourceTimer?
    private var advertise: Bool
    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "signaling")
    public private(set) var port: UInt16?

    /// Bonjour only helps trusted phones find the Mac after its IP changes, so it is off until one is paired.
    /// The service name is generic; phones match on the TXT id.
    public init(macId: String, macName: String, pairing: PairingManager, advertise: Bool = true) {
        self.macId = macId
        self.macName = macName
        self.pairing = pairing
        self.advertise = advertise
    }

    public static let serviceName = "PhoneCam"

    /// Turn Bonjour advertising on or off (e.g. when the first phone is paired or the last one forgotten).
    public func setAdvertising(_ on: Bool) {
        queue.async {
            self.advertise = on
            self.listener?.service = on ? self.service() : nil
        }
    }

    private func service() -> NWListener.Service {
        NWListener.Service(name: Self.serviceName, type: Self.serviceType, domain: nil,
                           txtRecord: NWTXTRecord(["id": macId, "v": String(phoneCamProtocolVersion)]))
    }

    // MARK: Lifecycle

    public func start(port requested: UInt16 = SignalingServer.preferredPort) {
        queue.async { self.startListener(port: requested, allowFallback: true) }
        queue.async { self.startWatchdog() }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for c in connections.values { c.connection.cancel() }
            connections.removeAll()
            activeSession = nil
            watchdog?.cancel()
            watchdog = nil
        }
    }

    private func startListener(port requested: UInt16, allowFallback: Bool) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        // LAN only: no cellular and no VPN tunnels (utun interfaces are type .other).
        params.prohibitedInterfaceTypes = [.cellular, .other]
        let l: NWListener
        do {
            l = try NWListener(using: params, on: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        } catch {
            if allowFallback { return startListener(port: 0, allowFallback: false) }
            return emit(.listenerFailed("Could not open a network port: \(error.localizedDescription)"))
        }
        if advertise { l.service = service() }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue
                self.log.info("listening on \(self.port ?? 0)")
                self.emit(.listening(port: self.port ?? 0))
            case .failed(let error):
                self.log.error("listener failed: \(error.localizedDescription)")
                l.cancel()
                if self.listener === l {
                    self.listener = nil
                    if allowFallback, case .posix(let code) = error, code == .EADDRINUSE {
                        self.startListener(port: 0, allowFallback: false)
                    } else {
                        self.emit(.listenerFailed(error.localizedDescription))
                        // Retry after a pause (e.g. network changed during sleep).
                        self.queue.asyncAfter(deadline: .now() + 3) { if self.listener == nil { self.startListener(port: requested, allowFallback: allowFallback) } }
                    }
                }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener = l
        l.start(queue: queue)
    }

    /// Recreate the listener (e.g. after wake from sleep when interfaces changed).
    public func restartListener() {
        queue.async {
            let p = self.port ?? Self.preferredPort
            self.listener?.cancel()
            self.listener = nil
            self.startListener(port: p, allowFallback: true)
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.checkTimeouts() }
        t.resume()
        watchdog = t
    }

    private func checkTimeouts() {
        let now = Date()
        for c in connections.values {
            let limit = c.state == .authenticated ? idleTimeout : preAuthTimeout
            let since = c.state == .authenticated ? c.lastReceived : c.openedAt
            if now.timeIntervalSince(since) > limit {
                close(c, reason: c.state == .authenticated ? "timeout" : "pre-auth timeout")
            }
        }
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        // LAN only, enforced: refuse peers outside private, link-local and unique-local ranges.
        guard LanAddress.isLAN(conn.endpoint) else {
            log.info("refused non-LAN peer \(Self.host(of: conn.endpoint), privacy: .public)")
            conn.cancel()
            return
        }
        let host = Self.host(of: conn.endpoint)
        let unauthenticated = connections.values.filter { $0.state != .authenticated }
        // Per-address cap on connections that haven't authenticated yet.
        if unauthenticated.filter({ $0.host == host }).count >= 3 {
            conn.cancel()
            return
        }
        // When full, evict the oldest unauthenticated connection rather than refusing a (possibly legitimate) new one.
        if connections.count >= 16, let oldest = unauthenticated.min(by: { $0.openedAt < $1.openedAt }) {
            close(oldest, reason: "evicted")
        }
        if connections.count >= 16 {
            conn.cancel()
            return
        }
        let c = Connection(connection: conn)
        c.host = host
        connections[ObjectIdentifier(c)] = c
        conn.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .failed, .cancelled: self.close(c, reason: "connection closed")
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: Connection) {
        c.connection.receiveMessage { [weak self, weak c] data, context, _, error in
            guard let self, let c else { return }
            if let error {
                self.close(c, reason: "receive error: \(error.localizedDescription)")
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                self.close(c, reason: "phone closed")
                return
            }
            if let data, !data.isEmpty {
                c.lastReceived = Date()
                self.handle(String(decoding: data, as: UTF8.self), from: c)
            }
            if self.connections[ObjectIdentifier(c)] != nil { self.receive(on: c) }
        }
    }

    private func handle(_ text: String, from c: Connection) {
        guard let msg = WireMessage.decode(text) else { return reject(c, .badRequest, "Malformed message") }
        if msg.t == "ping" {
            // After auth, answer with a sealed pong so an on-path attacker can't fake liveness for a dead Mac.
            if c.state == .authenticated { var b = SignalBody(t: "pong"); b.note = nil; return sendSealed(b, on: c) }
            return send(WireMessage(t: "pong"), to: c)
        }

        switch (c.state, msg.t) {
        case (.new, "pair"):
            guard msg.v == phoneCamProtocolVersion else { return reject(c, .version, "Update PhoneCam on your phone and Mac") }
            guard let deviceId = msg.deviceId, let nonce = msg.nonce.flatMap(Data.init(base64URL:)),
                  let proof = msg.proof.flatMap(Data.init(base64URL:)) else { return reject(c, .badRequest, "Missing fields") }
            let name = msg.deviceName ?? "Phone"
            switch pairing.pair(deviceId: deviceId, deviceName: name, nonce: nonce, proof: proof) {
            case .success(let device, let n, let sealed):
                var reply = WireMessage(t: "paired")
                reply.macId = macId
                reply.macName = macName
                reply.sealedNonce = n.base64URL
                reply.sealedSecret = sealed.base64URL
                send(reply, to: c)
                c.state = .new   // phone continues with hello on the same socket
                emit(.paired(device))
            case .failure(let code):
                emit(.pairingRejected(code, deviceName: name))
                reject(c, code, Self.describe(code))
            }

        case (.new, "hello"):
            guard msg.v == phoneCamProtocolVersion else { return reject(c, .version, "Update PhoneCam on your phone and Mac") }
            guard let deviceId = msg.deviceId, let nonce = msg.nonce.flatMap(Data.init(base64URL:)), nonce.count == 16
            else { return reject(c, .badRequest, "Missing fields") }
            guard let device = pairing.device(deviceId) else {
                emit(.authRejected(.unknownDevice, deviceId: deviceId))
                return reject(c, .unknownDevice, Self.describe(.unknownDevice))
            }
            c.device = device
            c.phoneNonce = nonce
            c.macNonce = PairingCrypto.randomBytes(16)
            c.state = .challenged
            var reply = WireMessage(t: "challenge")
            reply.nonce = c.macNonce!.base64URL
            send(reply, to: c)

        case (.challenged, "auth"):
            guard let device = c.device, let pn = c.phoneNonce, let mn = c.macNonce,
                  let proof = msg.proof.flatMap(Data.init(base64URL:)) else { return reject(c, .badRequest, "Missing fields") }
            let key = SymmetricKey(data: device.secret)
            guard PairingCrypto.verify(key, PairingCrypto.authMessage(role: "phone", deviceId: device.deviceId, phoneNonce: pn, macNonce: mn), mac: proof) else {
                emit(.authRejected(.badProof, deviceId: device.deviceId))
                return reject(c, .badProof, Self.describe(.badProof))
            }
            var reply = WireMessage(t: "authok")
            reply.proof = PairingCrypto.hmac(key, PairingCrypto.authMessage(role: "mac", deviceId: device.deviceId, phoneNonce: pn, macNonce: mn)).base64URL
            reply.macName = macName
            send(reply, to: c)
            c.sessionKey = PairingCrypto.sessionKey(secret: device.secret, phoneNonce: pn, macNonce: mn)
            c.state = .authenticated
            let session = PhoneSession(server: self, connection: c, deviceId: device.deviceId, deviceName: device.name)
            c.session = session
            // One phone at a time: a newer authenticated connection replaces the old (often half-dead) one. A different
            // phone is told so, so it stops auto-reconnecting instead of the two taking turns forever.
            if let old = activeSession, let oc = old.connection, oc !== c {
                if old.deviceId != device.deviceId {
                    var notice = SignalBody(t: "replaced")
                    notice.note = device.name
                    sendSealedNow(notice, on: oc) { [weak self] in self?.close(oc, reason: "replaced by \(device.name)") }
                    oc.state = .closed   // stop routing anything else to it while the notice flushes
                    if let s = oc.session { emit(.closed(s, reason: "replaced by \(device.name)")) }
                } else {
                    close(oc, reason: "replaced by new connection")
                }
            }
            activeSession = session
            emit(.authenticated(session))

        case (.authenticated, "sealed"):
            guard let key = c.sessionKey, let seq = msg.seq, let body = msg.body,
                  let mac = msg.mac.flatMap(Data.init(base64URL:)), seq > c.recvSeq,
                  PairingCrypto.verify(key, "p2m|\(seq)|\(body)", mac: mac),
                  let decoded = SignalBody.decode(body)
            else { return reject(c, .badProof, "Message failed authentication") }
            c.recvSeq = seq
            if let s = c.session { emit(.received(s, decoded)) }

        default:
            reject(c, .badRequest, "Unexpected \(msg.t)")
        }
    }

    static func describe(_ code: WireMessage.ErrorCode) -> String {
        switch code {
        case .tokenExpired: return "This pairing code expired. Show a new code on your Mac."
        case .tokenUsed: return "This pairing code was already used. Show a new code on your Mac."
        case .tokenInvalid: return "Pairing code not recognized. Scan the code currently shown on your Mac."
        case .unknownDevice, .revoked: return "This Mac no longer trusts this phone. Scan a new pairing code."
        case .badProof: return "Authentication failed. Pair again."
        case .version: return "PhoneCam versions differ. Update both apps."
        case .badRequest: return "Bad request."
        case .storage: return "The Mac couldn’t save this pairing. Try again."
        }
    }

    private func reject(_ c: Connection, _ code: WireMessage.ErrorCode, _ message: String) {
        log.info("reject \(code.rawValue): \(message)")
        send(WireMessage.error(code, message), to: c) { [weak self] in self?.close(c, reason: "rejected: \(code.rawValue)") }
    }

    fileprivate func send(_ msg: WireMessage, to c: Connection, then: (() -> Void)? = nil) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.connection.send(content: Data(msg.encoded().utf8), contentContext: ctx, isComplete: true,
                          completion: .contentProcessed { _ in then?() })
    }

    fileprivate func sendSealed(_ body: SignalBody, on c: Connection) {
        queue.async { self.sendSealedNow(body, on: c) }
    }

    /// Must run on `queue`.
    fileprivate func sendSealedNow(_ body: SignalBody, on c: Connection, then: (() -> Void)? = nil) {
        guard c.state == .authenticated, let key = c.sessionKey else { then?(); return }
        c.sendSeq += 1
        let text = body.encoded()
        var m = WireMessage(t: "sealed")
        m.seq = c.sendSeq
        m.body = text
        m.mac = PairingCrypto.hmac(key, "m2p|\(c.sendSeq)|\(text)").base64URL
        send(m, to: c, then: then)
    }

    static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    fileprivate func close(_ c: Connection, reason: String) {
        guard connections.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        let wasAuthenticated = c.state == .authenticated
        c.state = .closed
        c.connection.cancel()
        if let s = c.session {
            if activeSession === s { activeSession = nil }
            if wasAuthenticated { emit(.closed(s, reason: reason)) }
        }
    }

    /// Revokes trust: forget the phone and drop its live session with a "revoked" notice.
    public func revoke(deviceId: String) {
        queue.async {
            self.pairing.revoke(deviceId)
            for c in self.connections.values where c.device?.deviceId == deviceId {
                // Sealed notice first: the phone only drops its pairing on an authenticated revoke.
                if c.state == .authenticated { self.sendSealedNow(SignalBody(t: "revoked"), on: c) }
                self.reject(c, .revoked, Self.describe(.revoked))
            }
        }
    }

    /// Runs `body` on the signaling queue (PairingManager is confined to it).
    public func sync<T>(_ body: (PairingManager) -> T) -> T { queue.sync { body(pairing) } }

    private func emit(_ e: Event) {
        let handler = onEvent
        eventQueue.async { handler?(e) }
    }

    // MARK: Types

    final class Connection {
        enum State { case new, challenged, authenticated, closed }
        let connection: NWConnection
        var state: State = .new
        let openedAt = Date()
        var lastReceived = Date()
        var device: PairedDevice?
        var phoneNonce: Data?
        var macNonce: Data?
        var sessionKey: SymmetricKey?
        var sendSeq = 0
        var recvSeq = 0
        var host = ""
        weak var session: PhoneSession?
        init(connection: NWConnection) { self.connection = connection }
    }
}

/// An authenticated phone connection.
public final class PhoneSession: @unchecked Sendable {
    public let id = UUID()
    public let deviceId: String
    public let deviceName: String
    weak var server: SignalingServer?
    fileprivate weak var connection: SignalingServer.Connection?

    fileprivate init(server: SignalingServer, connection: SignalingServer.Connection, deviceId: String, deviceName: String) {
        self.server = server
        self.connection = connection
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    public func send(_ body: SignalBody) {
        guard let server, let c = connection else { return }
        server.sendSealed(body, on: c)
    }

    public func close() {
        guard let server else { return }
        server.queue.async { if let c = self.connection { server.close(c, reason: "closed by Mac") } }
    }
}

public enum LocalAddresses {
    /// Private IPv4 addresses of active interfaces, Wi-Fi/Ethernet first. Excludes loopback, link-local and CGNAT (VPN).
    public static func ipv4() -> [String] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            guard isPrivate(ip) else { continue }
            result.append((name, ip))
        }
        result.sort { rank($0.0) < rank($1.0) }
        var seen = Set<String>()
        return result.map(\.1).filter { seen.insert($0).inserted }
    }

    static func rank(_ ifname: String) -> Int { ifname.hasPrefix("en") ? 0 : 1 }

    public static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }
}
