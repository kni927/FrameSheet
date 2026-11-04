import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import VideoToolbox

// Ported from v2 src/AVFoundationBackend.swift: the probe, the zero-tolerance
// AVAssetImageGenerator with one ±0.5 s retry per failed frame (decision 11),
// and the fourCC naming. Rewritten for Swift 6 concurrency and the async
// AVFoundation loading API; frames are addressed by frame number.

/// In-process decode with VideoToolbox. The asset stays open for the movie,
/// so later requests hit a warm decoder.
public final class AVFoundationBackend: DecodeBackend {
    public let kind = DecoderKind.avFoundation
    public let info: MediaInfo
    let asset: AVURLAsset
    /// Presentation time of frame 0 (the video track's start), in seconds;
    /// AVPlayer's item time of frame n starts at `startTime + n / fps`.
    public let startTime: Double
    /// Reads the frames the exact image-generator request misses from one
    /// GOP earlier (decision 25).
    let reader: EarlierGOPReader
    /// Fetches the frames AVFoundation cannot decode exactly (decision 25);
    /// set and cleared by `setExactFallback` while the movie stays open.
    private let fallbackState: Mutex<FFmpegFrameFallback?>
    private let url: URL

    private static let retryTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    private init(
        asset: AVURLAsset, url: URL, info: MediaInfo, startTime: Double, reader: EarlierGOPReader,
        fallback: FFmpegTools?
    ) {
        self.asset = asset
        self.url = url
        self.info = info
        self.startTime = startTime
        self.reader = reader
        fallbackState = Mutex(fallback.map { FFmpegFrameFallback(url: url, tools: $0) })
    }

    /// The ffmpeg fallback in use, if any.
    var fallback: FFmpegFrameFallback? { fallbackState.withLock { $0 } }

    /// Turns the ffmpeg fallback on (with `tools`) or off (nil) for later
    /// requests, keeping the movie open (Settings → Fetch exact frames with
    /// ffmpeg). The same tools keep the fallback already opened.
    public func setExactFallback(_ tools: FFmpegTools?) {
        fallbackState.withLock { current in
            guard let tools else { current = nil; return }
            if let current, current.tools == tools { return }
            current = FFmpegFrameFallback(url: url, tools: tools)
        }
    }

