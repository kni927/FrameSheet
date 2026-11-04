import CoreGraphics
import Foundation
import Testing
@testable import FrameSheetCore

/// Rotation, crop and aspect ratio (§3, T08).
@Suite struct TransformTests {
    private func transform(rotation: Int = 0, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) -> MovieTransform {
        var t = MovieTransform()
        t.rotation = rotation
        t.cropTop = top
        t.cropBottom = bottom
        t.cropLeft = left
        t.cropRight = right
        return t
    }

    @Test func sizesAndClamping() {
        let t = transform(rotation: 90, top: 100, bottom: 20, left: 8)
        #expect(t.rotatedSize(width: 1920, height: 1080) == (1080, 1920))
        let rect = t.cropRect(width: 1920, height: 1080)
        #expect(rect == (8, 100, 1072, 1800))
        #expect(t.outputSize(width: 1920, height: 1080) == (1072, 1800))
        // Each edge leaves at least one pixel (MoviePrint's input check).
        let wide = transform(left: 5000, right: 5000).clamped(width: 1920, height: 1080)
        #expect(wide.cropLeft == 1919 && wide.cropRight == 0)
        #expect(wide.outputSize(width: 1920, height: 1080) == (1, 1080))
        #expect(transform(top: -4).cropRect(width: 10, height: 10) == (0, 0, 10, 10))
        #expect(MovieTransform().keepsImage)
        #expect(!transform(rotation: 180).keepsImage)
    }

    @Test func displayAspectRatio() {
        var t = transform(rotation: 270)
        #expect(t.displayAspectRatioInv(width: 1920, height: 1080) == 1920.0 / 1080.0)
        t.aspectRatioInv = 0.75
        #expect(t.displayAspectRatioInv(width: 1920, height: 1080) == 0.75)
        var file = MovieFile(
            url: URL(fileURLWithPath: "/m/a.mov"), duration: 1, frameCount: 25, fps: 25, width: 1920, height: 1080,
            size: 1, fourCC: "avc1")
        file.transform = transform(top: 140, bottom: 140)
        #expect(file.frameSize == (1920, 800))
        #expect(file.displayAspectRatioInv == 800.0 / 1920.0)
    }

    /// MoviePrint's crop presets: top and bottom for a wider ratio, left and
    /// right for a narrower one, in the rotated frame; truncated like
    /// `parseInt`.
    @Test func cropPresets() {
        let scope = transform().croppedTo(ratioInv: 0.4184, width: 1920, height: 1080)
        #expect(scope.cropTop == 138 && scope.cropBottom == 138 && scope.cropLeft == 0)
        let square = transform().croppedTo(ratioInv: 1, width: 1920, height: 1080)
        #expect(square.cropLeft == 420 && square.cropRight == 420 && square.cropTop == 0)
        let turned = transform(rotation: 90).croppedTo(ratioInv: 0.5625, width: 1920, height: 1080)
        #expect(turned.cropTop == 656 && turned.cropBottom == 656)
        #expect(transform(top: 5).croppedTo(ratioInv: nil, width: 1920, height: 1080).cropTop == 0)
        #expect(TransformOptions.cropPresets.count == 14 && TransformOptions.aspectRatios.count == 10)
    }

    @Test func decodeWidthForOutput() {
        // 1920×1080 turned: the output is 1080 wide, so 540 needs half size.
        #expect(transform(rotation: 90).sourceMaxWidth(forOutput: 540, width: 1920, height: 1080) == 960)
        // A 960 px crop of 1920: 480 output pixels need half size.
        #expect(transform(left: 480, right: 480).sourceMaxWidth(forOutput: 480, width: 1920, height: 1080) == 960)
        // Never enlarged.
        #expect(transform(rotation: 180).sourceMaxWidth(forOutput: 4000, width: 1920, height: 1080) == 1920)
        #expect(MovieTransform().sourceMaxWidth(forOutput: 300, width: 1920, height: 1080) == 300)
    }

