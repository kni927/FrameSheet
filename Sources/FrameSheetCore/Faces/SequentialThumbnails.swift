import Accelerate
import CoreGraphics
import Foundation

/// Thumbnails of many frames read in one sequential pass (the scan's
/// `frameList` pass) instead of one random-access request each: for a
/// faces sheet opened after a relaunch, whose hundreds of thumbs are no
/// longer in memory (T08; one request per frame took minutes on open-GOP
/// films, the face scan's own pass seconds). The frames are the scan's
/// upright 720 px frames with the movie's transform, so each thumbnail is
/// the exact frame.
public enum SequentialThumbnails {
    /// Reads `frames` (any order) and delivers each one's thumbnail, at most
    /// `width` pixels wide, in frame order on the pass's task. Ends with
    /// `.finished`, `.cancelled` (the consuming task was cancelled) or
    /// `.failed`. The pass holds the DecodeGate and lets other decodes go
    /// first in turns, as the scans do.
    public static func read(
        url: URL, frames: [Int], width: Int, transform: MovieTransform, ffmpeg: FFmpegTools?,
        log: ScanLogSink? = nil, deliver: @escaping @Sendable (_ frame: Int, _ image: CGImage) -> Void
    ) -> AsyncStream<ScanEvent> {
        var request = ScanRequest(
            fileId: UUID(), url: url, method: .mean, threshold: 0, ffmpeg: ffmpeg, store: nil,
            observer: Collector(width: width, deliver: deliver))
        request.frameList = Array(Set(frames)).sorted()
        request.transform = transform
        request.log = log
        return ShotScanner.scan(request)
    }

    private final class Collector: ScanFrameObserver, @unchecked Sendable {
        let width: Int
        let deliver: @Sendable (Int, CGImage) -> Void
        init(width: Int, deliver: @escaping @Sendable (Int, CGImage) -> Void) {
            self.width = width
            self.deliver = deliver
        }

        func scanned(_ frame: ScanFrame) async {
            if let image = SequentialThumbnails.thumbnail(of: frame.image, width: width) {
                deliver(frame.frameNumber, image)
            }
        }
    }

    /// A scan frame scaled to at most `width` pixels wide (aspect kept,
    /// never enlarged), tagged Rec. 709 as the face scan's thumbnails are.
    static func thumbnail(of frame: BGRAFrame, width: Int) -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let w = min(max(1, width), frame.width)
        let h = max(1, Int((Double(w) * Double(frame.height) / Double(frame.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data
        else { return nil }
        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: frame.base), height: vImagePixelCount(frame.height),
            width: vImagePixelCount(frame.width), rowBytes: frame.bytesPerRow)
        var target = vImage_Buffer(
            data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: context.bytesPerRow)
        guard vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
        else { return nil }
        return context.makeImage()
    }
}