    /// Opens the movie, or throws `RoutingError` when the file should go to
    /// ffmpeg instead (no decodable video track, or HEVC tagged `hev1`).
    /// A frame whose exact request fails or returns another frame is read
    /// from one GOP earlier, and when that fails too, fetched with
    /// `fallback` if given (decision 25).
    public static func open(_ url: URL, fallback: FFmpegTools? = nil) async throws -> AVFoundationBackend {
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        do {
            guard let first = try await asset.loadTracks(withMediaType: .video).first else {
                throw RoutingError("AVFoundation found no video track")
            }
            track = first
        } catch let error as RoutingError {
            throw error
        } catch {
            throw RoutingError("AVFoundation cannot open the file (\(error.localizedDescription))")
        }

        let (decodable, formats, naturalSize, transform, nominalRate, timeRange, canCursor) = try await track.load(
            .isDecodable, .formatDescriptions, .naturalSize, .preferredTransform, .nominalFrameRate,
            .timeRange, .canProvideSampleCursors)
        let fourCC = formats.first.map { fourCCString(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
        guard decodable else {
            throw RoutingError("AVFoundation cannot decode \(fourCC.isEmpty ? "this codec" : fourCC)")
        }
        // VideoToolbox rejects HEVC with the hev1 sample entry (-12906); the
        // spike found that the track still reports itself decodable.
        guard fourCC != "hev1" else {
            throw RoutingError("HEVC tagged hev1 is not decodable by AVFoundation")
        }

        // The video track's own length: the file's duration can include a
        // longer audio track, which would put the last frames past the video.
        let trackDuration = timeRange.duration.seconds
        let duration = trackDuration.isFinite && trackDuration > 0
            ? trackDuration : try await asset.load(.duration).seconds
        let display = naturalSize.applying(transform)
        let fps = Double(nominalRate)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let info = MediaInfo(
            duration: safeDuration,
            frameCount: fps > 0 ? Int((safeDuration * fps).rounded()) : 0,
            fps: fps,
            width: Int(abs(display.width).rounded()),
            height: Int(abs(display.height).rounded()),
            fourCC: fourCC, size: size)
        let start = timeRange.start.seconds.isFinite ? timeRange.start.seconds : 0
        let reader = EarlierGOPReader(
            asset: asset, info: info, startTime: start, transform: transform,
            canProvideSampleCursors: canCursor)
        return AVFoundationBackend(
            asset: asset, url: url, info: info, startTime: start, reader: reader, fallback: fallback)
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Frames

    /// The middle of the frame's display interval, so a zero-tolerance
    /// request cannot land on the neighbour through rounding.
    private func time(of frame: Int) -> CMTime {
        let fps = info.fps > 0 ? info.fps : 25
        let seconds = min(Double(frame) + 0.5, max(0.5, info.duration * fps - 0.25)) / fps
        return CMTime(seconds: startTime + seconds, preferredTimescale: 600_000)
    }

    /// Where the ±0.5 s retry asks: the exact time, but no later than half
    /// the tolerance before the video ends, so the whole window lies inside
    /// the movie (the ffmpeg path likewise retries 0.5 s earlier). Centred on
    /// the last frame, half the window would lie past the end; a movie whose
    /// last frames do not decode then failed although a frame a little
    /// earlier did (the print's last thumb, T04).
    func retryTime(of frame: Int) -> CMTime {
        let requested = time(of: frame)
        let end = startTime + info.duration - Self.retryTolerance.seconds
        guard info.duration > 0, requested.seconds > end else { return requested }
        return CMTime(seconds: max(startTime, end), preferredTimescale: 600_000)
    }

    /// The frame a zero-tolerance request returns: the requested one, or
    /// the last frame for a request past the end (`time(of:)` clamps there).
    /// Not derived from the decoded time, whose rounding can be a frame off
    /// in files whose timestamps are not exact multiples of 1/fps.
    private func exactFrame(_ frame: Int) -> Int {
        min(frame, max(0, info.frameCount - 1))
    }

    private static func key(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 600_000, method: .roundHalfAwayFromZero).value
    }

    private func frameNumber(at time: CMTime) -> Int {
        let fps = info.fps > 0 ? info.fps : 25
        // A frame's start time; round so 6.9999 counts as frame 7.
        return max(0, Int(((time.seconds - startTime) * fps).rounded()))
    }

    /// Whether a zero-tolerance request at `time(of: frame)` came back with
    /// a later frame than the one shown at that time. A frame starting
    /// earlier is not counted: in variable-frame-rate movies (phone videos,
    /// screen recordings) a frame can last several nominal frame durations,
    /// and it is then the frame shown at that time. A quarter frame of slack
    /// allows for timestamps that are not exact multiples of 1/fps; a time
    /// AVFoundation does not report counts as the requested frame.
    func isOtherFrame(_ actual: CMTime, for frame: Int) -> Bool {
        guard actual.isValid, actual.isNumeric else { return false }
        let fps = info.fps > 0 ? info.fps : 25
        return actual.seconds > time(of: frame).seconds + 0.25 / fps
    }

    private func makeGenerator(maxWidth: Int, exact: Bool) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        // Rotated movies come out upright.
        generator.appliesPreferredTrackTransform = true
        let tolerance = exact ? CMTime.zero : Self.retryTolerance
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // Width-limited, aspect kept (0 = unconstrained), never enlarged.
        generator.maximumSize = CGSize(width: min(maxWidth, max(1, info.width)), height: 0)
        return generator
    }

    public func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        await DecodeGate.shared.acquire()
        do {
            let frame = try await decodeFrame(frameNumber, maxWidth: maxWidth)
            await DecodeGate.shared.release()
            return frame
        } catch {
            await DecodeGate.shared.release()
            throw error
        }
    }