    /// 4 × 2 quadrants: red, green (top), blue, white (bottom).
    private func quadrants() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Core Graphics has y up: the top row is y = 1.
        let fills: [(CGRect, (CGFloat, CGFloat, CGFloat))] = [
            (CGRect(x: 0, y: 1, width: 2, height: 1), (1, 0, 0)), (CGRect(x: 2, y: 1, width: 2, height: 1), (0, 1, 0)),
            (CGRect(x: 0, y: 0, width: 2, height: 1), (0, 0, 1)), (CGRect(x: 2, y: 0, width: 2, height: 1), (1, 1, 1)),
        ]
        for (rect, c) in fills {
            context.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    /// The image at twice its size.
    private func upscaled(_ image: CGImage) -> CGImage {
        let context = CGContext(
            data: nil, width: image.width * 2, height: image.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        return context.makeImage()!
    }

    /// R, G, B of each pixel, rows from the top.
    private func pixels(_ image: CGImage) -> [[String]] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.height).map { y in
            (0..<image.width).map { x in
                let i = (y * image.width + x) * 4
                switch (data[i] > 127, data[i + 1] > 127, data[i + 2] > 127) {
                case (true, false, false): return "R"
                case (false, true, false): return "G"
                case (false, false, true): return "B"
                case (true, true, true): return "W"
                default: return "?"
                }
            }
        }
    }

    @Test func rotatesClockwise() throws {
        let image = quadrants()
        #expect(pixels(image) == [["R", "R", "G", "G"], ["B", "B", "W", "W"]])
        let cw = try #require(transform(rotation: 90).apply(to: image, width: 4, height: 2))
        #expect(pixels(cw) == [["B", "R"], ["B", "R"], ["W", "G"], ["W", "G"]])
        let half = try #require(transform(rotation: 180).apply(to: image, width: 4, height: 2))
        #expect(pixels(half) == [["W", "W", "B", "B"], ["G", "G", "R", "R"]])
        let ccw = try #require(transform(rotation: 270).apply(to: image, width: 4, height: 2))
        #expect(pixels(ccw) == [["G", "W"], ["G", "W"], ["R", "B"], ["R", "B"]])
    }

    @Test func cropsAfterRotating() throws {
        let image = quadrants()
        let left = try #require(transform(right: 2).apply(to: image, width: 4, height: 2))
        #expect(pixels(left) == [["R", "R"], ["B", "B"]])
        // Turned to 2 × 4, then the top three rows cropped.
        let bottom = try #require(transform(rotation: 90, top: 3).apply(to: image, width: 4, height: 2))
        #expect(pixels(bottom) == [["W", "G"]])
        // Decoded at twice the size: the crop scales with it.
        let large = try #require(transform(right: 2).apply(to: upscaled(image), width: 4, height: 2))
        #expect(large.width == 4 && large.height == 4)
        #expect(MovieTransform().apply(to: image, width: 4, height: 2) === image)
    }

    @Test func aspectScaledSaves() {
        var t = MovieTransform()
        #expect(t.aspectScaledSize(width: 1920, height: 1080) == nil)
        t.aspectRatioInv = 0.75
        #expect(t.aspectScaledSize(width: 1920, height: 1080)! == (1920, 1440))
        t.aspectRatioInv = 1.5
        #expect(t.aspectScaledSize(width: 1080, height: 1920)! == (1280, 1920))
        let shaped = t.applyAspectRatio(to: quadrants())
        #expect(shaped.width == 1 && shaped.height == 2)
    }

    /// The untransformed video turned and moved so its crop fills the box.
    @Test func playbackPlacement() {
        let plain = MovieTransform().playbackPlacement(fitWidth: 480, fitHeight: 270, width: 1920, height: 1080)
        #expect(plain == PlaybackPlacement(width: 480, height: 270, offsetX: 0, offsetY: 0, rotation: 0))
        let turned = transform(rotation: 90).playbackPlacement(fitWidth: 270, fitHeight: 480, width: 1920, height: 1080)
        #expect(turned == PlaybackPlacement(width: 480, height: 270, offsetX: 0, offsetY: 0, rotation: 90))
        // The left half kept: the frame is twice the box wide, its center a
        // half box to the right.
        let left = transform(right: 960).playbackPlacement(fitWidth: 240, fitHeight: 270, width: 1920, height: 1080)
        #expect(left == PlaybackPlacement(width: 480, height: 270, offsetX: 120, offsetY: 0, rotation: 0))
    }

