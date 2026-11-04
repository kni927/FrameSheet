import AVFoundation
import CoreVideo
import Foundation
import Synchronization

// The shot scan of §10: one sequential pass over every frame, decoded at up
// to 720 px BGRA with the track's orientation applied; the 240 px metric
// frame is derived with vImage (docs/v3-measurements.md). AVFoundation reads
// with one `AVAssetReader` output through the macOS 27 output-provider API;
// files routed to ffmpeg (decision 10) are read from a rawvideo BGRA pipe in
// software decode.
//
// The scan holds the DecodeGate for its whole pass, so no other decoder
// session runs beside it (known issue 4). Thumb requests that arrive meanwhile
// are served in turns: every `yieldCheckFrames` frames the scan looks for
// waiters at the gate and, at most once per `minimumRunBeforeYield` (3 s),
// lets all of them go first in one pause (it queues again behind every
// request waiting then). Pausing more often made a face scan of an open-GOP
// film take minutes instead of 18 s when thumb requests kept arriving: each
// pause reopens the reader with a pre-roll from a closed GOP, and the
// waiting decodes themselves took 0.1–0.4 s each there. On the AVFoundation path it closes its reader before
// releasing the gate (an idle reader still holds a decoder session and reads
// ahead) and opens a new one at the last frame read (from a closed GOP before
// it in open-GOP files, `ClosedGOPStart`), and it runs at least a few times as
// long as that reopen took before pausing again; the ffmpeg process just
// pauses, since software decode does not use the hardware decoder.

/// What a scan reports while it runs. A stream ends after `finished`,
/// `cancelled` or `failed`.
public enum ScanEvent: Sendable {
    /// The pass began: the decoder used, the expected frame count and the
    /// frame it starts from (above 0 when a partial scan resumes).
    case started(decoder: DecoderKind, frameCount: Int, resumedAt: Int)
    case progress(framesScanned: Int, frameCount: Int)
    /// The scene list over the frames read so far (the last scene ends at
    /// the frame reached).
    case scenes([SceneSpan])
    case finished(ScanData)
    /// The partial result, also stored in the cache when the request has one.
    case cancelled(ScanData)
    /// The pass stored the request's `endFrame` and stopped there (the face
    /// scan's combined pass, T07); the partial result is stored like a
    /// cancelled one and resumes the same way.
    case stopped(ScanData)
    case failed(String)
}

/// One 720 px upright frame of the scan pass, lent to a `ScanFrameObserver`
/// for the duration of its call (faces, T07).
public struct ScanFrame: Sendable {
    public var frameNumber: Int
    public var image: BGRAFrame
}

/// Receives every frame the scan measures, in order, on the scan's task.
/// The image is valid only until the call returns. Do not decode through
/// the DecodeGate from here: the scan holds it.
public protocol ScanFrameObserver: AnyObject, Sendable {
    func scanned(_ frame: ScanFrame) async
}

/// Receives one line of text per notable scan event (pass start, pauses
/// for thumb requests, reopens, checkpoints, the end), for the app's scan
/// timing log. Called on the scan's tasks; keep it cheap.
public typealias ScanLogSink = @Sendable (String) -> Void

/// Seconds with millisecond precision, for log lines.
func logSeconds(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.3f s", Double(seconds) + Double(attoseconds) / 1e18)
}

public struct ScanRequest: Sendable {
    public var fileId: UUID
    public var url: URL
    public var method: ShotDetectionMethod
    /// For the scene lists streamed during the scan.
    public var threshold: Double
    /// The ffmpeg path, for files AVFoundation cannot read.
    public var ffmpeg: FFmpegTools?
    /// Where the result is stored; nil scans without a cache.
    public var store: ScanCacheStore?
    /// Scan again although the cache holds a complete scan.
    public var rescan: Bool
    public var observer: (any ScanFrameObserver)?
    /// The scan timing log; nil logs nothing.
    public var log: ScanLogSink?

