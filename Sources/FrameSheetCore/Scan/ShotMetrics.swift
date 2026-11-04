import Accelerate
import CoreGraphics
import Foundation

// The per-frame shot metrics of §10, ported from MoviePrint v0.2.23 `detectCut`
// and `HSVtoRGB` (app/utils/utilsForOpencv.js, MIT,
// docs/licenses/MoviePrint-LICENSE). MoviePrint converts each frame, resized
// to 240 px on its long side, with OpenCV's 8-bit `COLOR_BGR2HSV` (H 0–179,
// S and V 0–255) and then:
// - Mean: difference = |mean V − previous mean V|; color = `HSVtoRGB` of the
//   mean H, S and V.
// - Histogram: a 32×32×32 histogram of H, S and V (each binned over 0–255,
//   so H fills bins 0–22), L2-normalized, compared with the previous frame's
//   by `HISTCMP_CHISQR_ALT`; the first frame is compared with itself (0);
//   color = mean R, G and B.

public enum ShotDetectionMethod: String, Codable, Sendable, CaseIterable {
    case mean, histogram

    public var label: String {
        switch self {
        case .mean: "Mean average"
        case .histogram: "Histogram"
        }
    }
}

/// HSV as OpenCV's 8-bit `COLOR_BGR2HSV` computes it: fixed point with 12
/// fraction bits and its rounding, so values match MoviePrint's.
enum HSV8 {
    static let shift: Int32 = 12
    private static let half: Int32 = 1 << (shift - 1)
    /// 255 / v and 180 / (6 · diff) in fixed point, rounded half to even.
    static let saturationDivisor: [Int32] = (0..<256).map {
        $0 == 0 ? 0 : Int32((Double(255 << 12) / Double($0)).rounded(.toNearestOrEven))
    }
    static let hueDivisor: [Int32] = (0..<256).map {
        $0 == 0 ? 0 : Int32((Double(180 << 12) / (6 * Double($0))).rounded(.toNearestOrEven))
    }

    @inline(__always)
    static func convert(red r: Int32, green g: Int32, blue b: Int32) -> (h: Int32, s: Int32, v: Int32) {
        let v = max(r, g, b)
        let diff = v - min(r, g, b)
        let s = (diff * saturationDivisor[Int(v)] + half) >> shift
        var h: Int32
        if v == r {
            h = g - b
        } else if v == g {
            h = b - r + 2 * diff
        } else {
            h = r - g + 4 * diff
        }
        h = (h * hueDivisor[Int(diff)] + half) >> shift
        if h < 0 { h += 180 }
        return (h, s, v)
    }
}

/// An sRGB color, 0–255 per channel.
public struct RGB8: Sendable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = RGB8(red: 0, green: 0, blue: 0)

    public var array: [Int] { [Int(red), Int(green), Int(blue)] }
}

public enum ShotMetrics {
    /// MoviePrint's `HSVtoRGB`: h in OpenCV's 0–180 range, s and v 0–255.
    public static func hsvToRGB(h: Double, s: Double, v: Double) -> RGB8 {
        let i = Int((h / 180 * 6).rounded(.down))
        let f = h / 180 * 6 - Double(i)
        let p = v / 255 * (1 - s / 255)
        let q = v / 255 * (1 - f * (s / 255))
        let t = v / 255 * (1 - (1 - f) * (s / 255))
        let value = v / 255
        let (r, g, b): (Double, Double, Double)
        switch ((i % 6) + 6) % 6 {
        case 0: (r, g, b) = (value, t, p)
        case 1: (r, g, b) = (q, value, p)
        case 2: (r, g, b) = (p, value, t)
        case 3: (r, g, b) = (p, q, value)
        case 4: (r, g, b) = (t, p, value)
        default: (r, g, b) = (value, p, q)
        }
        return RGB8(red: byte(r * 255), green: byte(g * 255), blue: byte(b * 255))
    }

    /// `Math.round` to a byte.
    static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value + 0.5).rounded(.down))))
    }

    /// OpenCV's `HISTCMP_CHISQR_ALT`: 2 · Σ (a − b)² / (a + b) over the bins
    /// where a + b is not zero.
    public static func chiSquareAlternative(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        var result = 0.0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for i in 0..<a.count {
                    let sum = Double(a[i]) + Double(b[i])
                    if abs(sum) > Double.ulpOfOne {
                        let d = Double(a[i]) - Double(b[i])
                        result += d * d / sum
                    }
                }
            }
        }
        return 2 * result
    }

    /// Mean of HSV V (max(R, G, B)) over a BGRA image: the brightness the
    /// automatic IN/OUT detection compares with 20.
    public static func meanV(_ frame: BGRAFrame) -> Double {
        var total: UInt64 = 0
        for y in 0..<frame.height {
            let row = (frame.base + y * frame.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var rowSum: UInt32 = 0
            var x = 0
            while x < frame.width * 4 {
                rowSum &+= UInt32(max(row[x], row[x + 1], row[x + 2]))
                x += 4
            }
            total += UInt64(rowSum)
        }
        return Double(total) / Double(max(1, frame.width * frame.height))
    }
}

