import AVFoundation
import CoreVideo
import Foundation

// Automatic IN/OUT detection (§10, Experimental), ported from MoviePrint
// v0.2.23's `send-get-in-and-outpoint` handler (app/worker_opencv.js, MIT,
// docs/licenses/MoviePrint-LICENSE) with `IN_OUT_POINT_SEARCH_LENGTH` 300 and
// `IN_OUT_POINT_SEARCH_THRESHOLD` 20 (app/utils/constants.js). MoviePrint
// reads the first min(300, last frame / 2) frames, stopping at the first one
// whose mean V (frame scaled to a quarter) reaches 20, and the frames from
// last frame − that length to the last frame; then it takes the first frame
// (from the start, and from the end) whose mean is above 20, or else the
// brightest frame. The threshold is a setting here (Brightness threshold,
// default 20; owner, 2026-11-03).

public enum AutoInOut {
    public static let searchLength = 300
    /// MoviePrint's threshold, the default of the setting.
    public static let defaultThreshold = Defaults.automaticInOutThreshold
    /// Frames are measured at this fraction of the movie's size.
    public static let scale = 0.25

    /// The frames searched for IN (from the start) and OUT (to the end).
    public static func searchRanges(frameCount: Int) -> (in: Range<Int>, out: ClosedRange<Int>)? {
        let last = frameCount - 1
        guard last > 0 else { return nil }
        let length = min(Double(searchLength), Double(last) / 2)
        let inEnd = Int(length.rounded(.up))
        let outStart = Int((Double(last) - length).rounded(.up))
        return (0..<max(1, inEnd), min(outStart, last)...last)
    }

    /// MoviePrint's reduction of the measured means. `inMeans` runs from the
    /// start (as far as it was read), `outMeans` in frame order up to
    /// `lastFrame`. A frame above `threshold` wins from either end;
    /// otherwise the brightest frame does, a later frame winning a tie for
    /// IN and an earlier one for OUT (the order MoviePrint reduces in).
    public static func points(
        inMeans: [(frame: Int, mean: Double)], outMeans: [(frame: Int, mean: Double)], lastFrame: Int,
        threshold: Double = defaultThreshold
    ) -> (inFrame: Int, outFrame: Int) {
        func reduce(_ means: some Sequence<(frame: Int, mean: Double)>, initial: Int) -> Int {
            var brightest = (frame: initial, mean: 0.0)
            var above: Int?
            for current in means {
                let larger = brightest.mean > current.mean ? brightest : current
                if above == nil, current.mean > threshold { above = current.frame }
                brightest = larger
            }
            return above ?? brightest.frame
        }
        return (reduce(inMeans, initial: 0), reduce(outMeans.reversed(), initial: lastFrame))
    }

    /// Detects IN and OUT for a movie, decoding the searched frames
    /// sequentially under the DecodeGate (AVFoundation, or ffmpeg for files
    /// routed there). A range that cannot be read keeps its end of the movie.
    public static func detect(
        _ url: URL, ffmpeg: FFmpegTools?, threshold: Double = defaultThreshold
    ) async throws -> (inFrame: Int, outFrame: Int) {
        let source = try await ScanSource.open(url, ffmpeg: ffmpeg)
        let frameCount = source.info.frameCount
        guard let ranges = searchRanges(frameCount: frameCount) else { return (0, max(0, frameCount - 1)) }
        await DecodeGate.shared.acquire()
        do {
            let inMeans = (try? await means(
                source, ranges.in.lowerBound, ranges.in.upperBound - 1, stopAt: threshold)) ?? []
            let outMeans = (try? await means(source, ranges.out.lowerBound, ranges.out.upperBound, stopAt: nil)) ?? []
            try Task.checkCancellation()
            await DecodeGate.shared.release()
            return points(inMeans: inMeans, outMeans: outMeans, lastFrame: frameCount - 1, threshold: threshold)
        } catch {
            await DecodeGate.shared.release()
            throw error
        }
    }