    /// Exact decode, then the earlier-GOP read, then the ffmpeg fallback
    /// (unless `useFallback` is off: a frame-strip run tried ffmpeg already)
    /// or the retry; callers hold the gate.
    func decodeFrame(_ frameNumber: Int, maxWidth: Int, useFallback: Bool = true) async throws -> DecodedFrame {
        let requested = time(of: frameNumber)
        do {
            let (image, actual) = try await makeGenerator(maxWidth: maxWidth, exact: true).image(at: requested)
            if !isOtherFrame(actual, for: frameNumber) {
                return DecodedFrame(
                    image: image, requestedFrame: frameNumber, actualFrame: exactFrame(frameNumber),
                    retried: false)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        if let frame = try await earlierGOP(frameNumber, maxWidth: maxWidth) { return frame }
        return try await notExact(frameNumber, maxWidth: maxWidth, useFallback: useFallback)
    }

    /// Step 2 for a frame the exact request did not decode: the reader from
    /// one GOP earlier, or nil when it does not deliver the frame. Callers
    /// hold the gate.
    private func earlierGOP(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame? {
        let target = exactFrame(frameNumber)
        guard let image = try await reader.image(of: target, maxWidth: maxWidth) else { return nil }
        return DecodedFrame(
            image: image, requestedFrame: frameNumber, actualFrame: target, retried: false,
            decoder: .avFoundationReader)
    }

    /// Step 3 for a frame neither the exact request nor the earlier-GOP read
    /// decoded: ffmpeg when the fallback is on and returns the frame
    /// exactly, else the bounded-tolerance retry. Callers hold the gate, so
    /// the ffmpeg run never overlaps an AVFoundation decode.
    private func notExact(_ frameNumber: Int, maxWidth: Int, useFallback: Bool = true) async throws -> DecodedFrame {
        if useFallback, let fallback, let frame = try await fallback.frame(frameNumber, maxWidth: maxWidth),
           frame.actualFrame == exactFrame(frameNumber) {
            return frame
        }
        return try await retry(frameNumber, maxWidth: maxWidth)
    }

    /// The bounded-tolerance retry, keeping the frame actually decoded.
    private func retry(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        do {
            let (image, actual) = try await makeGenerator(maxWidth: maxWidth, exact: false)
                .image(at: retryTime(of: frameNumber))
            return DecodedFrame(
                image: image, requestedFrame: frameNumber, actualFrame: self.frameNumber(at: actual),
                retried: true)
        } catch {
            throw DecodeError("Frame \(frameNumber): \(error.localizedDescription)")
        }
    }

    public func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult> {
        AsyncStream { continuation in
            let task = Task {
                // The whole batch holds the gate: one hardware decode at a
                // time across the app (see DecodeGate).
                await DecodeGate.shared.acquire()
                // One generator for the batch keeps the decoder warm between
                // neighbouring requests; failures retry one by one afterwards.
                let generator = makeGenerator(maxWidth: maxWidth, exact: true)
                let times = frameNumbers.map { time(of: $0) }
                // Keyed by time in the request timescale (requests may repeat).
                var pending: [Int64: [Int]] = [:]
                for (i, t) in times.enumerated() { pending[Self.key(t), default: []].append(i) }
                var failed: [Int] = []

                for await result in generator.images(for: times) {
                    if Task.isCancelled { break }
                    let key = Self.key(result.requestedTime)
                    guard let index = pending[key]?.first else { continue }
                    pending[key]?.removeFirst()
                    let number = frameNumbers[index]
                    if let image = try? result.image,
                       !isOtherFrame((try? result.actualTime) ?? .invalid, for: number) {
                        let frame = DecodedFrame(
                            image: image, requestedFrame: number,
                            actualFrame: exactFrame(number),
                            retried: false)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .success(frame)))
                    } else {
                        failed.append(index)
                    }
                }
                // Results whose requested time matched no request (the
                // generator can report it in another timescale) were never
                // yielded: decode those one by one too, exact first.
                let unmatched = pending.values.flatMap { $0 }
                for index in unmatched where !Task.isCancelled {
                    let number = frameNumbers[index]
                    // `frame` already retries with tolerance on failure.
                    do {
                        let frame = try await self.decodeFrame(number, maxWidth: maxWidth)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .success(frame)))
                    } catch {
                        let message = (error as? DecodeError) ?? DecodeError(error.localizedDescription)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .failure(message)))
                    }
                }
                // After the batch's session, one by one: the earlier-GOP read
                // for every failed frame, then ffmpeg (when on) or the retry
                // for those it did not deliver.
                var notRead: [Int] = []
                for index in failed where !Task.isCancelled {
                    let number = frameNumbers[index]
                    if let frame = try? await earlierGOP(number, maxWidth: maxWidth) {
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .success(frame)))
                    } else {
                        notRead.append(index)
                    }
                }
                for index in notRead where !Task.isCancelled {
                    let number = frameNumbers[index]
                    do {
                        let frame = try await notExact(number, maxWidth: maxWidth)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .success(frame)))
                    } catch {
                        let message = (error as? DecodeError) ?? DecodeError(error.localizedDescription)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .failure(message)))
                    }
                }
                await DecodeGate.shared.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reads single frames that an exact AVAssetImageGenerator request misses