/// A borrowed BGRA image: 8 bits per channel, blue first (Core Video's
/// `32BGRA`, ffmpeg's `bgra`). Valid only while its owner keeps it.
public struct BGRAFrame: @unchecked Sendable {
    public var base: UnsafeRawPointer
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int

    public init(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

/// Computes one method's difference and mean color frame by frame, keeping
/// the previous frame's values. Not thread-safe; one per scan.
final class ShotMetricCalculator {
    static let histogramBins = 32
    static let histogramSize = histogramBins * histogramBins * histogramBins

    let method: ShotDetectionMethod
    private var previousMeanV: Double?
    private var histogram: [Float]
    private var previousHistogram: [Float]
    private var hasPrevious = false

    init(method: ShotDetectionMethod) {
        self.method = method
        let size = method == .histogram ? Self.histogramSize : 0
        histogram = [Float](repeating: 0, count: size)
        previousHistogram = [Float](repeating: 0, count: size)
    }

    /// The frame's difference to the previous frame (0 for the first) and
    /// its mean color; the frame becomes the previous one.
    func measure(_ frame: BGRAFrame) -> (difference: Float, color: RGB8) {
        switch method {
        case .mean:
            let (h, s, v) = Self.meanHSV(frame)
            // MoviePrint compares the first frame with an empty value; it is
            // stored as 0 here (no cut can fall on frame 0 either way).
            let difference = previousMeanV.map { abs(v - $0) } ?? 0
            previousMeanV = v
            return (Float(difference), ShotMetrics.hsvToRGB(h: h, s: s, v: v))
        case .histogram:
            let color = fillHistogram(frame)
            let difference = hasPrevious
                ? ShotMetrics.chiSquareAlternative(histogram, previousHistogram) : 0
            swap(&histogram, &previousHistogram)
            hasPrevious = true
            return (Float(difference), color)
        }
    }

    /// Makes the frame the previous one without a result (resuming a scan
    /// re-reads the last stored frame).
    func seed(_ frame: BGRAFrame) {
        _ = measure(frame)
    }

    /// Means of H, S and V over the frame.
    static func meanHSV(_ frame: BGRAFrame) -> (h: Double, s: Double, v: Double) {
        var sumH = 0, sumS = 0, sumV = 0
        for y in 0..<frame.height {
            let row = (frame.base + y * frame.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < frame.width * 4 {
                let hsv = HSV8.convert(red: Int32(row[x + 2]), green: Int32(row[x + 1]), blue: Int32(row[x]))
                sumH += Int(hsv.h)
                sumS += Int(hsv.s)
                sumV += Int(hsv.v)
                x += 4
            }
        }
        let count = Double(max(1, frame.width * frame.height))
        return (Double(sumH) / count, Double(sumS) / count, Double(sumV) / count)
    }

    /// Fills `histogram` with the frame's normalized HSV histogram and
    /// returns its mean RGB color.
    private func fillHistogram(_ frame: BGRAFrame) -> RGB8 {
        var sumR = 0, sumG = 0, sumB = 0
        histogram.withUnsafeMutableBufferPointer { bins in
            bins.update(repeating: 0)
            for y in 0..<frame.height {
                let row = (frame.base + y * frame.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                var x = 0
                while x < frame.width * 4 {
                    let (b, g, r) = (Int32(row[x]), Int32(row[x + 1]), Int32(row[x + 2]))
                    sumR += Int(r)
                    sumG += Int(g)
                    sumB += Int(b)
                    let hsv = HSV8.convert(red: r, green: g, blue: b)
                    let index = Int(hsv.h >> 3) << 10 | Int(hsv.s >> 3) << 5 | Int(hsv.v >> 3)
                    bins[index] += 1
                    x += 4
                }
            }
            // cv::normalize with its defaults: L2 norm 1.
            var squares = 0.0
            for value in bins where value != 0 { squares += Double(value) * Double(value) }
            let scale = squares > 0 ? Float(1 / squares.squareRoot()) : 0
            for i in 0..<bins.count where bins[i] != 0 { bins[i] *= scale }
        }
        let count = Double(max(1, frame.width * frame.height))
        return RGB8(
            red: ShotMetrics.byte(Double(sumR) / count), green: ShotMetrics.byte(Double(sumG) / count),
            blue: ShotMetrics.byte(Double(sumB) / count))
    }
}

// MARK: - Frame geometry

/// How the track's preferred transform turns the decoded frame upright: a
/// quarter-turn rotation (vImage's constant) followed by an optional
/// horizontal mirror.
struct FrameOrientation: Equatable, Sendable {
    /// `kRotate0DegreesClockwise` … `kRotate90DegreesClockwise`.
    var rotation: UInt8
    var mirrored: Bool

    static let up = FrameOrientation(rotation: UInt8(kRotate0DegreesClockwise), mirrored: false)

    var isIdentity: Bool { self == .up }
    /// Width and height swap.
    var swapsAxes: Bool {
        rotation == UInt8(kRotate90DegreesClockwise) || rotation == UInt8(kRotate90DegreesCounterClockwise)
    }

    /// The orientation for a preferred track transform (in video coordinates,
    /// y down: `(0, 1, −1, 0)` shows the frame turned 90° clockwise).
    init(_ t: CGAffineTransform) {
        let (a, b, c, d) = (Int(t.a.rounded()), Int(t.b.rounded()), Int(t.c.rounded()), Int(t.d.rounded()))
        switch (a, b, c, d) {
        case (-1, 0, 0, -1): self.init(rotation: UInt8(kRotate180DegreesClockwise), mirrored: false)
        case (0, 1, -1, 0): self.init(rotation: UInt8(kRotate90DegreesClockwise), mirrored: false)
        case (0, -1, 1, 0): self.init(rotation: UInt8(kRotate90DegreesCounterClockwise), mirrored: false)
        case (-1, 0, 0, 1): self.init(rotation: UInt8(kRotate0DegreesClockwise), mirrored: true)
        case (1, 0, 0, -1): self.init(rotation: UInt8(kRotate180DegreesClockwise), mirrored: true)
        case (0, 1, 1, 0): self.init(rotation: UInt8(kRotate90DegreesClockwise), mirrored: true)
        case (0, -1, -1, 0): self.init(rotation: UInt8(kRotate90DegreesCounterClockwise), mirrored: true)
        default: self.init(rotation: UInt8(kRotate0DegreesClockwise), mirrored: false)
        }
    }

    init(rotation: UInt8, mirrored: Bool) {
        self.rotation = rotation
        self.mirrored = mirrored
    }
}

enum ScanGeometry {
    /// Long side of the frames the scan decodes (faces use them; §10).
    static let decodeSide = 720
    /// Long side of the frames the shot metric reads (MoviePrint's 240).
    static let metricSide = 240

    /// The size whose long side is at most `maxSide` (never enlarged),
    /// aspect kept, both sides even and at least 2.
    static func fit(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let w = max(1, width), h = max(1, height)
        guard max(w, h) > maxSide else { return (even(Double(w)), even(Double(h))) }
        if w >= h { return (even(Double(maxSide)), even(Double(h) * Double(maxSide) / Double(w))) }
        return (even(Double(w) * Double(maxSide) / Double(h)), even(Double(maxSide)))
    }
}

/// An owned BGRA buffer.
final class OwnedBGRA {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: UnsafeMutableRawPointer

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = (width * 4 + 63) / 64 * 64
        data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
    }

    deinit { data.deallocate() }

    var vImage: vImage_Buffer {
        vImage_Buffer(
            data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
    }

    var frame: BGRAFrame { BGRAFrame(base: data, width: width, height: height, bytesPerRow: bytesPerRow) }
}

/// Turns decoded frames upright and derives the 240 px metric frame with
/// vImage, reusing its buffers.
final class ScanFrameConverter {
    let orientation: FrameOrientation
    /// The upright decode size (long side up to 720).
    let uprightWidth: Int
    let uprightHeight: Int
    private var upright: OwnedBGRA?
    private var mirror: OwnedBGRA?
    private let metric: OwnedBGRA
    private var scaleTemp: UnsafeMutableRawPointer?

    /// The movie's transform (rotation and crop, §3), applied after the
    /// frame is upright, and the crop in the upright frame's pixels.
    let transform: MovieTransform
    private let crop: (x: Int, y: Int, width: Int, height: Int)
    private var turned: OwnedBGRA?

    /// `sourceWidth` × `sourceHeight` is the movie's upright size, which the
    /// transform's crop refers to.
    init(
        uprightWidth: Int, uprightHeight: Int, orientation: FrameOrientation, transform: MovieTransform = MovieTransform(),
        sourceWidth: Int = 0, sourceHeight: Int = 0
    ) {
        self.uprightWidth = uprightWidth
        self.uprightHeight = uprightHeight
        self.orientation = orientation
        self.transform = transform
        let (rw, rh) = transform.rotatedSize(width: uprightWidth, height: uprightHeight)
        if transform.keepsImage || sourceWidth <= 0 || sourceHeight <= 0 {
            crop = (0, 0, rw, rh)
        } else {
            let rect = transform.cropRect(width: sourceWidth, height: sourceHeight)
            let (sw, sh) = transform.rotatedSize(width: sourceWidth, height: sourceHeight)
            let sx = Double(rw) / Double(sw), sy = Double(rh) / Double(sh)
            let x = min(rw - 1, Int((Double(rect.x) * sx).rounded()))
            let y = min(rh - 1, Int((Double(rect.y) * sy).rounded()))
            crop = (
                x, y, max(1, min(rw - x, Int((Double(rect.width) * sx).rounded()))),
                max(1, min(rh - y, Int((Double(rect.height) * sy).rounded()))))
        }
        let size = ScanGeometry.fit(width: crop.width, height: crop.height, maxSide: ScanGeometry.metricSide)
        metric = OwnedBGRA(width: size.width, height: size.height)
    }

    deinit { scaleTemp?.deallocate() }

    /// The decoded size: the upright size, turned back when the frame is
    /// rotated by a quarter.
    var decodedWidth: Int { orientation.swapsAxes ? uprightHeight : uprightWidth }
    var decodedHeight: Int { orientation.swapsAxes ? uprightWidth : uprightHeight }

    /// The upright frame: `source` itself, or a rotated copy.
    func upright(_ source: BGRAFrame) -> BGRAFrame {
        guard !orientation.isIdentity else { return source }
        var src = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source.base), height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width), rowBytes: source.bytesPerRow)
        let target = upright ?? OwnedBGRA(width: uprightWidth, height: uprightHeight)
        upright = target
        var dst = target.vImage
        let back: [UInt8] = [0, 0, 0, 255]
        vImageRotate90_ARGB8888(&src, &dst, orientation.rotation, back, vImage_Flags(kvImageNoFlags))
        guard orientation.mirrored else { return target.frame }
        let mirrored = mirror ?? OwnedBGRA(width: uprightWidth, height: uprightHeight)
        mirror = mirrored
        var mirrorBuffer = mirrored.vImage
        vImageHorizontalReflect_ARGB8888(&dst, &mirrorBuffer, vImage_Flags(kvImageNoFlags))
        return mirrored.frame
    }

    /// The upright frame rotated and cropped by the movie's transform: a
    /// view into `upright` when only cropped (valid until the next call).
    func transformed(_ upright: BGRAFrame) -> BGRAFrame {
        guard !transform.keepsImage else { return upright }
        var frame = upright
        if transform.rotation != 0 {
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: upright.base), height: vImagePixelCount(upright.height),
                width: vImagePixelCount(upright.width), rowBytes: upright.bytesPerRow)
            let (rw, rh) = transform.rotatedSize(width: upright.width, height: upright.height)
            let target = turned ?? OwnedBGRA(width: rw, height: rh)
            turned = target
            var dst = target.vImage
            let constant = switch transform.rotation {
            case 90: kRotate90DegreesClockwise
            case 180: kRotate180DegreesClockwise
            default: kRotate90DegreesCounterClockwise
            }
            vImageRotate90_ARGB8888(&src, &dst, UInt8(constant), [0, 0, 0, 255], vImage_Flags(kvImageNoFlags))
            frame = target.frame
        }
        let x = min(crop.x, frame.width - 1), y = min(crop.y, frame.height - 1)
        return BGRAFrame(
            base: frame.base + y * frame.bytesPerRow + x * 4, width: min(crop.width, frame.width - x),
            height: min(crop.height, frame.height - y), bytesPerRow: frame.bytesPerRow)
    }

    /// The upright frame scaled to the metric size (valid until the next call).
    func metricFrame(_ upright: BGRAFrame) -> BGRAFrame {
        var src = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: upright.base), height: vImagePixelCount(upright.height),
            width: vImagePixelCount(upright.width), rowBytes: upright.bytesPerRow)
        var dst = metric.vImage
        if scaleTemp == nil {
            let size = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageGetTempBufferSize))
            if size > 0 { scaleTemp = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 64) }
        }
        vImageScale_ARGB8888(&src, &dst, scaleTemp, vImage_Flags(kvImageNoFlags))
        return metric.frame
    }
}