    /// Detects IN and OUT for a movie entry and stores them in it, so a
    /// default sheet made afterwards lies between them (Add movies with
    /// Automatic IN/OUT on). Returns false, leaving the entry as it was, when
    /// the detection gives no range (OUT not after IN).
    @discardableResult
    public static func apply(
        to file: inout MovieFile, ffmpeg: FFmpegTools?, threshold: Double = defaultThreshold
    ) async throws -> Bool {
        let points = try await detect(file.url, ffmpeg: ffmpeg, threshold: threshold)
        guard points.inFrame < points.outFrame else { return false }
        file.inFrame = points.inFrame
        file.outFrame = points.outFrame
        return true
    }

    /// Mean V of frames `first`…`last`, in order; with `stopAt` the first
    /// frame at or above that threshold is the last one read.
    private static func means(
        _ source: ScanSource, _ first: Int, _ last: Int, stopAt: Double?
    ) async throws -> [(frame: Int, mean: Double)] {
        let size = ScanGeometry.fit(
            width: Int((Double(source.info.width) * scale).rounded()),
            height: Int((Double(source.info.height) * scale).rounded()), maxSide: .max)
        var result: [(frame: Int, mean: Double)] = []
        let fps = source.fps
        switch source.kind {
        case .avFoundation(let asset, let startTime, let orientation):
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
            let reader = try AVAssetReader(asset: asset)
            var start = CMTime(seconds: startTime + (Double(first) - 0.25) / fps, preferredTimescale: 600_000)
            // The OUT range starts inside the movie: in an open-GOP file the
            // read starts at a closed GOP before it (frames before `first`
            // are skipped below).
            if first > 0, let closed = await ClosedGOPStart.time(
                track, atOrBefore: start, notBefore: start - ClosedGOPStart.maximumPreRoll), closed < start {
                start = closed
            }
            reader.timeRange = CMTimeRange(
                start: start,
                end: CMTime(seconds: startTime + (Double(last) + 0.75) / fps, preferredTimescale: 600_000))
            let (w, h) = orientation.swapsAxes ? (size.height, size.width) : (size.width, size.height)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
            let provider = reader.outputProvider(for: output)
            try reader.start()
            defer { reader.cancelReading() }
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                let frame = Int(((sample.presentationTimeStamp.seconds - startTime) * fps).rounded())
                guard frame >= first, frame <= last, frame > (result.last?.frame ?? -1) else { continue }
                guard let buffer = sample.withUnsafeSampleBuffer({ PixelBufferBox($0) })?.buffer else { continue }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { continue }
                let mean = ShotMetrics.meanV(BGRAFrame(
                    base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)))
                result.append((frame, mean))
                if let stopAt, mean >= stopAt { break }
            }
        case .ffmpeg(let tools):
            let count = last - first + 1
            var arguments = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]
            if first > 0 { arguments += ["-ss", String(format: "%.6f", (Double(first) - 0.5) / fps)] }
            arguments += [
                "-i", source.url.nfcPath, "-map", "0:v:0", "-an", "-sn", "-dn", "-frames:v", "\(count)",
                "-vf", "scale=\(size.width):\(size.height)", "-pix_fmt", "bgra", "-f", "rawvideo", "-",
            ]
            let pipe = RawVideoPipe(executable: tools.ffmpeg, arguments: arguments)
            try pipe.start()
            let bytes = size.width * size.height * 4
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            defer { buffer.deallocate() }
            var frame = first
            do {
                while frame <= last, try await pipe.readFrame(into: buffer, count: bytes) {
                    let mean = ShotMetrics.meanV(
                        BGRAFrame(base: buffer, width: size.width, height: size.height, bytesPerRow: size.width * 4))
                    result.append((frame, mean))
                    frame += 1
                    if let stopAt, mean >= stopAt { break }
                }
            } catch {
                pipe.terminate()
                _ = await pipe.finish()
                throw error
            }
            pipe.terminate()
            _ = await pipe.finish()
        }
        return result
    }
}
