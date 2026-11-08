import XCTest
@testable import PhoneCamCore

final class KeychainMigrationTests: XCTestCase {
    func device(_ id: String, _ secret: UInt8, at t: TimeInterval) -> PairedDevice {
        PairedDevice(deviceId: id, name: id, secret: Data(repeating: secret, count: 32), pairedAt: Date(timeIntervalSince1970: t))
    }

    func tempFile(_ devices: [PairedDevice]?) throws -> FileDeviceStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).json")
        let store = FileDeviceStore(url: url)
        if let devices { XCTAssertTrue(store.save(devices)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return store
    }

    func testMergeKeepsBothSidesAndNewestPairingWins() throws {
        let target = MemoryDeviceStore()
        target.devices = [device("a", 1, at: 100), device("b", 2, at: 100)]
        let file = try tempFile([device("a", 9, at: 200), device("c", 3, at: 50), device("b", 8, at: 10)])
        XCTAssertEqual(KeychainDeviceStore.migrate(from: file, to: target), .migrated(3))
        let byId = Dictionary(uniqueKeysWithValues: target.devices.map { ($0.deviceId, $0) })
        XCTAssertEqual(Set(byId.keys), ["a", "b", "c"])
        XCTAssertEqual(byId["a"]?.secret.first, 9, "newer file entry replaces the older keychain one")
        XCTAssertEqual(byId["b"]?.secret.first, 2, "older file entry doesn't overwrite a newer keychain one")
    }

    func testFailedWriteMeansKeepTheFile() throws {
        let target = MemoryDeviceStore()
        target.failWrites = true
        let file = try tempFile([device("a", 1, at: 1)])
        XCTAssertEqual(KeychainDeviceStore.migrate(from: file, to: target), .failed)
    }

    func testUnreadableFileIsNotTreatedAsEmpty() throws {
        let file = try tempFile(nil)
        try Data("not json".utf8).write(to: file.url)
        XCTAssertEqual(KeychainDeviceStore.migrate(from: file, to: MemoryDeviceStore()), .failed)
    }

    func testEmptyFileMigratesNothing() throws {
        let target = MemoryDeviceStore()
        target.devices = [device("a", 1, at: 1)]
        XCTAssertEqual(KeychainDeviceStore.migrate(from: try tempFile([]), to: target), .migrated(0))
        XCTAssertEqual(target.devices.count, 1)
    }
}

final class LanAddressTests: XCTestCase {
    func testAddresses() {
        for ip in ["192.168.1.20", "10.1.2.3", "172.16.0.1", "172.31.255.255", "169.254.1.1", "127.0.0.1",
                   "fe80::1%en0", "fd12:3456::1", "::1", "abcd-1234.local"] {
            XCTAssertTrue(LanAddress.isLAN(ip), ip)
        }
        for ip in ["8.8.8.8", "100.64.0.1", "172.32.0.1", "2001:4860::8888", "evil.example.com", ""] {
            XCTAssertFalse(LanAddress.isLAN(ip), ip)
        }
    }

    func testCandidatesAndSDP() {
        let lan = "candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host generation 0"
        let vpn = "candidate:2 1 udp 2122194687 100.96.1.2 50001 typ host generation 0"
        let v6 = "candidate:3 1 udp 2122129151 2600:1700::5 50002 typ host generation 0"
        XCTAssertTrue(LanAddress.isLANCandidate(lan))
        XCTAssertFalse(LanAddress.isLANCandidate(vpn))
        XCTAssertFalse(LanAddress.isLANCandidate(v6))
        let sdp = ["v=0", "a=" + lan, "a=" + vpn, "a=" + v6, "a=end-of-candidates"].joined(separator: "\r\n")
        XCTAssertEqual(LanAddress.filterSDP(sdp), ["v=0", "a=" + lan, "a=end-of-candidates"].joined(separator: "\r\n"))
    }
}

final class LatestFrameSlotTests: XCTestCase {
    func testSlowConsumerGetsOnlyTheNewestAndNoBacklog() {
        let slot = LatestFrameSlot<Int>()
        XCTAssertTrue(slot.put(1), "first put schedules a drain")
        XCTAssertFalse(slot.put(2), "drain already pending")
        XCTAssertFalse(slot.put(3))
        XCTAssertEqual(slot.take(), 3)
        XCTAssertNil(slot.take())
        XCTAssertEqual(slot.droppedCount, 2)
        XCTAssertTrue(slot.put(4), "after a take, the next put schedules again")
    }

