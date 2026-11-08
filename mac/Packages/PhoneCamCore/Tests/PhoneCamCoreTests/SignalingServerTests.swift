import XCTest
import CryptoKit
@testable import PhoneCamCore

/// Runs the real signaling server on loopback and talks to it the way the Android app does.
final class SignalingServerTests: XCTestCase {
    var server: SignalingServer!
    var port: UInt16 = 0
    var events: [SignalingServer.Event] = []
    let eventsLock = NSLock()

    override func setUp() async throws {
        let pairing = PairingManager(store: MemoryDeviceStore(), ttl: 2)
        server = SignalingServer(macId: "mac-test", macName: "Test Mac", pairing: pairing, advertise: false)
        server.eventQueue = DispatchQueue(label: "test-events")
        server.idleTimeout = 2
        let ready = expectation(description: "listening")
        server.onEvent = { [weak self] e in
            guard let self else { return }
            self.eventsLock.lock(); self.events.append(e); self.eventsLock.unlock()
            if case .listening(let p) = e { self.port = p; ready.fulfill() }
        }
        server.start(port: 0)
        await fulfillment(of: [ready], timeout: 5)
    }

    override func tearDown() { server.stop() }

    final class Client {
        let task: URLSessionWebSocketTask
        init(port: UInt16) {
            task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
            task.resume()
        }
        func send(_ m: WireMessage) async throws { try await task.send(.string(m.encoded())) }
        func receive() async throws -> WireMessage {
            guard case .string(let s) = try await task.receive(), let m = WireMessage.decode(s) else { throw URLError(.cannotParseResponse) }
            return m
        }
    }

    func pairMessage(token: Data, deviceId: String) -> WireMessage {
        let nonce = PairingCrypto.randomBytes(16)
        var m = WireMessage(t: "pair")
        m.v = 1
        m.deviceId = deviceId
        m.deviceName = "Pixel Test"
        m.nonce = nonce.base64URL
        m.proof = PairingCrypto.hmac(PairingCrypto.pairingKey(token: token), PairingCrypto.pairProofMessage(deviceId: deviceId, nonce: nonce)).base64URL
        return m
    }

    /// Pairs, authenticates and exchanges sealed messages; returns the secret.
    @discardableResult
    func pairAndAuth(deviceId: String = "phone-1", token: Data? = nil) async throws -> (Client, Data, SymmetricKey) {
        let token = token ?? server.sync { $0.activeToken().value }
        let c = Client(port: port)
        try await c.send(pairMessage(token: token, deviceId: deviceId))
        let paired = try await c.receive()
        XCTAssertEqual(paired.t, "paired", paired.message ?? "")
        let secret = try PairingCrypto.open(nonce: Data(base64URL: paired.sealedNonce!)!, sealed: Data(base64URL: paired.sealedSecret!)!,
                                            key: PairingCrypto.pairingKey(token: token), aad: deviceId)
        let ks = try await auth(c, deviceId: deviceId, secret: secret)
        return (c, secret, ks)
    }

    func auth(_ c: Client, deviceId: String, secret: Data) async throws -> SymmetricKey {
        let pn = PairingCrypto.randomBytes(16)
        var hello = WireMessage(t: "hello"); hello.v = 1; hello.deviceId = deviceId; hello.nonce = pn.base64URL
        try await c.send(hello)
        let challenge = try await c.receive()
        XCTAssertEqual(challenge.t, "challenge", challenge.message ?? "")
        let mn = Data(base64URL: challenge.nonce!)!
        let key = SymmetricKey(data: secret)
        var auth = WireMessage(t: "auth")
        auth.proof = PairingCrypto.hmac(key, PairingCrypto.authMessage(role: "phone", deviceId: deviceId, phoneNonce: pn, macNonce: mn)).base64URL
        try await c.send(auth)
        let ok = try await c.receive()
        XCTAssertEqual(ok.t, "authok")
        XCTAssertTrue(PairingCrypto.verify(key, PairingCrypto.authMessage(role: "mac", deviceId: deviceId, phoneNonce: pn, macNonce: mn),
                                           mac: Data(base64URL: ok.proof!)!), "Mac proves it holds the secret too")
        return PairingCrypto.sessionKey(secret: secret, phoneNonce: pn, macNonce: mn)
    }

    func testPairAuthAndSealedRoundTrip() async throws {
        let (c, _, ks) = try await pairAndAuth()
        var body = SignalBody(t: "state"); body.width = 1920; body.height = 1080; body.fps = 30
        let text = body.encoded()
        var m = WireMessage(t: "sealed"); m.seq = 1; m.body = text; m.mac = PairingCrypto.hmac(ks, "p2m|1|\(text)").base64URL
        try await c.send(m)
        try await Task.sleep(nanoseconds: 200_000_000)
        let got = snapshot().compactMap { e -> SignalBody? in if case .received(_, let b) = e { return b }; return nil }
        XCTAssertEqual(got.first?.width, 1920)
    }

    func testReusedTokenRejected() async throws {
        let token = server.sync { $0.activeToken().value }
        try await pairAndAuth(deviceId: "phone-1", token: token)
        let c2 = Client(port: port)
        try await c2.send(pairMessage(token: token, deviceId: "phone-2"))
        let r = try await c2.receive()
        XCTAssertEqual(r.t, "error"); XCTAssertEqual(r.code, "token_used")
    }

    func testExpiredTokenRejected() async throws {
        let token = server.sync { $0.activeToken().value }
        try await Task.sleep(nanoseconds: 2_200_000_000) // ttl is 2 s in this test
        let c = Client(port: port)
        try await c.send(pairMessage(token: token, deviceId: "phone-x"))
        let r = try await c.receive()
        XCTAssertEqual(r.code, "token_expired")
    }

