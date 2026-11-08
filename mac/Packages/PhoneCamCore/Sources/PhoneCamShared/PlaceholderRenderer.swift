import Foundation
import CoreGraphics
import CoreText
import CoreVideo

/// Draws the "no live video" frame. Used by the extension (app not running) and the app (waiting, reconnecting, paused).
public enum PlaceholderRenderer {
    public struct Content: Equatable, Sendable {
        public var title: String
        public var subtitle: String
        public init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// Fills a BGRA pixel buffer with the placeholder. Returns false if the buffer is not 32BGRA.
    @discardableResult
    public static func draw(_ content: Content, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        draw(content, in: ctx, width: CGFloat(width), height: CGFloat(height))
        return true
    }

    public static func draw(_ content: Content, in ctx: CGContext, width: CGFloat, height: CGFloat) {
        let scale = height / 1080
        // Flat rack-page background (Flight Strip tokens: rack.page #13171b).
        ctx.setFillColor(CGColor(srgbRed: 0x13 / 255, green: 0x17 / 255, blue: 0x1b / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Camera glyph: rounded body + lens ring, drawn with plain paths so no assets are needed.
        let cx = width / 2, cy = height / 2 + 90 * scale
        let body = CGRect(x: cx - 90 * scale, y: cy - 55 * scale, width: 180 * scale, height: 110 * scale)
        ctx.setStrokeColor(CGColor(srgbRed: 0xa4 / 255, green: 0xa3 / 255, blue: 0x9b / 255, alpha: 1))
        ctx.setLineWidth(8 * scale)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 22 * scale, cornerHeight: 22 * scale, transform: nil))
        ctx.strokePath()
        ctx.strokeEllipse(in: CGRect(x: cx - 32 * scale, y: cy - 32 * scale, width: 64 * scale, height: 64 * scale))
        ctx.setFillColor(CGColor(srgbRed: 0xec / 255, green: 0xdc / 255, blue: 0xb8 / 255, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: body.maxX - 34 * scale, y: body.maxY - 30 * scale, width: 14 * scale, height: 14 * scale))

        drawCentered(content.title, size: 54 * scale, weight: .semibold, y: cy - 150 * scale, width: width, ctx: ctx,
                     color: CGColor(srgbRed: 0xee / 255, green: 0xea / 255, blue: 0xe0 / 255, alpha: 1))
        drawCentered(content.subtitle, size: 32 * scale, weight: .regular, y: cy - 210 * scale, width: width, ctx: ctx,
                     color: CGColor(srgbRed: 0xc4 / 255, green: 0xc0 / 255, blue: 0xb4 / 255, alpha: 1))
    }

    private enum Weight { case regular, semibold }

    private static func drawCentered(_ text: String, size: CGFloat, weight: Weight, y: CGFloat, width: CGFloat,
                                     ctx: CGContext, color: CGColor) {
        let fontName = weight == .semibold ? "Helvetica Neue Medium" : "Helvetica Neue"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: y)
        CTLineDraw(line, ctx)
    }
}
