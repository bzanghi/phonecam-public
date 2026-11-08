import XCTest
import CryptoKit
@testable import PhoneCamCore

final class PairingTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    func makeManager(ttl: TimeInterval = 120) -> PairingManager {
        PairingManager(store: MemoryDeviceStore(), ttl: ttl, now: { [unowned self] in self.clock })
    }

    func proof(token: Data, deviceId: String, nonce: Data) -> Data {
        PairingCrypto.hmac(PairingCrypto.pairingKey(token: token), PairingCrypto.pairProofMessage(deviceId: deviceId, nonce: nonce))
    }

    func testValidTokenPairsOnceAndSecretOpens() throws {
        let m = makeManager()
        let token = m.activeToken().value
        let nonce = PairingCrypto.randomBytes(16)
        guard case .success(let device, let n, let sealed) = m.pair(deviceId: "phone-1", deviceName: "Pixel", nonce: nonce, proof: proof(token: token, deviceId: "phone-1", nonce: nonce))
        else { return XCTFail("expected success") }
        let secret = try PairingCrypto.open(nonce: n, sealed: sealed, key: PairingCrypto.pairingKey(token: token), aad: "phone-1")
        XCTAssertEqual(secret, device.secret)
        XCTAssertEqual(m.device("phone-1")?.name, "Pixel")

        // Reuse of the same token is rejected as used, even from another device id.
        let n2 = PairingCrypto.randomBytes(16)
        XCTAssertEqual(m.pair(deviceId: "phone-2", deviceName: "X", nonce: n2, proof: proof(token: token, deviceId: "phone-2", nonce: n2)), .failure(.tokenUsed))
    }

    func testExpiredTokenRejected() {
        let m = makeManager(ttl: 120)
        let token = m.activeToken().value
        clock += 121
        let nonce = PairingCrypto.randomBytes(16)
        XCTAssertEqual(m.pair(deviceId: "p", deviceName: "P", nonce: nonce, proof: proof(token: token, deviceId: "p", nonce: nonce)), .failure(.tokenExpired))
        // After a new token is issued, the old one is still reported as expired (not merely invalid).
        _ = m.activeToken()
        XCTAssertEqual(m.pair(deviceId: "p", deviceName: "P", nonce: nonce, proof: proof(token: token, deviceId: "p", nonce: nonce)), .failure(.tokenExpired))
    }

    func testInvalidTokensDoNotBurnTheRealOne() {
        // Burning on bad attempts would let anyone on the LAN block pairing; 128-bit tokens can't be guessed anyway.
        let m = makeManager()
        let real = m.activeToken().value
        for _ in 0..<10 {
            let nonce = PairingCrypto.randomBytes(16)
            XCTAssertEqual(m.pair(deviceId: "p", deviceName: "P", nonce: nonce, proof: proof(token: PairingCrypto.randomBytes(16), deviceId: "p", nonce: nonce)), .failure(.tokenInvalid))
        }
        let nonce = PairingCrypto.randomBytes(16)
        guard case .success = m.pair(deviceId: "p", deviceName: "P", nonce: nonce, proof: proof(token: real, deviceId: "p", nonce: nonce)) else {
            return XCTFail("real token must still pair")
        }
    }

    func testProofBoundToDeviceIdAndNonce() {
        let m = makeManager()
        let token = m.activeToken().value
        let nonce = PairingCrypto.randomBytes(16)
        let p = proof(token: token, deviceId: "a", nonce: nonce)
        XCTAssertEqual(m.pair(deviceId: "b", deviceName: "B", nonce: nonce, proof: p), .failure(.tokenInvalid))
        XCTAssertEqual(m.pair(deviceId: "a", deviceName: "B", nonce: PairingCrypto.randomBytes(16), proof: p), .failure(.tokenInvalid))
    }

    func testRevokeForgetsDevice() {
        let store = MemoryDeviceStore()
        let m = PairingManager(store: store)
        let token = m.activeToken().value
        let nonce = PairingCrypto.randomBytes(16)
        _ = m.pair(deviceId: "p", deviceName: "P", nonce: nonce, proof: proof(token: token, deviceId: "p", nonce: nonce))
        XCTAssertEqual(store.devices.count, 1)
        m.revoke("p")
        XCTAssertNil(m.device("p"))
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testQRPayloadRoundTrip() {
        let p = PairingPayload(macId: "mac-1", macName: "Office Mac Studio", hosts: ["192.168.1.20", "10.0.0.2"], port: 47800, token: Data(repeating: 7, count: 16))
        XCTAssertEqual(PairingPayload(url: p.url), p)
        XCTAssertNil(PairingPayload(url: "https://example.com/pair?k=abc"))
    }

    /// Fixed vectors; the Android unit test asserts the same hex values.
    func testCrossPlatformVectors() throws {
        let token = Data((0..<16).map { UInt8($0) })
        let kp = PairingCrypto.pairingKey(token: token)
        let kpHex = kp.withUnsafeBytes { Data($0) }.hex
        let nonce = Data(repeating: 0xAB, count: 16)
        let proofHex = PairingCrypto.hmac(kp, PairingCrypto.pairProofMessage(deviceId: "dev-1", nonce: nonce)).hex
        let ks = PairingCrypto.sessionKey(secret: Data(repeating: 0x11, count: 32), phoneNonce: Data(repeating: 1, count: 16), macNonce: Data(repeating: 2, count: 16))
        let ksHex = ks.withUnsafeBytes { Data($0) }.hex
        print("VECTOR kp=\(kpHex)\nVECTOR proof=\(proofHex)\nVECTOR ks=\(ksHex)")
        XCTAssertEqual(kpHex, CrossPlatformVectors.pairingKey)
        XCTAssertEqual(proofHex, CrossPlatformVectors.pairProof)
        XCTAssertEqual(ksHex, CrossPlatformVectors.sessionKey)
        // AES-GCM with a fixed nonce must also match (Android encrypts with javax.crypto).
        let box = try AES.GCM.seal(Data(repeating: 0x22, count: 32), using: kp, nonce: AES.GCM.Nonce(data: Data(repeating: 3, count: 12)), authenticating: Data("dev-1".utf8))
        let sealedHex = (box.ciphertext + box.tag).hex
        print("VECTOR sealed=\(sealedHex)")
        XCTAssertEqual(sealedHex, CrossPlatformVectors.sealed)
    }
}

// Fixed test vectors, not secrets: every input is a constant (token 00..0f, nonce 0xAB or 0x01..02, secret 0x11, AES nonce 0x03).
enum CrossPlatformVectors {
    static let pairingKey = "5ecefb528d85c078ec68c5b8d6c518d8953c72b9c82519020383677e45b666e4"
    static let pairProof = "ed13386e1d66c9d0e5f945074e52d6b06f60ea8a8c5ded0a2ae3e321fe4db9c4"
    static let sessionKey = "743cf5d52e379b3fcbc088bf91ffd5aa37f94b24225fe3ad1a53bac11b0cbf25"
    static let sealed = "c532d3465c7f3ae2c4730d4a20374ab7af0ee0b70fc872c713d6aadf379d5d3e01798e4f21fe28c1e9b23fe48f04450d"
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