    /// Tuning, changed by tests.
    var yieldCheckFrames = 30
    /// The scan runs at least this long between pauses for thumb requests.
    var minimumRunBeforeYield: Duration = .seconds(3)
    /// After a pause the scan runs at least this many times as long as the
    /// last reopen took (reader start and pre-roll), so pausing never costs
    /// more than about a quarter of the scan, whatever the GOP length.
    var reopenCostFactor = 4
    var checkpointInterval: Duration = .seconds(30)
    var eventInterval: Duration = .milliseconds(250)
    /// Scene lists are rebuilt over every frame read so far, so they are
    /// sent less often than the progress (the app applies one a second).
    var sceneInterval: Duration = .seconds(1)
    /// Lets waiting thumb requests go first in turns; off only to measure.
    var yieldsToWaiters = true
    /// Counters for measuring a scan (the scan probe); nil in the app.
    var diagnostics: ScanDiagnostics?
    /// Stops as if cancelled once this many frames are stored (tests); in a
    /// `frameList` pass, once this many listed frames were seen.
    var stopAfterFrames: Int?
    /// Stops with `stopped` once this frame is stored (the face scan's
    /// combined pass reads only as far as its last sampled frame).
    var endFrame: Int?
    /// A pass over these frames only (sorted, unique) for the observer,
    /// without shot metrics or the cache: the face scan's faces-only pass
    /// over frames the shot scan has already read (T07). It reads
    /// sequentially from the first listed frame, skips the frames between,
    /// and stops after the last one; after a pause it reopens at the next
    /// listed frame.
    var frameList: [Int]?

    public init(
        fileId: UUID, url: URL, method: ShotDetectionMethod, threshold: Double, ffmpeg: FFmpegTools?,
        store: ScanCacheStore?, rescan: Bool = false, observer: (any ScanFrameObserver)? = nil
    ) {
        self.fileId = fileId
        self.url = url
        self.method = method
        self.threshold = threshold
        self.ffmpeg = ffmpeg
        self.store = store
        self.rescan = rescan
        self.observer = observer
    }
}

public enum ShotScanner {
    /// Scans a movie for shots. A complete cached scan with the same method
    /// is returned without decoding unless `rescan` is set; a partial one
    /// with the same method and frame count resumes at its last frame.
    /// Cancelling the consuming task (or dropping the stream) cancels the
    /// scan, which stores its partial result.
    public static func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ request: ScanRequest, _ continuation: AsyncStream<ScanEvent>.Continuation) async {
        if request.frameList != nil {
            do {
                let source = try await ScanSource.open(request.url, ffmpeg: request.ffmpeg)
                let empty = ScanData(method: request.method, expectedFrameCount: source.info.frameCount)
                await ScanSession(request: request, source: source, data: empty, continuation: continuation).run()
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
            return
        }
        let cached = (try? request.store?.load(request.fileId)) ?? nil
        if let cached, cached.complete, cached.method == request.method, !request.rescan {
            continuation.yield(.scenes(SceneList.scenes(from: cached, threshold: request.threshold)))
            continuation.yield(.finished(cached))
            return
        }
        let source: ScanSource
        do {
            source = try await ScanSource.open(request.url, ffmpeg: request.ffmpeg)
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            return
        }
        var start = ScanData(method: request.method, expectedFrameCount: source.info.frameCount)
        if let cached, !cached.complete, !request.rescan, cached.method == request.method,
           cached.expectedFrameCount == source.info.frameCount {
            start = cached
        }
        let session = ScanSession(request: request, source: source, data: start, continuation: continuation)
        await session.run()
    }
}

/// Where a reader that has to deliver the frames from a time on can start,
/// for open-GOP files (known issue 5): a reader whose range starts in a GOP
/// with leading frames (frames after the keyframe in decode order but shown
/// before it) can stop with -11821, while one starting at a keyframe without
/// leading frames decodes on through the following open GOPs, as a read from
/// the start does. In a closed-GOP file this is the keyframe AVFoundation
/// would start from anyway.
enum ClosedGOPStart {
    /// How far back a start may lie; a scan reading more than this again
    /// would cost more than the thumb requests it pauses for.
    static let maximumPreRoll = CMTime(seconds: 30, preferredTimescale: 600)
    /// Samples a lookup steps through at most.
    static let maximumSteps = 100_000
    /// Samples after a keyframe searched for leading frames.
    static let leadingFrameWindow = 64