/// (open-GOP files, decision 25) with an `AVAssetReader` whose range starts
/// at the full sync sample one GOP before the frame's own and ends one frame
/// after it, decoding forward and keeping only the frame whose presentation
/// time is the target's. Found on macOS 27.2 (TASK T04b): such a read is
/// exact when it starts at an IDR frame, and fails (AVErrorDecodeFailed,
/// -11821) when it starts at a non-IDR keyframe whose leading frames lack
/// their references; it then returns nil and the backend goes on to ffmpeg
/// or the retry. Callers hold the DecodeGate, so a read never overlaps
/// another decoder session.
///
/// The sync lookup is not cached: it steps a sample cursor back through at
/// most two GOPs of the sample table, which costs little next to the read.
final class EarlierGOPReader: Sendable {
    let asset: AVURLAsset
    let info: MediaInfo
    /// Presentation time of frame 0 (track time).
    let startTime: Double
    /// The reader's buffers are not rotated, so a track with a rotating or
    /// flipping transform is left to the next step (and the frame strip's
    /// runs to single requests).
    let usable: Bool
    /// Track time minus media time of the first non-empty edit, loaded on
    /// first use.
    private let offset = Mutex<CMTime?>(nil)

    init(
        asset: AVURLAsset, info: MediaInfo, startTime: Double,
        transform: CGAffineTransform, canProvideSampleCursors: Bool
    ) {
        self.asset = asset
        self.info = info
        self.startTime = startTime
        usable = canProvideSampleCursors && transform.a == 1 && transform.b == 0 && transform.c == 0
            && transform.d == 1 && info.fps > 0 && info.width > 0 && info.height > 0
    }

    /// The image of `frame`, scaled to at most `maxWidth` pixels wide
    /// (aspect kept, never enlarged), or nil when the read does not deliver
    /// a frame whose time maps to `frame`; throws only when cancelled.
    func image(of frame: Int, maxWidth: Int) async throws -> CGImage? {
        guard usable else { return nil }
        let fps = info.fps
        let target = CMTime(seconds: startTime + Double(frame) / fps, preferredTimescale: 600_000)
        let frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
        let width = min(max(1, maxWidth), info.width)
        let height = max(1, Int((Double(width) * Double(info.height) / Double(info.width)).rounded()))
        do {
            // AVAssetTrack is not Sendable, so it is looked up per read (the
            // asset has its tracks loaded since `open`).
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let offset = try await mediaOffset(track)
            guard let start = Self.previousSyncTime(track, before: target, offset: offset) else { return nil }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: start, end: target + frameDuration)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            let provider = reader.outputProvider(for: output)
            try reader.start()
            defer { reader.cancelReading() }
            // A quarter frame of slack, as for the generator's actual time.
            let slack = 0.25 / fps
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                let pts = sample.presentationTimeStamp.seconds
                if pts > target.seconds + slack { break }
                guard abs(pts - target.seconds) <= slack,
                      Int(((pts - startTime) * fps).rounded()) == frame
                else { continue }
                let image: CGImage? = sample.withUnsafeSampleBuffer { buffer in
                    guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
                    var image: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
                    return image
                }
                return image
            }
        } catch {
            try Task.checkCancellation()
        }
        return nil
    }

    func mediaOffset(_ track: AVAssetTrack) async throws -> CMTime {
        if let known = offset.withLock({ $0 }) { return known }
        let segments = try await track.load(.segments)
        let found = segments.first { !$0.isEmpty }
            .map { $0.timeMapping.target.start - $0.timeMapping.source.start } ?? .zero
        offset.withLock { $0 = found }
        return found
    }

    /// Presentation time (track time) of the full sync sample before the
    /// one the decode of the frame at `time` starts from: a sample cursor
    /// steps back in decode order to the second full sync sample (for a
    /// leading B frame the first is the I frame shown after it). Sample
    /// cursors work in media time, hence `offset`. The first sample's time
    /// when there is no earlier sync sample; nil without a cursor.
    static func previousSyncTime(_ track: AVAssetTrack, before time: CMTime, offset: CMTime) -> CMTime? {
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time - offset) else { return nil }
        var found = 0
        while true {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                found += 1
                if found == 2 { return cursor.presentationTimeStamp + offset }
            }
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { return cursor.presentationTimeStamp + offset }
        }
    }
}

