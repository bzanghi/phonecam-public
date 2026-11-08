import Foundation

/// Adds libwebrtc's x-google-start-bitrate / x-google-min-bitrate to every video codec in an SDP.
/// The Mac applies it to the answer it sends to the phone, whose sender reads codec parameters from the remote
/// description. Without it every new connection (including each reconnect) starts near 300 kbps at 320x180.
public enum SDPTuning {
    public static func withBitrateHints(_ sdp: String, startKbps: Int = 3000, minKbps: Int = 600) -> String {
        let hint = "x-google-start-bitrate=\(startKbps);x-google-min-bitrate=\(minKbps)"
        let lines = sdp.components(separatedBy: "\r\n")
        var videoPTs: [String] = []
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let parts = line.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let codec = parts[1].split(separator: "/").first.map { String($0).uppercased() } ?? ""
            if ["H264", "VP8", "VP9", "AV1", "H265"].contains(codec) { videoPTs.append(String(parts[0])) }
        }
        var out: [String] = []
        var hasFmtp = Set<String>()
        for line in lines where line.hasPrefix("a=fmtp:") {
            if let pt = line.dropFirst("a=fmtp:".count).split(separator: " ").first { hasFmtp.insert(String(pt)) }
        }
        for line in lines {
            if line.hasPrefix("a=fmtp:"), let pt = line.dropFirst("a=fmtp:".count).split(separator: " ").first,
               videoPTs.contains(String(pt)), !line.contains("x-google-start-bitrate") {
                out.append(line + ";" + hint)
                continue
            }
            out.append(line)
            if line.hasPrefix("a=rtpmap:"), let pt = line.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init),
               videoPTs.contains(pt), !hasFmtp.contains(pt) {
                out.append("a=fmtp:\(pt) \(hint)")
            }
        }
        return out.joined(separator: "\r\n")
    }
}
