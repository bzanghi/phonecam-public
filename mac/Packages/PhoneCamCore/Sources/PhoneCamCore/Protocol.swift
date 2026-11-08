import Foundation

/// Signaling protocol version; both sides reject other versions with error code "version".
public let phoneCamProtocolVersion = 1

/// Outer WebSocket message (JSON text frame). Pre-auth messages use the plain fields; after authentication
/// everything except ping/pong travels as t="sealed" with an HMAC over direction, sequence and body.
public struct WireMessage: Codable, Equatable, Sendable {
    public var t: String
    public var v: Int?
    public var deviceId: String?
    public var deviceName: String?
    public var nonce: String?
    public var proof: String?
    public var macId: String?
    public var macName: String?
    public var sealedSecret: String?
    public var sealedNonce: String?
    public var code: String?
    public var message: String?
    public var seq: Int?
    public var body: String?
    public var mac: String?

    public init(t: String) { self.t = t }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ text: String) -> WireMessage? {
        try? JSONDecoder().decode(WireMessage.self, from: Data(text.utf8))
    }

    public static func error(_ code: ErrorCode, _ message: String) -> WireMessage {
        var m = WireMessage(t: "error")
        m.code = code.rawValue
        m.message = message
        return m
    }

    public enum ErrorCode: String, Sendable {
        case version, badRequest = "bad_request", tokenInvalid = "token_invalid", tokenExpired = "token_expired",
             tokenUsed = "token_used", unknownDevice = "unknown_device", badProof = "bad_proof", revoked,
             storage   // the Mac could not save the pairing
    }
}

/// Body of a sealed message.
public struct SignalBody: Codable, Equatable, Sendable {
    public var t: String                 // offer | answer | candidate | state | control | revoked | replaced | bye
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int?
    // state (phone -> mac)
    public var streaming: Bool?
    public var camera: String?           // id of the active camera/lens
    public var cameras: [CameraInfo]?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var battery: Int?             // percent
    public var thermal: String?          // none | light | moderate | severe | critical | emergency | shutdown
    public var limited: String?          // "network" | "thermal" when the phone stepped down to 720p
    public var note: String?             // e.g. "Camera in use by another app"; replaced: the other phone's name
    public var busy: String?             // another paired Mac has the phone's camera (its name); this Mac is queued
    public var torch: Bool?              // state: live-indicator light setting (nil = phone has no flash); control: set it
    public var mic: Bool?                // state: the phone can send its microphone (nil = older phone); control start: send audio too
    // control (mac -> phone)
    public var action: String?           // start | idle (no app is using Phone Camera) | stop (paused) | camera | torch

    public init(t: String) { self.t = t }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ text: String) -> SignalBody? {
        try? JSONDecoder().decode(SignalBody.self, from: Data(text.utf8))
    }
}

public struct CameraInfo: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var label: String             // "Back", "Back 0.5x", "Front"
    public var facing: String            // front | back
    public init(id: String, label: String, facing: String) {
        self.id = id
        self.label = label
        self.facing = facing
    }
}

/// What the QR code encodes: phonecam://pair?v=1&id=..&n=..&h=ip1,ip2&p=port&k=token
public struct PairingPayload: Equatable, Sendable {
    public var macId: String
    public var macName: String
    public var hosts: [String]
    public var port: UInt16
    public var token: Data

    public init(macId: String, macName: String, hosts: [String], port: UInt16, token: Data) {
        self.macId = macId
        self.macName = macName
        self.hosts = hosts
        self.port = port
        self.token = token
    }

    public var url: String {
        var c = URLComponents()
        c.scheme = "phonecam"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: String(phoneCamProtocolVersion)),
            URLQueryItem(name: "id", value: macId),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "k", value: token.base64URL),
        ]
        return c.string!
    }

    public init?(url: String) {
        guard let c = URLComponents(string: url), c.scheme == "phonecam", c.host == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        guard q["v"] == String(phoneCamProtocolVersion), let id = q["id"], !id.isEmpty, id.count <= 128, let hostList = q["h"],
              let port = q["p"].flatMap(UInt16.init), port > 0, let token = q["k"].flatMap(Data.init(base64URL:)), token.count == 16
        else { return nil }
        // Same rule as the phone: a pairing code may only point at private LAN addresses.
        let hosts = hostList.split(separator: ",").map(String.init)
        guard !hosts.isEmpty, hosts.allSatisfy(LocalAddresses.isPrivate) else { return nil }
        self.init(macId: id, macName: q["n"] ?? "Mac", hosts: hosts, port: port, token: token)
    }
}
