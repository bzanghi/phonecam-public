import Foundation
import CryptoKit

/// Key derivation and proofs shared with the Android app (see android .../PairingCrypto.kt; test vectors must match).
///
/// - Pairing key   Kp = HKDF-SHA256(ikm: QR token, salt: "phonecam-v1", info: "pair")
/// - Pair proof       = HMAC(Kp, "phonecam-pair|<deviceId>|<nonce>")
/// - Device secret S  : 32 random bytes from the Mac, sent sealed with AES-GCM(Kp, aad: deviceId)
/// - Auth proofs      = HMAC(S, "phonecam-auth-phone|..." / "phonecam-auth-mac|...")
/// - Session key Ks   = HKDF-SHA256(ikm: S, salt: nonceP||nonceM, info: "session")
/// - Sealed messages  = HMAC(Ks, "<direction>|<seq>|<body>")
public enum PairingCrypto {
    public static let salt = Data("phonecam-v1".utf8)

    public static func pairingKey(token: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: token), salt: salt,
                               info: Data("pair".utf8), outputByteCount: 32)
    }

    public static func sessionKey(secret: Data, phoneNonce: Data, macNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: phoneNonce + macNonce,
                               info: Data("session".utf8), outputByteCount: 32)
    }

    public static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    public static func verify(_ key: SymmetricKey, _ message: String, mac: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(message.utf8), using: key)
    }

    public static func pairProofMessage(deviceId: String, nonce: Data) -> String {
        "phonecam-pair|\(deviceId)|\(nonce.base64URL)"
    }

    public static func authMessage(role: String, deviceId: String, phoneNonce: Data, macNonce: Data) -> String {
        "phonecam-auth-\(role)|\(deviceId)|\(phoneNonce.base64URL)|\(macNonce.base64URL)"
    }

    /// Returns (nonce, ciphertext||tag).
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: String) throws -> (Data, Data) {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8))
        return (Data(box.nonce), box.ciphertext + box.tag)
    }

    public static func open(nonce: Data, sealed: Data, key: SymmetricKey, aad: String) throws -> Data {
        guard sealed.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: sealed.prefix(sealed.count - 16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

public extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