    /// Presentation time (track time) of the latest full sync sample at or
    /// before `time` without leading frames, not earlier than `notBefore`;
    /// nil without sample cursors or when there is none in that range.
    static func time(_ track: AVAssetTrack, atOrBefore time: CMTime, notBefore: CMTime) async -> CMTime? {
        guard let segments = try? await track.load(.segments) else { return nil }
        // Sample cursors work in media time.
        let offset = segments.first { !$0.isEmpty }
            .map { $0.timeMapping.target.start - $0.timeMapping.source.start } ?? .zero
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time - offset) else { return nil }
        for _ in 0..<maximumSteps {
            let pts = cursor.presentationTimeStamp + offset
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                if pts < notBefore { return nil }
                if pts <= time, !hasLeadingFrames(cursor) { return pts }
            }
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { return nil }
        }
        return nil
    }

    /// Whether a sample after this keyframe in decode order, before the
    /// next keyframe, is shown before it.
    private static func hasLeadingFrames(_ keyframe: AVSampleCursor) -> Bool {
        guard let probe = keyframe.copy() as? AVSampleCursor else { return true }
        let pts = keyframe.presentationTimeStamp
        for _ in 0..<leadingFrameWindow {
            if probe.stepInDecodeOrder(byCount: 1) == 0 { return false }
            if probe.currentSampleSyncInfo.sampleIsFullSync.boolValue { return false }
            if probe.presentationTimeStamp < pts { return true }
        }
        return false
    }
}

/// What a scan spent on sharing the decoder: pauses for thumb requests,
/// reader reopens and the frames decoded only to reach the resume point.
final class ScanDiagnostics: Sendable {
    struct Values: Sendable {
        /// Readers opened, the first one included.
        var readers = 0
        /// Times the scan let waiting decodes go first.
        var pauses = 0
        /// Time between releasing the gate and getting it back.
        var gateWait: Duration = .zero
        /// From creating a reader after a pause to its first wanted frame.
        var reopenTime: Duration = .zero
        /// From creating the first reader to its first wanted frame.
        var startTime: Duration = .zero
        /// Mid-file readers that failed and were replaced by a read from 0.
        var fallbacksToStart = 0
        /// Frames decoded before the resume point (pre-roll), thrown away.
        var discardedFrames = 0
    }

    let values = Mutex(Values())

    func update(_ change: (inout Values) -> Void) { values.withLock { change(&$0) } }
    var snapshot: Values { values.withLock { $0 } }
}

/// Carries a sample's image buffer out of `withUnsafeSampleBuffer`. The
/// reference keeps the buffer alive (its pool does not reuse a retained
/// buffer), and it stays on the reading task.
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer

    init?(_ sample: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        self.buffer = buffer
    }
}

// MARK: - Source

/// The opened movie, routed as the thumbnails are (decision 10).
struct ScanSource: Sendable {
    enum Kind: Sendable {
        case avFoundation(asset: AVURLAsset, startTime: Double, orientation: FrameOrientation)
        case ffmpeg(tools: FFmpegTools)
    }

    var url: URL
    var info: MediaInfo
    var kind: Kind

    var decoder: DecoderKind {
        if case .ffmpeg = kind { return .ffmpeg }
        return .avFoundation
    }

    var fps: Double { info.fps > 0 ? info.fps : 25 }