    @Test func transformedBackend() async throws {
        let base = StubBackend(image: quadrants(), width: 4, height: 2)
        let wrapped = TransformedBackend(base, transform: transform(rotation: 90, top: 1))
        #expect(wrapped.info.width == 2 && wrapped.info.height == 3)
        let frame = try await wrapped.frame(0, maxWidth: 2)
        #expect(pixels(frame.image) == [["B", "R"], ["W", "G"], ["W", "G"]])
        #expect(base.requested.value == [4])
        var got: [[String]] = []
        for await result in wrapped.frames([1], maxWidth: 1) {
            if case .success(let f) = result.result { got = pixels(f.image) }
        }
        #expect(got == [["B", "R"], ["W", "G"], ["W", "G"]])
        #expect(TransformedBackend.wrap(base, transform: MovieTransform()) is StubBackend)
    }

    /// The scan reads the transformed frame: rotated, then a view into the
    /// crop.
    @Test func scanConverterTransforms() {
        let source = OwnedBGRA(width: 4, height: 2)
        let bytes = source.data.assumingMemoryBound(to: UInt8.self)
        // B, G, R, A: left half red, right half blue.
        for y in 0..<2 {
            for x in 0..<4 {
                let p = bytes + y * source.bytesPerRow + x * 4
                p[0] = x < 2 ? 0 : 255
                p[1] = 0
                p[2] = x < 2 ? 255 : 0
                p[3] = 255
            }
        }
        let converter = ScanFrameConverter(
            uprightWidth: 4, uprightHeight: 2, orientation: .up, transform: transform(rotation: 90, top: 2),
            sourceWidth: 4, sourceHeight: 2)
        let frame = converter.transformed(converter.upright(source.frame))
        #expect(frame.width == 2 && frame.height == 2)
        // Turned clockwise, the right (blue) half is at the bottom.
        let out = frame.base.assumingMemoryBound(to: UInt8.self)
        #expect(out[0] == 255 && out[2] == 0)
        #expect(out[frame.bytesPerRow + 4] == 255)
    }

    @Test func transformObjectRoundTrip() throws {
        var t = transform(rotation: 270, top: 4, bottom: 6, left: 8, right: 10)
        t.aspectRatioInv = 0.4184
        let exchange = ExchangeTransform(t)
        #expect(exchange.rotationFlag == ExchangeTransform.rotate90CounterClockwise)
        let json = exchange.jsonText.rendered()
        #expect(json == #"{"cropTop":4,"cropLeft":8,"cropBottom":6,"cropRight":10,"rotationFlag":2,"aspectRatioInv":0.4184}"#)
        let read = try JSONDecoder().decode(ExchangeTransform.self, from: Data(json.utf8))
        #expect(read.movieTransform(keepRotation: true) == t)
        var imported = t
        imported.rotation = 0
        #expect(read.movieTransform(keepRotation: false) == imported)
    }
}

/// Returns one fixed image for every request and records the widths asked.
private final class StubBackend: DecodeBackend, @unchecked Sendable {
    let image: CGImage
    let info: MediaInfo
    let requested = LockedValue<[Int]>([])
    var kind: DecoderKind { .avFoundation }

    init(image: CGImage, width: Int, height: Int) {
        self.image = image
        info = MediaInfo(duration: 1, frameCount: 25, fps: 25, width: width, height: height, fourCC: "test", size: 1)
    }

    func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        requested.withLock { $0.append(maxWidth) }
        return DecodedFrame(image: image, requestedFrame: frameNumber, actualFrame: frameNumber, retried: false)
    }

    func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult> {
        concurrentFrames(frameNumbers, maxWidth: maxWidth, concurrency: 1)
    }

    func frameRun(_ range: ClosedRange<Int>, maxWidth: Int) -> AsyncStream<FrameResult> {
        concurrentFrames(Array(range), maxWidth: maxWidth, concurrency: 1)
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withLock(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
