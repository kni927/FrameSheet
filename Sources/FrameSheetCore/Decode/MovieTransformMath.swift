import CoreGraphics
import Foundation

// Rotation, cropping and aspect ratio of a movie (§3, §4 "Edit
// rotation/cropping/aspect ratio"), as MoviePrint v0.2.23 applies its
// `transformObject` (app/utils/utilsForOpencv.js `transformMat`,
// `getCropRect`; app/components/EditTransformModal.js; MIT,
// docs/licenses/MoviePrint-LICENSE): the upright frame is rotated first, then
// cropped in the rotated frame's pixels. The aspect ratio does not change the
// decoded image; thumbs are drawn (and saved thumbs scaled) to it.

extension MovieTransform {
    /// Rotation and crop leave the frame as it is.
    public var keepsImage: Bool {
        rotation == 0 && cropTop == 0 && cropBottom == 0 && cropLeft == 0 && cropRight == 0
    }

    /// Width and height swap (90° and 270°).
    public var swapsAxes: Bool { rotation == 90 || rotation == 270 }

    /// The frame size after the rotation.
    public func rotatedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }

    /// The crop in the rotated frame's pixels (origin top left), each edge
    /// clamped so at least one pixel remains (MoviePrint's
    /// `handleCropInputChange`).
    public func cropRect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let (w, h) = rotatedSize(width: max(1, width), height: max(1, height))
        let left = min(max(0, cropLeft), w - 1)
        let right = min(max(0, cropRight), w - 1 - left)
        let top = min(max(0, cropTop), h - 1)
        let bottom = min(max(0, cropBottom), h - 1 - top)
        return (left, top, w - left - right, h - top - bottom)
    }

    /// The size of the transformed frame for a movie of `width` × `height`
    /// (the upright size the probe reports).
    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let rect = cropRect(width: width, height: height)
        return (rect.width, rect.height)
    }

    /// Height / width the thumbs are drawn at: the aspect ratio if one is
    /// set, else the transformed frame's.
    public func displayAspectRatioInv(width: Int, height: Int) -> Double {
        if let aspectRatioInv, aspectRatioInv > 0 { return aspectRatioInv }
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        let size = outputSize(width: width, height: height)
        return Double(size.height) / Double(size.width)
    }

    /// The same transform with each crop edge clamped as `cropRect` does.
    public func clamped(width: Int, height: Int) -> MovieTransform {
        let (w, h) = rotatedSize(width: max(1, width), height: max(1, height))
        let rect = cropRect(width: width, height: height)
        var t = self
        t.cropLeft = rect.x
        t.cropTop = rect.y
        t.cropRight = w - rect.x - rect.width
        t.cropBottom = h - rect.y - rect.height
        return t
    }

    /// A crop preset (MoviePrint's `handleCropDropdownChange`): crops top and
    /// bottom, or left and right, equally so the rotated frame takes the
    /// height / width `ratioInv`; nil removes the crop.
    public func croppedTo(ratioInv: Double?, width: Int, height: Int) -> MovieTransform {
        var t = self
        t.cropTop = 0
        t.cropBottom = 0
        t.cropLeft = 0
        t.cropRight = 0
        guard let ratioInv, ratioInv > 0, width > 0, height > 0 else { return t }
        let (w, h) = rotatedSize(width: width, height: height)
        if ratioInv <= Double(h) / Double(w) {
            let each = Int((Double(h) - ratioInv * Double(w)) / 2)
            t.cropTop = each
            t.cropBottom = each
        } else {
            let each = Int((Double(w) - Double(h) / ratioInv) / 2)
            t.cropLeft = each
            t.cropRight = each
        }
        return t.clamped(width: width, height: height)
    }

    /// The `maxWidth` to decode the upright frame at so the transformed
    /// frame is at most `maxWidth` wide (never enlarged).
    public func sourceMaxWidth(forOutput maxWidth: Int, width: Int, height: Int) -> Int {
        guard !keepsImage, width > 0, height > 0 else { return maxWidth }
        let output = outputSize(width: width, height: height)
        let scale = min(1, Double(max(1, maxWidth)) / Double(output.width))
        return max(1, Int((Double(width) * scale).rounded()))
    }

    /// The transformed image of an upright frame decoded from a movie of
    /// `width` × `height` (it may be decoded smaller; the crop is scaled to
    /// it). Returns the image itself when nothing changes.
    public func apply(to image: CGImage, width: Int, height: Int) -> CGImage? {
        guard !keepsImage else { return image }
        let turned = rotation == 0 ? image : Self.rotate(image, degrees: rotation)
        guard let turned else { return nil }
        let rect = cropRect(width: width, height: height)
        let (rw, rh) = rotatedSize(width: max(1, width), height: max(1, height))
        let sx = Double(turned.width) / Double(rw)
        let sy = Double(turned.height) / Double(rh)
        let x = Int((Double(rect.x) * sx).rounded())
        let y = Int((Double(rect.y) * sy).rounded())
        let w = max(1, min(turned.width - x, Int((Double(rect.width) * sx).rounded())))
        let h = max(1, min(turned.height - y, Int((Double(rect.height) * sy).rounded())))
        if x == 0, y == 0, w == turned.width, h == turned.height { return turned }
        return turned.cropping(to: CGRect(x: x, y: y, width: w, height: h))
    }

    /// The image turned clockwise by 90, 180 or 270 degrees.
    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let (w, h) = (image.width, image.height)
        let quarter = degrees == 90 || degrees == 270
        let (outW, outH) = quarter ? (h, w) : (w, h)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        // Core Graphics has y up: a clockwise turn on screen is a negative
        // angle.
        switch degrees {
        case 90:
            context.translateBy(x: 0, y: CGFloat(w))
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: CGFloat(w), y: CGFloat(h))
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: CGFloat(h), y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// The pixel size a saved thumb or frame is scaled to for the aspect
    /// ratio (MoviePrint's `resizeMat` with `useAspectRatio`): a landscape
    /// ratio keeps the width, a portrait one the height. Nil keeps the size.
    public func aspectScaledSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard let aspectRatioInv, aspectRatioInv > 0, width > 0, height > 0 else { return nil }
        let size = aspectRatioInv <= 1
            ? (width, max(1, Int((Double(width) * aspectRatioInv).rounded())))
            : (max(1, Int((Double(height) / aspectRatioInv).rounded())), height)
        return size == (width, height) ? nil : size
    }

    /// A saved thumb or frame scaled to the aspect ratio
    /// (`aspectScaledSize`); the image itself when none is set.
    public func applyAspectRatio(to image: CGImage) -> CGImage {
        guard let size = aspectScaledSize(width: image.width, height: image.height) else { return image }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage() ?? image
    }
}