    static func open(_ url: URL, ffmpeg: FFmpegTools?) async throws -> ScanSource {
        do {
            let backend = try await AVFoundationBackend.open(url)
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw DecodeError("AVFoundation found no video track")
            }
            let (transform, timeRange) = try await track.load(.preferredTransform, .timeRange)
            let start = timeRange.start.seconds.isFinite ? timeRange.start.seconds : 0
            return ScanSource(
                url: url, info: backend.info,
                kind: .avFoundation(asset: asset, startTime: start, orientation: FrameOrientation(transform)))
        } catch let routing as RoutingError {
            guard let ffmpeg else {
                throw DecodeError("\(routing.reason), and ffmpeg was not found. Install it, for example with `brew install ffmpeg`, or choose it in the settings.")
            }
            let backend = try await FFmpegBackend.open(url, tools: ffmpeg)
            return ScanSource(url: url, info: backend.info, kind: .ffmpeg(tools: ffmpeg))
        }
    }

    /// Upright size of the decoded frames (long side up to 720).
    var uprightSize: (width: Int, height: Int) {
        ScanGeometry.fit(width: info.width, height: info.height, maxSide: ScanGeometry.decodeSide)
    }

    var orientation: FrameOrientation {
        if case .avFoundation(_, _, let orientation) = kind { return orientation }
        // ffmpeg rotates on decode.
        return .up
    }
}

// MARK: - Session

private enum PassOutcome {
    case finished
    /// Stopped to let thumb requests use the decoder.
    case yielded
}

/// Thrown when a pass has stored its `endFrame`.
private struct ReachedEndFrame: Error {}

/// The state of one scan, confined to its task.
private final class ScanSession {
    let request: ScanRequest
    let source: ScanSource
    var data: ScanData
    let continuation: AsyncStream<ScanEvent>.Continuation
    let calculator: ShotMetricCalculator
    let converter: ScanFrameConverter
    let clock = ContinuousClock()
    /// The frame re-read to restore the previous frame's values.
    var seedFrame: Int?
    var lastEvent: ContinuousClock.Instant
    var lastScenes: ContinuousClock.Instant
    var lastCheckpoint: ContinuousClock.Instant
    var resumedAt: ContinuousClock.Instant
    /// What the last reopen after a pause took until its first wanted frame.
    var lastReopenCost: Duration = .zero
    var yieldsAllowed = true
    /// A `frameList` pass: the listed frames and the next one to read.
    let frameList: [Int]?
    var nextListed = 0
    /// For the log: pauses, their total time and the frames thrown away.
    var pauses = 0
    var pausedTime: Duration = .zero
    var readers = 0
    var discarded = 0
    let started = ContinuousClock.now

    init(request: ScanRequest, source: ScanSource, data: ScanData, continuation: AsyncStream<ScanEvent>.Continuation) {
        self.request = request
        self.source = source
        self.data = data
        self.continuation = continuation
        frameList = request.frameList
        calculator = ShotMetricCalculator(method: request.method)
        let size = source.uprightSize
        converter = ScanFrameConverter(uprightWidth: size.width, uprightHeight: size.height, orientation: source.orientation)
        let now = ContinuousClock.now
        lastEvent = now
        lastScenes = now
        lastCheckpoint = now
        resumedAt = now
        if frameList == nil { self.data.reserve(source.info.frameCount + 16) }
    }

    var expected: Int { max(source.info.frameCount, data.frameCount) }

    /// A `frameList` pass has seen all its frames.
    var listDone: Bool { frameList.map { nextListed >= $0.count } ?? false }

    /// The pass ended short of what it should read: the movie's frames, or
    /// the listed frames.
    var readsShort: Bool { frameList != nil ? !listDone : data.frameCount < source.info.frameCount }

    /// Progress for the events: frames stored, or listed frames seen.
    var progressEvent: ScanEvent {
        if let frameList { return .progress(framesScanned: nextListed, frameCount: frameList.count) }
        return .progress(framesScanned: data.frameCount, frameCount: expected)
    }