    func testInvalidTokenRejected() async throws {
        _ = server.sync { $0.activeToken() }
        let c = Client(port: port)
        try await c.send(pairMessage(token: PairingCrypto.randomBytes(16), deviceId: "phone-x"))
        let r = try await c.receive()
        XCTAssertEqual(r.code, "token_invalid")
    }

    func testTamperedSealedMessageClosesSession() async throws {
        let (c, _, _) = try await pairAndAuth()
        var m = WireMessage(t: "sealed"); m.seq = 1; m.body = "{\"t\":\"state\"}"; m.mac = Data(repeating: 0, count: 32).base64URL
        try await c.send(m)
        let r = try await c.receive()
        XCTAssertEqual(r.code, "bad_proof")
    }

    func testRevokedDeviceMustRepair() async throws {
        let (c, secret, _) = try await pairAndAuth(deviceId: "phone-r")
        server.revoke(deviceId: "phone-r")
        _ = try await c.receive() // sealed revoke notice
        let r = try await c.receive()
        XCTAssertEqual(r.code, "revoked")
        // Reconnecting with the old secret now fails with unknown_device -> the phone shows "pair again".
        let c2 = Client(port: port)
        var hello = WireMessage(t: "hello"); hello.v = 1; hello.deviceId = "phone-r"; hello.nonce = PairingCrypto.randomBytes(16).base64URL
        try await c2.send(hello)
        let r2 = try await c2.receive()
        XCTAssertEqual(r2.code, "unknown_device")
        _ = secret
    }

    func testReconnectReplacesOldSessionAndIdleTimeoutCloses() async throws {
        let (c1, secret, _) = try await pairAndAuth(deviceId: "phone-1")
        _ = c1
        let c2 = Client(port: port)
        _ = try await auth(c2, deviceId: "phone-1", secret: secret)
        try await Task.sleep(nanoseconds: 300_000_000)
        let closes = snapshot().compactMap { e -> String? in if case .closed(_, let reason) = e { return reason }; return nil }
        XCTAssertTrue(closes.contains("replaced by new connection"), "\(closes)")
        // No pings for > idleTimeout (2 s) -> the server drops the session so the Mac shows the placeholder.
        try await Task.sleep(nanoseconds: 3_500_000_000)
        let closes2 = snapshot().compactMap { e -> String? in if case .closed(_, let reason) = e { return reason }; return nil }
        XCTAssertTrue(closes2.contains("timeout"), "\(closes2)")
    }

    func testIdleConnectionsFromOneAddressAreCapped() async throws {
        // Three silent sockets from one address are allowed; the fourth is dropped immediately.
        let idle = (0..<3).map { _ in Client(port: port) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let extra = Client(port: port)
        var hello = WireMessage(t: "hello"); hello.v = 1; hello.deviceId = "x"; hello.nonce = PairingCrypto.randomBytes(16).base64URL
        do {
            try await extra.send(hello)
            _ = try await extra.receive()
            XCTFail("fourth unauthenticated connection from the same address should be refused")
        } catch {}
        _ = idle
    }

    func testRevokeIsSentSealedBeforeTheError() async throws {
        let (c, _, ks) = try await pairAndAuth(deviceId: "phone-s")
        server.revoke(deviceId: "phone-s")
        let sealed = try await c.receive()
        XCTAssertEqual(sealed.t, "sealed")
        XCTAssertTrue(PairingCrypto.verify(ks, "m2p|\(sealed.seq!)|\(sealed.body!)", mac: Data(base64URL: sealed.mac!)!))
        XCTAssertEqual(SignalBody.decode(sealed.body!)?.t, "revoked")
        let err = try await c.receive()
        XCTAssertEqual(err.code, "revoked")
    }

    func testDifferentPhoneTakingOverIsToldSealed() async throws {
        let (c1, _, ks1) = try await pairAndAuth(deviceId: "phone-a")
        try await pairAndAuth(deviceId: "phone-b")
        let notice = try await c1.receive()
        XCTAssertEqual(notice.t, "sealed")
        XCTAssertTrue(PairingCrypto.verify(ks1, "m2p|\(notice.seq!)|\(notice.body!)", mac: Data(base64URL: notice.mac!)!))
        let body = SignalBody.decode(notice.body!)
        XCTAssertEqual(body?.t, "replaced")
        XCTAssertEqual(body?.note, "Pixel Test")
        try await Task.sleep(nanoseconds: 300_000_000)
        let closes = snapshot().compactMap { e -> String? in if case .closed(_, let reason) = e { return reason }; return nil }
        XCTAssertEqual(closes.filter { $0.hasPrefix("replaced by") }.count, 1, "\(closes)")
    }

    func testStorageFailureIsReportedNotPaired() async throws {
        let store = MemoryDeviceStore()
        store.failWrites = true
        let pairing = PairingManager(store: store, ttl: 60)
        let token = pairing.activeToken().value
        let nonce = PairingCrypto.randomBytes(16)
        let proof = PairingCrypto.hmac(PairingCrypto.pairingKey(token: token), PairingCrypto.pairProofMessage(deviceId: "p", nonce: nonce))
        XCTAssertEqual(pairing.pair(deviceId: "p", deviceName: "P", nonce: nonce, proof: proof), .failure(.storage))
        XCTAssertNil(pairing.device("p"), "a pairing that wasn't saved must not be trusted for this run either")
    }

    func snapshot() -> [SignalingServer.Event] {
        eventsLock.lock(); defer { eventsLock.unlock() }
        return events
    }
}