/// Where the untransformed video (AVPlayer's layer, ffmpeg playback's
/// frames) is drawn so that, turned by `rotation` degrees clockwise about
/// its center and moved by the offset, its crop fills the fitted box: its
/// size before turning, and the offset of its center from the box's.
public struct PlaybackPlacement: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var offsetX: Double
    public var offsetY: Double
    public var rotation: Int
}

extension MovieTransform {
    /// The placement of a `width` × `height` (upright) movie's video in a
    /// box of `fitWidth` × `fitHeight` points that shows the transformed
    /// frame (the crop stretched to the box, as the thumbs are).
    public func playbackPlacement(fitWidth: Double, fitHeight: Double, width: Int, height: Int) -> PlaybackPlacement {
        guard width > 0, height > 0, fitWidth > 0, fitHeight > 0 else {
            return PlaybackPlacement(width: fitWidth, height: fitHeight, offsetX: 0, offsetY: 0, rotation: 0)
        }
        let crop = cropRect(width: width, height: height)
        let (rw, rh) = rotatedSize(width: width, height: height)
        let sx = fitWidth / Double(crop.width), sy = fitHeight / Double(crop.height)
        // The turned frame's center in the box, from the box's center.
        let centerX = -Double(crop.x) * sx + Double(rw) * sx / 2 - fitWidth / 2
        let centerY = -Double(crop.y) * sy + Double(rh) * sy / 2 - fitHeight / 2
        let (w, h) = swapsAxes ? (Double(width) * sy, Double(height) * sx) : (Double(width) * sx, Double(height) * sy)
        return PlaybackPlacement(width: w, height: h, offsetX: centerX, offsetY: centerY, rotation: rotation)
    }
}

