import XCTest
import CoreVideo
@testable import PhoneCamCore
@testable import PhoneCamShared

final class CompositorTests: XCTestCase {
    func testLandscapeFillsFrame() {
        let r = FrameCompositor.fitRect(sourceWidth: 1920, sourceHeight: 1080, rotation: 0, outWidth: 1920, outHeight: 1080)
        XCTAssertEqual(r.rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testPortraitIsPillarboxedNotStretched() {
        // Sensor delivers 1920x1080 with a 90° tag when the phone is held upright.
        let r = FrameCompositor.fitRect(sourceWidth: 1920, sourceHeight: 1080, rotation: 90, outWidth: 1920, outHeight: 1080)
        XCTAssertEqual(r.rotated, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(r.rect.height, 1080)
        XCTAssertEqual(r.rect.width, 608) // 1080 * 1080/1920 = 607.5 -> 608
        XCTAssertEqual(r.rect.midX, 960, accuracy: 1)
    }

    func test720pScalesUp() {
        let r = FrameCompositor.fitRect(sourceWidth: 1280, sourceHeight: 720, rotation: 180, outWidth: 1920, outHeight: 1080)
        XCTAssertEqual(r.rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    /// A 200x100 source with a red left half, tagged 90° (clockwise). After compositing, red must be on top.
    func testRotationPutsContentUpright() throws {
        var src: CVPixelBuffer?
        CVPixelBufferCreate(nil, 200, 100, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &src)
        let s = try XCTUnwrap(src)
        CVPixelBufferLockBaseAddress(s, [])
        let base = CVPixelBufferGetBaseAddress(s)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(s)
        for y in 0..<100 { for x in 0..<200 {
            let p = base + y * bpr + x * 4
            let red = x < 100
            p[0] = red ? 0 : 255; p[1] = 0; p[2] = red ? 255 : 0; p[3] = 255 // BGRA: red or blue
        } }
        CVPixelBufferUnlockBaseAddress(s, [])

        let c = FrameCompositor(width: 320, height: 180)
        let out = try XCTUnwrap(c.composite(s, rotation: 90))
        let top = pixel(out, x: 160, y: 30), bottom = pixel(out, x: 160, y: 150), bar = pixel(out, x: 10, y: 90)
        XCTAssertGreaterThan(top.r, 200, "left of sensor image (red) rotates to the top")
        XCTAssertGreaterThan(bottom.b, 200)
        XCTAssertLessThan(bar.r + bar.g + bar.b, 30, "pillarbox bars are black")
    }

    func testPlaceholderDraws() throws {
        let c = FrameCompositor(width: 640, height: 360)
        let out = try XCTUnwrap(c.placeholder(.init(title: "Phone Camera", subtitle: "Waiting for your phone")))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 640)
        XCTAssertNotNil(c.sampleBuffer(for: out))
    }

    func pixel(_ buf: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }
}
