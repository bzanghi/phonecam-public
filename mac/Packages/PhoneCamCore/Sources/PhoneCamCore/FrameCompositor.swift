import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import PhoneCamShared

/// Turns decoded phone frames (any size, with a rotation tag) into upright 1920x1080 BGRA frames for the
/// virtual camera: rotated, aspect-fit (pillarboxed when the phone is portrait), never stretched.
public final class FrameCompositor {
    public let width: Int
    public let height: Int
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(width: Int = Int(PhoneCamConstants.width), height: Int = Int(PhoneCamConstants.height)) {
        self.width = width
        self.height = height
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "PhoneCamCompositor"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: PhoneCamConstants.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
                                attrs as CFDictionary, &pool)
    }

    /// Geometry used for compositing; exposed for tests.
    /// Returns the size of the source after rotation and the rect it occupies in the output.
    public static func fitRect(sourceWidth: Int, sourceHeight: Int, rotation: Int, outWidth: Int, outHeight: Int) -> (rotated: CGSize, rect: CGRect) {
        let swap = rotation % 180 != 0
        let rw = CGFloat(swap ? sourceHeight : sourceWidth), rh = CGFloat(swap ? sourceWidth : sourceHeight)
        guard rw > 0, rh > 0 else { return (.zero, .zero) }
        let scale = min(CGFloat(outWidth) / rw, CGFloat(outHeight) / rh)
        let w = (rw * scale).rounded(), h = (rh * scale).rounded()
        return (CGSize(width: rw, height: rh),
                CGRect(x: ((CGFloat(outWidth) - w) / 2).rounded(), y: ((CGFloat(outHeight) - h) / 2).rounded(), width: w, height: h))
    }

    static func orientation(for rotation: Int) -> CGImagePropertyOrientation {
        // WebRTC rotation = clockwise degrees needed to display the frame upright.
        switch (rotation % 360 + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    public func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        return out
    }

    /// Composite a decoded frame. Returns nil if no output buffer is available (pool exhausted).
    public func composite(_ source: CVPixelBuffer, rotation: Int) -> CVPixelBuffer? {
        guard let out = makeBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: source).oriented(Self.orientation(for: rotation))
        let (_, rect) = Self.fitRect(sourceWidth: CVPixelBufferGetWidth(source), sourceHeight: CVPixelBufferGetHeight(source),
                                     rotation: rotation, outWidth: width, outHeight: height)
        let extent = image.extent
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(scaled.composited(over: background), to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        return out
    }

    public func placeholder(_ content: PlaceholderRenderer.Content) -> CVPixelBuffer? {
        guard let out = makeBuffer() else { return nil }
        PlaceholderRenderer.draw(content, into: out)
        return out
    }

    /// Wraps a composited buffer in a CMSampleBuffer stamped with the host clock.
    public func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: PhoneCamConstants.frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sbuf)
        return sbuf
    }
}