    func testBacklogStaysBoundedUnderLoad() {
        // 30 fps producer, consumer takes 100 ms per frame: latency stays at most one frame + the work in progress.
        let slot = LatestFrameSlot<Int>()
        let q = DispatchQueue(label: "consumer")
        var processed: [Int] = []
        let done = expectation(description: "drained")
        let start = Date()
        for i in 0..<30 {
            if slot.put(i) { q.async { if let v = slot.take() { Thread.sleep(forTimeInterval: 0.1); processed.append(v) } } }
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        // Sleeps overshoot on loaded CI runners, so bound by the time the producer actually ran:
        // at 100 ms per frame the consumer can finish at most elapsed/0.1 frames, plus the one in progress
        // and the final drain. A queue (no dropping) would process all 30.
        let bound = min(29, Int(Date().timeIntervalSince(start) / 0.1) + 2)
        q.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertLessThanOrEqual(processed.count, bound, "frames were queued instead of dropped (30 produced)")
        XCTAssertEqual(processed.last, 29, "the newest frame is the one shown")
    }
}

final class CameraDemandTests: XCTestCase {
    func testOnImmediatelyOffAfterDelay() {
        var d = CameraDemand(offDelay: 10)
        XCTAssertFalse(d.update(consumers: 0, previewVisible: false, alwaysOn: false, now: 0))
        XCTAssertTrue(d.update(consumers: 1, previewVisible: false, alwaysOn: false, now: 1))
        XCTAssertTrue(d.update(consumers: 0, previewVisible: false, alwaysOn: false, now: 5), "brief stop doesn't turn the phone off")
        XCTAssertTrue(d.update(consumers: 1, previewVisible: false, alwaysOn: false, now: 6))
        XCTAssertTrue(d.update(consumers: 0, previewVisible: false, alwaysOn: false, now: 15.9))
        XCTAssertFalse(d.update(consumers: 0, previewVisible: false, alwaysOn: false, now: 16))
    }

    func testPreviewAndAlwaysOnCount() {
        var d = CameraDemand()
        XCTAssertTrue(d.update(consumers: 0, previewVisible: true, alwaysOn: false, now: 0))
        var a = CameraDemand()
        XCTAssertTrue(a.update(consumers: 0, previewVisible: false, alwaysOn: true, now: 0))
    }
}

/// The same vectors drive android/app/src/test/.../ProtocolVectorsTest.kt.
final class ProtocolVectorsTests: XCTestCase {
    struct Vectors: Decodable {
        struct Pairing: Decodable { let url, macId, macName: String; let hosts: [String]; let port: UInt16; let tokenHex: String }
        struct Sealed: Decodable { let keyHex, dir: String; let seq: Int; let body, macB64url: String }
        struct Auth: Decodable { let deviceId, phoneNonceHex, macNonceHex, phone, mac: String }
        struct Body: Decodable { let name, json: String }
        let protocolVersion: Int
        let pairing: Pairing
        let rejectedPairingUrls: [String]
        let sealed: [Sealed]
        let auth: Auth
        let bodies: [Body]
    }

    func load() throws -> Vectors {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/protocol-vectors.json").path) {
            dir.deleteLastPathComponent()
        }
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: dir.appendingPathComponent("docs/protocol-vectors.json")))
    }

    func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! })
    }

    func testVectors() throws {
        let v = try load()
        XCTAssertEqual(v.protocolVersion, phoneCamProtocolVersion)
        let p = try XCTUnwrap(PairingPayload(url: v.pairing.url))
        XCTAssertEqual(p.macId, v.pairing.macId)
        XCTAssertEqual(p.macName, v.pairing.macName)
        XCTAssertEqual(p.hosts, v.pairing.hosts)
        XCTAssertEqual(p.port, v.pairing.port)
        XCTAssertEqual(p.token, hex(v.pairing.tokenHex))
        for url in v.rejectedPairingUrls { XCTAssertNil(PairingPayload(url: url), url) }
        for s in v.sealed {
            let mac = PairingCrypto.hmac(.init(data: hex(s.keyHex)), "\(s.dir)|\(s.seq)|\(s.body)")
            XCTAssertEqual(mac.base64URL, s.macB64url, s.dir)
        }
        XCTAssertEqual(PairingCrypto.authMessage(role: "phone", deviceId: v.auth.deviceId, phoneNonce: hex(v.auth.phoneNonceHex),
                                                 macNonce: hex(v.auth.macNonceHex)), v.auth.phone)
        XCTAssertEqual(PairingCrypto.authMessage(role: "mac", deviceId: v.auth.deviceId, phoneNonce: hex(v.auth.phoneNonceHex),
                                                 macNonce: hex(v.auth.macNonceHex)), v.auth.mac)
        for b in v.bodies {
            let decoded = try XCTUnwrap(SignalBody.decode(b.json), b.name)
            XCTAssertEqual(decoded.encoded(), b.json, "Swift encodes \(b.name) exactly as the vector")
        }
    }
}