    func run() async {
        let kind = frameList != nil ? "faces-only pass over \(frameList!.count) listed frames"
            : request.observer != nil ? "combined pass" : "shot pass"
        let end = request.endFrame.map { ", to frame \($0)" } ?? ""
        let from = frameList?.first ?? data.frameCount
        request.log?("scan: \(kind), decoder \(source.decoder.rawValue), \(source.info.frameCount) frames, "
            + "\(source.info.width)x\(source.info.height) at \(String(format: "%.3f", source.fps)) fps, from frame \(from)\(end)")
        let gateAsked = clock.now
        await DecodeGate.shared.acquire()
        if clock.now - gateAsked > .milliseconds(5) {
            request.log?("scan: waited \(logSeconds(clock.now - gateAsked)) for the decode gate before starting")
        }
        if let frameList {
            continuation.yield(.started(decoder: source.decoder, frameCount: frameList.count, resumedAt: 0))
        } else {
            continuation.yield(.started(decoder: source.decoder, frameCount: source.info.frameCount, resumedAt: data.frameCount))
        }
        do {
            switch source.kind {
            case .avFoundation(let asset, let startTime, _):
                try await runAVFoundation(asset: asset, startTime: startTime)
            case .ffmpeg(let tools):
                try await runFFmpeg(tools: tools)
            }
            await DecodeGate.shared.release()
            logEnd("finished")
            if frameList != nil {
                continuation.yield(progressEvent)
                continuation.yield(.finished(data))
                return
            }
            data.complete = true
            try? request.store?.save(data, for: request.fileId)
            continuation.yield(.progress(framesScanned: data.frameCount, frameCount: data.frameCount))
            continuation.yield(.scenes(SceneList.scenes(from: data, threshold: request.threshold)))
            continuation.yield(.finished(data))
        } catch {
            await DecodeGate.shared.release()
            if frameList == nil { try? request.store?.save(data, for: request.fileId) }
            logEnd(error is ReachedEndFrame ? "stopped at its end frame"
                : error is CancellationError || Task.isCancelled ? "cancelled" : "failed: \(error.localizedDescription)")
            if error is ReachedEndFrame {
                continuation.yield(.progress(framesScanned: data.frameCount, frameCount: expected))
                continuation.yield(.stopped(data))
            } else if error is CancellationError || Task.isCancelled {
                continuation.yield(.cancelled(data))
            } else {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
    }

    private func logEnd(_ how: String) {
        guard let log = request.log else { return }
        let read = frameList != nil ? "\(nextListed) of \(frameList!.count) listed frames seen" : "\(data.frameCount) frames stored"
        log("scan: pass \(how) after \(logSeconds(clock.now - started)): \(read), \(readers) reader(s), "
            + "\(pauses) pause(s) for thumb requests (\(logSeconds(pausedTime)) paused), \(discarded) frames decoded and skipped")
    }

    /// Sets up the seed for a pass that starts at the last stored frame.
    func prepareSeed() -> Int {
        if let frameList {
            seedFrame = nil
            return listDone ? 0 : frameList[nextListed]
        }
        guard data.frameCount > 0 else { seedFrame = nil; return 0 }
        seedFrame = data.frameCount - 1
        return data.frameCount - 1
    }

    /// Whether a decoded frame is needed (pre-roll and repeated frame
    /// numbers are skipped).
    func wants(_ frame: Int) -> Bool {
        if let frameList { return !listDone && frame >= frameList[nextListed] }
        if let seedFrame { return frame >= seedFrame }
        return frame >= data.frameCount
    }

    /// Measures one decoded frame (already known to be wanted).
    func process(_ frame: Int, decoded: BGRAFrame) async throws {
        if let frameList {
            // Listed frames the decoder skipped (frame number gaps) are
            // passed over.
            while nextListed < frameList.count, frameList[nextListed] < frame { nextListed += 1 }
            guard nextListed < frameList.count, frameList[nextListed] == frame else { return }
            nextListed += 1
            if let observer = request.observer {
                await observer.scanned(ScanFrame(frameNumber: frame, image: converter.upright(decoded)))
            }
            if let stop = request.stopAfterFrames, nextListed >= stop { throw CancellationError() }
            try Task.checkCancellation()
            return
        }
        let upright = converter.upright(decoded)
        let metricFrame = converter.metricFrame(upright)
        if seedFrame != nil {
            seedFrame = nil
            calculator.seed(metricFrame)
            // A missing seed frame: the frame after it is compared with
            // itself (difference 0).
            if frame < data.frameCount { return }
        }
        // A gap in the frame numbers (variable frame rate, dropped frames)
        // repeats the previous frame; an implausible jump is not filled.
        if frame > data.frameCount, frame - data.frameCount < 1000 {
            while data.frameCount < frame { data.appendRepeatingLast() }
        }
        let (difference, color) = calculator.measure(metricFrame)
        let number = data.frameCount
        data.append(difference: difference, color: color)
        if let observer = request.observer {
            await observer.scanned(ScanFrame(frameNumber: number, image: upright))
        }
        if let stop = request.stopAfterFrames, data.frameCount >= stop { throw CancellationError() }
        if let end = request.endFrame, data.frameCount > end { throw ReachedEndFrame() }
        try Task.checkCancellation()
    }

    /// Events and checkpoints; returns whether to yield the gate now.
    func tick() async -> Bool {
        let now = clock.now
        if now - lastEvent >= request.eventInterval {
            lastEvent = now
            continuation.yield(progressEvent)
        }
        if frameList == nil, now - lastScenes >= request.sceneInterval {
            lastScenes = now
            continuation.yield(.scenes(SceneList.scenes(from: data, threshold: request.threshold)))
        }
        if frameList == nil, now - lastCheckpoint >= request.checkpointInterval {
            lastCheckpoint = now
            if let store = request.store {
                try? store.save(data, for: request.fileId)
                request.log?("scan: shot cache checkpoint, \(data.frameCount) frames, \(logSeconds(clock.now - now))")
            }
        }
        let run = max(request.minimumRunBeforeYield, lastReopenCost * request.reopenCostFactor)
        guard request.yieldsToWaiters, yieldsAllowed, now - resumedAt >= run else { return false }
        return await DecodeGate.shared.hasWaiters
    }

    /// Lets the waiting decodes run, then takes the gate back.
    func yieldGate() async {
        let waiting = request.log != nil ? await DecodeGate.shared.waiterCount : 0
        let released = clock.now
        await DecodeGate.shared.release()
        await DecodeGate.shared.acquire()
        resumedAt = clock.now
        pauses += 1
        pausedTime += resumedAt - released
        request.diagnostics?.update {
            $0.pauses += 1
            $0.gateWait += resumedAt - released
        }
        let at = frameList != nil ? "listed frame \(nextListed)" : "frame \(data.frameCount)"
        request.log?("scan: pause \(pauses) at \(at): \(waiting) waiting request(s) served, "
            + "paused \(logSeconds(resumedAt - released))")
    }

    // MARK: AVFoundation

    func runAVFoundation(asset: AVURLAsset, startTime: Double) async throws {
        var fromStart = false
        while true {
            let seed = prepareSeed()
            let first = fromStart ? 0 : seed
            let outcome: PassOutcome
            do {
                outcome = try await readAVFoundation(asset: asset, startTime: startTime, from: first)
            } catch where first > 0 && !(error is CancellationError) && !(error is ReachedEndFrame) && !Task.isCancelled {
                // A reader that starts inside the movie can fail on open-GOP
                // files (known issue 5); read from the start instead, without
                // further pauses.
                request.diagnostics?.update { $0.fallbacksToStart += 1 }
                request.log?("scan: reader at frame \(first) failed (\(error.localizedDescription)); reading from the start")
                fromStart = true
                yieldsAllowed = false
                continue
            }
            switch outcome {
            case .finished: return
            case .yielded: await yieldGate()
            }
        }
    }

    private func readAVFoundation(asset: AVURLAsset, startTime: Double, from first: Int) async throws -> PassOutcome {
        let fps = source.fps
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DecodeError("AVFoundation found no video track")
        }
        let opened = clock.now
        let reader = try AVAssetReader(asset: asset)
        let diagnostics = request.diagnostics
        diagnostics?.update { $0.readers += 1 }
        readers += 1
        var skipped = 0
        var reachedResumePoint = false
        if first > 0 {
            let resume = CMTime(seconds: startTime + (Double(first) - 0.25) / fps, preferredTimescale: 600_000)
            // In an open-GOP file a reader starting at the keyframe before
            // `first` can fail; start at a closed GOP shortly before instead,
            // and decode up to `first` (the frames before are skipped).
            var start = resume
            if let closed = await ClosedGOPStart.time(
                track, atOrBefore: resume, notBefore: resume - ClosedGOPStart.maximumPreRoll),
               closed < resume {
                start = closed
            }
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: converter.decodedWidth,
            kCVPixelBufferHeightKey as String: converter.decodedHeight,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { reader.cancelReading() }
        var count = 0
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite else { continue }
            let frame = max(0, Int(((pts - startTime) * fps).rounded()))
            guard wants(frame) else {
                diagnostics?.update { $0.discardedFrames += 1 }
                discarded += 1
                skipped += 1
                // A `frameList` pass skips most frames: it still lets
                // waiting thumb requests go first in turns.
                if frameList != nil {
                    count += 1
                    if count % request.yieldCheckFrames == 0, await tick() { return .yielded }
                }
                continue
            }
            if !reachedResumePoint {
                reachedResumePoint = true
                let elapsed = clock.now - opened
                if first > 0 { lastReopenCost = elapsed }
                diagnostics?.update {
                    if $0.readers == 1 { $0.startTime += elapsed } else { $0.reopenTime += elapsed }
                }
                request.log?("scan: reader \(readers) \(first > 0 ? "reopened at frame \(first)" : "opened"): "
                    + "first wanted frame after \(logSeconds(elapsed)), \(skipped) frames decoded before it")
            }
            guard let buffer = sample.withUnsafeSampleBuffer({ PixelBufferBox($0) })?.buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            do {
                guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    continue
                }
                let decoded = BGRAFrame(
                    base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
                try await process(frame, decoded: decoded)
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            } catch {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                throw error
            }
            if listDone { return .finished }
            count += 1
            if count % request.yieldCheckFrames == 0, await tick() { return .yielded }
        }
        // A reader that fails may end its samples without throwing; short of
        // the expected frames, that is a failure (and mid-file, the cue for
        // the read from the start), not the end of the movie.
        if reader.status == .failed, readsShort {
            throw reader.error ?? DecodeError("AVFoundation stopped reading at frame \(data.frameCount)")
        }
        return .finished
    }

    // MARK: ffmpeg

    func runFFmpeg(tools: FFmpegTools) async throws {
        let fps = source.fps
        let first = prepareSeed()
        let (width, height) = (converter.uprightWidth, converter.uprightHeight)
        var arguments = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]
        if first > 0 {
            // Input seeking decodes from the keyframe before and drops the
            // frames before this time; half a frame early lands on `first`.
            arguments += ["-ss", String(format: "%.6f", (Double(first) - 0.5) / fps)]
        }
        arguments += [
            "-i", source.url.nfcPath, "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", "scale=\(width):\(height)", "-pix_fmt", "bgra", "-f", "rawvideo", "-",
        ]
        let pipe = RawVideoPipe(executable: tools.ffmpeg, arguments: arguments)
        try pipe.start()
        readers += 1
        request.log?("scan: ffmpeg started at frame \(first), \(width)x\(height) BGRA")
        let frameBytes = width * 4 * height
        let packed = UnsafeMutableRawPointer.allocate(byteCount: frameBytes, alignment: 64)
        defer { packed.deallocate() }
        let decoded = BGRAFrame(base: packed, width: width, height: height, bytesPerRow: width * 4)
        var frame = first
        var count = 0
        do {
            while try await pipe.readFrame(into: packed, count: frameBytes) {
                if wants(frame) { try await process(frame, decoded: decoded) }
                if listDone {
                    // The listed frames are read: the rest is not needed.
                    pipe.terminate()
                    _ = await pipe.finish()
                    return
                }
                frame += 1
                count += 1
                // ffmpeg decodes in software, so its process may keep
                // running (paused by the full pipe) while others decode.
                if count % request.yieldCheckFrames == 0, await tick() { await yieldGate() }
            }
        } catch {
            pipe.terminate()
            _ = await pipe.finish()
            throw error
        }
        let (status, errors) = await pipe.finish()
        if status != 0 {
            throw DecodeError("ffmpeg could not read the file: \(errors.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