/// Fetches single frames of a movie AVFoundation has open with ffmpeg, for
/// the frames AVFoundation cannot decode exactly (open-GOP files, decision
/// 25). The ffmpeg backend is opened (probed) on first use and kept. Callers
/// hold the DecodeGate, so ffmpeg runs one at a time and never alongside an
/// AVFoundation session.
final class FFmpegFrameFallback: Sendable {
    let url: URL
    let tools: FFmpegTools
    private let opening = Mutex<Task<FFmpegBackend, any Error>?>(nil)

    init(url: URL, tools: FFmpegTools) {
        self.url = url
        self.tools = tools
    }

    /// The frame from ffmpeg, or nil when ffmpeg cannot open the file or
    /// decode the frame; throws only when cancelled.
    func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame? {
        do {
            return try await backend().frame(frameNumber, maxWidth: maxWidth)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// The frames of `range` from one ffmpeg run, each named by the frame it
    /// shows (the frame strip, §9); empty when ffmpeg cannot open the file
    /// or read them; throws only when cancelled.
    func frameRun(_ range: ClosedRange<Int>, maxWidth: Int) async throws -> [DecodedFrame] {
        do {
            return try await backend().runFrames(range, maxWidth: maxWidth)
        } catch {
            try Task.checkCancellation()
            return []
        }
    }

    private func backend() async throws -> FFmpegBackend {
        let task = opening.withLock { task in
            if let task { return task }
            let (url, tools) = (url, tools)
            let new = Task { try await FFmpegBackend.open(url, tools: tools) }
            task = new
            return new
        }
        return try await task.value
    }
}

/// AVFoundation cannot take this file; the router sends it to ffmpeg.
public struct RoutingError: Error, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}


/// Lets one AVFoundation decode run at a time across the app. Many
/// concurrent AVAssetImageGenerator sessions (a reload storm while thumbs
/// were being evicted and redrawn) twice ended in a kernel panic in the
/// hardware video decoder driver (AppleAVD, in VTDecoderXPCService) on
/// macOS 27.2; serialising keeps the driver's load flat.
actor DecodeGate {
    static let shared = DecodeGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Someone waits for the gate (a long holder, the shot scan, then lets
    /// them go first).
    var hasWaiters: Bool { !waiters.isEmpty }

    /// Decodes waiting for the gate (the scan timing log).
    var waiterCount: Int { waiters.count }

    /// For reports of a stuck decode (tests).
    var stateDescription: String { "\(busy ? "held" : "free"), \(waiters.count) waiting" }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The DecodeGate for decoder sessions outside the backends: AVPlayer
/// playback in the player view holds it while it plays, so no other
/// AVFoundation decode (thumbs, the frame strip, a scan) runs beside the
/// player's own decoder session (KNOWN_ISSUES 4). Every `acquire` needs one
/// `release`.
public enum DecoderSessionGate {
    public static func acquire() async { await DecodeGate.shared.acquire() }
    public static func release() async { await DecodeGate.shared.release() }
}
