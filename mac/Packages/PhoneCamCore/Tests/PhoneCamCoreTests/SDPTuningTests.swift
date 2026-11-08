import XCTest
@testable import PhoneCamCore

final class SDPTuningTests: XCTestCase {
    func testAddsHintsToExistingAndMissingFmtp() {
        let sdp = ["v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98", "a=rtpmap:96 VP8/90000", "a=rtpmap:97 rtx/90000",
                   "a=fmtp:97 apt=96", "a=rtpmap:98 H264/90000", "a=fmtp:98 profile-level-id=42e01f;packetization-mode=1", ""].joined(separator: "\r\n")
        let out = SDPTuning.withBitrateHints(sdp)
        XCTAssertTrue(out.contains("a=rtpmap:96 VP8/90000\r\na=fmtp:96 x-google-start-bitrate=3000;x-google-min-bitrate=600"))
        XCTAssertTrue(out.contains("a=fmtp:98 profile-level-id=42e01f;packetization-mode=1;x-google-start-bitrate=3000"))
        XCTAssertTrue(out.contains("a=fmtp:97 apt=96\r\n"), "rtx untouched")
        XCTAssertEqual(SDPTuning.withBitrateHints(out), out, "idempotent")
    }
}
