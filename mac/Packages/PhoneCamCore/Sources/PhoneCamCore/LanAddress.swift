import Foundation
import Network

/// "LAN only" as code: which peer addresses and ICE candidates the Mac accepts or offers.
/// Private IPv4 (RFC 1918), IPv4/IPv6 link-local, IPv6 unique-local, loopback (tests), and mDNS `.local` names.
public enum LanAddress {
    public static func isLAN(_ ip: String) -> Bool {
        let host = ip.split(separator: "%").first.map(String.init) ?? ip   // drop an IPv6 zone ("fe80::1%en0")
        if host.lowercased().hasSuffix(".local") { return true }
        if let v4 = IPv4Address(host) { return isLAN(v4) }
        if let v6 = IPv6Address(host) { return isLAN(v6) }
        return false
    }

    public static func isLAN(_ a: IPv4Address) -> Bool {
        let b = [UInt8](a.rawValue)
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || b[0] == 127
    }

    public static func isLAN(_ a: IPv6Address) -> Bool {
        if a.isLoopback || a.isLinkLocal { return true }
        if let v4 = a.asIPv4 { return isLAN(v4) }
        return ([UInt8](a.rawValue)[0] & 0xFE) == 0xFC   // fc00::/7 unique-local
    }

    public static func isLAN(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return isLAN(a)
        case .ipv6(let a): return isLAN(a)
        case .name(let n, _): return isLAN(n)
        @unknown default: return false
        }
    }

    /// Address field of an ICE candidate line ("candidate:1 1 udp 2122260223 192.168.1.5 50000 typ host ...").
    public static func candidateAddress(_ candidate: String) -> String? {
        let line = candidate.hasPrefix("a=") ? String(candidate.dropFirst(2)) : candidate
        let f = line.split(separator: " ")
        return f.count > 4 ? String(f[4]) : nil
    }

    public static func isLANCandidate(_ candidate: String) -> Bool {
        candidateAddress(candidate).map(isLAN) ?? false
    }

    /// Removes `a=candidate` lines that point outside the LAN (VPN tunnels, global IPv6) from an SDP.
    public static func filterSDP(_ sdp: String) -> String {
        sdp.components(separatedBy: "\r\n")
            .filter { !$0.hasPrefix("a=candidate:") || isLANCandidate($0) }
            .joined(separator: "\r\n")
    }
}
