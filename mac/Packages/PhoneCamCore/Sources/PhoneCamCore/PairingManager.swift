import Foundation
import CryptoKit
import Security
import os

public struct PairedDevice: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var secret: Data
    public var pairedAt: Date
}

/// Persists trusted phones. Team-signed builds use the Keychain (`KeychainDeviceStore.preferred()`); ad hoc builds
/// fall back to a 0600 JSON file in Application Support.
public protocol DeviceStore: AnyObject {
    func load() -> [PairedDevice]
    /// Returns false if the devices could not be persisted.
    @discardableResult func save(_ devices: [PairedDevice]) -> Bool
}

public final class FileDeviceStore: DeviceStore {
    let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultStore() -> FileDeviceStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return FileDeviceStore(url: dir.appendingPathComponent("paired-devices.json"))
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func load() -> [PairedDevice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    /// Nil if the file exists but can't be decoded (so a migration never deletes data it couldn't read).
    func loadStrict() -> [PairedDevice]? {
        guard let data = try? Data(contentsOf: url) else { return exists ? nil : [] }
        return try? JSONDecoder().decode([PairedDevice].self, from: data)
    }

    @discardableResult
    public func save(_ devices: [PairedDevice]) -> Bool {
        guard let data = try? JSONEncoder().encode(devices) else { return false }
        return FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Trusted phones as one item in the data-protection Keychain, readable only by this team-signed app on this Mac
/// (no ACL prompts). Ad hoc builds can't use that keychain, so `preferred()` falls back to the file store.
public final class KeychainDeviceStore: DeviceStore {
    public enum Availability: Equatable {
        case usable
        case missingEntitlement          // ad hoc / unsigned build: this keychain is off limits for good
        case error(OSStatus)             // e.g. errSecInteractionNotAllowed before the login keychain unlocks
    }

    let service: String
    let account = "paired-devices"
    private let log = Logger(subsystem: "com.zanghi.phonecam", category: "pairing")

    public init(service: String = "com.zanghi.phonecam") { self.service = service }

    /// Keychain if this build may use it, merging (then deleting) the legacy JSON file; otherwise the file store.
    /// Only a missing entitlement selects the file: a transient keychain error must not silently move secrets to disk.
    public static func preferred(file: FileDeviceStore = .defaultStore(), keychain: KeychainDeviceStore = KeychainDeviceStore(),
                                 retryFor seconds: TimeInterval = 10) -> DeviceStore {
        var availability = keychain.availability()
        let deadline = Date().addingTimeInterval(seconds)
        while case .error = availability, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            availability = keychain.availability()
        }
        switch availability {
        case .missingEntitlement:
            keychain.log.info("keychain not available to this build (ad hoc?); using file store")
            return file
        case .error(let status):
            keychain.log.error("keychain unavailable (\(status)); trusted phones unreadable until relaunch")
            return keychain
        case .usable:
            break
        }
        if file.exists {
            switch migrate(from: file, to: keychain) {
            case .migrated(let n):
                file.remove()
                keychain.log.info("merged \(n) trusted phone(s) from file into keychain")
            case .failed:
                keychain.log.error("keychain migration failed; keeping the file store")
                return file
            }
        }
        keychain.log.info("keychain store: \(keychain.load().count) trusted phone(s)")
        return keychain
    }

    public enum MigrationResult: Equatable { case migrated(Int), failed }

    /// Merges `legacy` into `target` by deviceId (newest pairing wins) and verifies the write by reading it back.
    /// The caller may delete the legacy store only on `.migrated`.
    public static func migrate(from legacy: FileDeviceStore, to target: DeviceStore) -> MigrationResult {
        guard let old = legacy.loadStrict() else { return .failed }
        return merge(old, into: target)
    }

    static func merge(_ old: [PairedDevice], into target: DeviceStore) -> MigrationResult {
        if old.isEmpty { return .migrated(0) }
        var merged = target.load()
        for d in old {
            if let i = merged.firstIndex(where: { $0.deviceId == d.deviceId }) {
                if d.pairedAt > merged[i].pairedAt { merged[i] = d }
            } else {
                merged.append(d)
            }
        }
        guard target.save(merged), Set(target.load().map(\.deviceId)) == Set(merged.map(\.deviceId)) else { return .failed }
        return .migrated(old.count)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func availability() -> Availability {
        var q = query
        q[kSecReturnData as String] = false
        switch SecItemCopyMatching(q as CFDictionary, nil) {
        case errSecSuccess, errSecItemNotFound: return .usable
        case errSecMissingEntitlement: return .missingEntitlement
        case let status: return .error(status)
        }
    }

    public func load() -> [PairedDevice] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    @discardableResult
    public func save(_ devices: [PairedDevice]) -> Bool {
        guard let data = try? JSONEncoder().encode(devices) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("keychain write failed: \(status)") }
        return status == errSecSuccess
    }
}

public final class MemoryDeviceStore: DeviceStore {
    public var devices: [PairedDevice] = []
    public var failWrites = false
    public init() {}
    public func load() -> [PairedDevice] { devices }
    @discardableResult
    public func save(_ devices: [PairedDevice]) -> Bool {
        if failWrites { return false }
        self.devices = devices
        return true
    }
}

/// Issues expiring single-use pairing tokens and holds the list of trusted phones.
/// Not thread-safe: call from one queue (the signaling server's).
public final class PairingManager {
    public struct Token: Equatable {
        public let value: Data
        public let issuedAt: Date
        public let expiresAt: Date
        public fileprivate(set) var state: State
        public fileprivate(set) var failedAttempts = 0
        public enum State: Equatable { case active, used, expired }
    }

    public enum PairResult: Equatable {
        case success(PairedDevice, nonce: Data, sealedSecret: Data)
        case failure(WireMessage.ErrorCode)
    }

    public let ttl: TimeInterval
    private let store: DeviceStore
    private let now: () -> Date
    public private(set) var current: Token?
    private var history: [Token] = []         // recent tokens, kept to give specific errors
    public private(set) var devices: [PairedDevice]

    public init(store: DeviceStore, ttl: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.ttl = ttl
        self.now = now
        self.devices = store.load()
    }

    /// Returns the active token, issuing a new one if none is live.
    @discardableResult
    public func activeToken() -> Token {
        expireIfNeeded()
        if let current, current.state == .active { return current }
        return issueToken()
    }

    @discardableResult
    public func issueToken() -> Token {
        if var old = current {
            if old.state == .active { old.state = .expired }
            archive(old)
        }
        let t = Token(value: PairingCrypto.randomBytes(16), issuedAt: now(), expiresAt: now().addingTimeInterval(ttl), state: .active)
        current = t
        return t
    }

    private func archive(_ token: Token) {
        history.append(token)
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    private func expireIfNeeded() {
        if var t = current, t.state == .active, now() >= t.expiresAt {
            t.state = .expired
            current = t
        }
    }

    /// Validates a pairing proof. On success the token is consumed and the phone becomes trusted.
    public func pair(deviceId: String, deviceName: String, nonce: Data, proof: Data) -> PairResult {
        expireIfNeeded()
        guard !deviceId.isEmpty, deviceId.count <= 128, nonce.count == 16 else { return .failure(.badRequest) }
        let message = PairingCrypto.pairProofMessage(deviceId: deviceId, nonce: nonce)

        if var t = current {
            if PairingCrypto.verify(PairingCrypto.pairingKey(token: t.value), message, mac: proof) {
                switch t.state {
                case .active:
                    t.state = .used
                    current = t
                    let secret = PairingCrypto.randomBytes(32)
                    let device = PairedDevice(deviceId: deviceId, name: String(deviceName.prefix(64)), secret: secret, pairedAt: now())
                    var updated = devices.filter { $0.deviceId != deviceId }
                    updated.append(device)
                    // Report a storage failure now rather than letting the phone believe it is paired until the next relaunch.
                    guard store.save(updated) else { return .failure(.storage) }
                    devices = updated
                    guard let (n, sealed) = try? PairingCrypto.seal(secret, key: PairingCrypto.pairingKey(token: t.value), aad: deviceId)
                    else { return .failure(.badRequest) }
                    return .success(device, nonce: n, sealedSecret: sealed)
                case .used: return .failure(.tokenUsed)
                case .expired: return .failure(.tokenExpired)
                }
            }
        }
        // Not the current token: identify old ones for a precise error, otherwise count a failed attempt.
        for old in history.reversed() where PairingCrypto.verify(PairingCrypto.pairingKey(token: old.value), message, mac: proof) {
            return .failure(old.state == .used ? .tokenUsed : .tokenExpired)
        }
        // No global burn counter: tokens are 128-bit random (unguessable), and burning on bad attempts would let anyone
        // on the LAN invalidate every code before the real phone scans it. The server closes the offending socket instead.
        if var t = current, t.state == .active {
            t.failedAttempts += 1
            current = t
        }
        return .failure(.tokenInvalid)
    }

    public func device(_ id: String) -> PairedDevice? { devices.first { $0.deviceId == id } }

    /// Returns false if the change could not be persisted (the phone is still dropped for this run).
    @discardableResult
    public func revoke(_ id: String) -> Bool {
        devices.removeAll { $0.deviceId == id }
        return store.save(devices)
    }
}