/// The choices of the transform dialog (MoviePrint's `ROTATION_OPTIONS`,
/// `CROP_OPTIONS` and `ASPECT_RATIO_OPTIONS`; ratios as height / width).
public enum TransformOptions {
    public static let rotations: [(label: String, degrees: Int)] = [
        ("No rotation", 0), ("90° clockwise", 90), ("180°", 180), ("90° counterclockwise", 270),
    ]

    /// MoviePrint lists 2.21:1 as 0.5525, which is 1.81:1; 1 / 2.21 is used.
    public static let cropPresets: [(label: String, ratioInv: Double)] = [
        ("16:10", 0.625), ("16:9", 0.5625), ("4:3", 0.75), ("1.85:1", 0.5405), ("2.21:1", 0.4525),
        ("2.35:1", 0.4255), ("2.39:1", 0.4184), ("2:1", 0.5), ("5:3", 0.6), ("5:4", 0.8), ("1:1", 1.0),
        ("4:5", 1.25), ("2:3", 1.5), ("9:16", 1.7778),
    ]

    public static let aspectRatios: [(label: String, ratioInv: Double)] = [
        ("16:9", 0.5625), ("4:3", 0.75), ("1:1", 1.0), ("16:10", 0.625), ("1.85:1", 0.5405), ("2.21:1", 0.4525),
        ("2.35:1", 0.4255), ("2.39:1", 0.4184), ("5:3", 0.6), ("5:4", 0.8),
    ]
}

extension MovieFile {
    /// The frame size after rotation and crop (what thumbs, scrub, player
    /// and saved images show, before the aspect ratio).
    public var frameSize: (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        return transform.outputSize(width: width, height: height)
    }

    /// Height / width the movie's frames are shown at (§3 transform).
    public var displayAspectRatioInv: Double {
        transform.displayAspectRatioInv(width: width, height: height)
    }
}

/// A backend whose frames are rotated and cropped by a movie's transform:
/// the one place every consumer (thumbs, scrub, player stills and strip,
/// face analysis, saved prints and frames) gets its transformed image.
/// `info` reports the transformed size.
public struct TransformedBackend: DecodeBackend {
    public let base: any DecodeBackend
    public let transform: MovieTransform
    public let info: MediaInfo

    public init(_ base: any DecodeBackend, transform: MovieTransform) {
        self.base = base
        self.transform = transform
        var info = base.info
        let size = transform.outputSize(width: info.width, height: info.height)
        info.width = size.width
        info.height = size.height
        self.info = info
    }

    /// `base` itself when the transform keeps the image.
    public static func wrap(_ base: any DecodeBackend, transform: MovieTransform) -> any DecodeBackend {
        transform.keepsImage ? base : TransformedBackend(base, transform: transform)
    }

    public var kind: DecoderKind { base.kind }

    private func sourceWidth(_ maxWidth: Int) -> Int {
        transform.sourceMaxWidth(forOutput: maxWidth, width: base.info.width, height: base.info.height)
    }

    private func transformed(_ frame: DecodedFrame) throws -> DecodedFrame {
        guard let image = transform.apply(to: frame.image, width: base.info.width, height: base.info.height) else {
            throw DecodeError("The frame could not be rotated or cropped")
        }
        var frame = frame
        frame.image = image
        return frame
    }

    private func transformed(_ result: FrameResult) -> FrameResult {
        var result = result
        if case .success(let frame) = result.result {
            do { result.result = .success(try transformed(frame)) } catch let error as DecodeError {
                result.result = .failure(error)
            } catch {
                result.result = .failure(DecodeError(error.localizedDescription))
            }
        }
        return result
    }

    private func mapped(_ stream: AsyncStream<FrameResult>) -> AsyncStream<FrameResult> {
        AsyncStream { continuation in
            let task = Task {
                for await result in stream { continuation.yield(transformed(result)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        try transformed(try await base.frame(frameNumber, maxWidth: sourceWidth(maxWidth)))
    }

    public func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult> {
        mapped(base.frames(frameNumbers, maxWidth: sourceWidth(maxWidth)))
    }

    public func frameRun(_ range: ClosedRange<Int>, maxWidth: Int) -> AsyncStream<FrameResult> {
        mapped(base.frameRun(range, maxWidth: sourceWidth(maxWidth)))
    }
}
