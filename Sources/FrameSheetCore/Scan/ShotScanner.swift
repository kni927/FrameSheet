import AVFoundation
import CoreVideo
import Foundation

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
// waiters at the gate and, at most once per `minimumRunBeforeYield`, lets
// them go first. On the AVFoundation path it closes its reader before
// releasing the gate (an idle reader still holds a decoder session and reads
// ahead) and opens a new one at the last frame read; the ffmpeg process just
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

    /// Tuning, changed by tests.
    var yieldCheckFrames = 30
    var minimumRunBeforeYield: Duration = .seconds(1)
    var checkpointInterval: Duration = .seconds(30)
    var eventInterval: Duration = .milliseconds(250)
    /// Stops as if cancelled once this many frames are stored (tests).
    var stopAfterFrames: Int?

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
    var lastCheckpoint: ContinuousClock.Instant
    var resumedAt: ContinuousClock.Instant
    var yieldsAllowed = true

    init(request: ScanRequest, source: ScanSource, data: ScanData, continuation: AsyncStream<ScanEvent>.Continuation) {
        self.request = request
        self.source = source
        self.data = data
        self.continuation = continuation
        calculator = ShotMetricCalculator(method: request.method)
        let size = source.uprightSize
        converter = ScanFrameConverter(uprightWidth: size.width, uprightHeight: size.height, orientation: source.orientation)
        let now = ContinuousClock.now
        lastEvent = now
        lastCheckpoint = now
        resumedAt = now
        self.data.reserve(source.info.frameCount + 16)
    }

    var expected: Int { max(source.info.frameCount, data.frameCount) }

    func run() async {
        await DecodeGate.shared.acquire()
        continuation.yield(.started(decoder: source.decoder, frameCount: source.info.frameCount, resumedAt: data.frameCount))
        do {
            switch source.kind {
            case .avFoundation(let asset, let startTime, _):
                try await runAVFoundation(asset: asset, startTime: startTime)
            case .ffmpeg(let tools):
                try await runFFmpeg(tools: tools)
            }
            await DecodeGate.shared.release()
            data.complete = true
            try? request.store?.save(data, for: request.fileId)
            continuation.yield(.progress(framesScanned: data.frameCount, frameCount: data.frameCount))
            continuation.yield(.scenes(SceneList.scenes(from: data, threshold: request.threshold)))
            continuation.yield(.finished(data))
        } catch {
            await DecodeGate.shared.release()
            try? request.store?.save(data, for: request.fileId)
            if error is CancellationError || Task.isCancelled {
                continuation.yield(.cancelled(data))
            } else {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
    }

    /// Sets up the seed for a pass that starts at the last stored frame.
    func prepareSeed() -> Int {
        guard data.frameCount > 0 else { seedFrame = nil; return 0 }
        seedFrame = data.frameCount - 1
        return data.frameCount - 1
    }

    /// Whether a decoded frame is needed (pre-roll and repeated frame
    /// numbers are skipped).
    func wants(_ frame: Int) -> Bool {
        if let seedFrame { return frame >= seedFrame }
        return frame >= data.frameCount
    }

    /// Measures one decoded frame (already known to be wanted).
    func process(_ frame: Int, decoded: BGRAFrame) async throws {
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
        try Task.checkCancellation()
    }

    /// Events and checkpoints; returns whether to yield the gate now.
    func tick() async -> Bool {
        let now = clock.now
        if now - lastEvent >= request.eventInterval {
            lastEvent = now
            continuation.yield(.progress(framesScanned: data.frameCount, frameCount: expected))
            continuation.yield(.scenes(SceneList.scenes(from: data, threshold: request.threshold)))
        }
        if now - lastCheckpoint >= request.checkpointInterval {
            lastCheckpoint = now
            try? request.store?.save(data, for: request.fileId)
        }
        guard yieldsAllowed, now - resumedAt >= request.minimumRunBeforeYield else { return false }
        return await DecodeGate.shared.hasWaiters
    }

    /// Lets the waiting decodes run, then takes the gate back.
    func yieldGate() async {
        await DecodeGate.shared.release()
        await DecodeGate.shared.acquire()
        resumedAt = clock.now
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
            } catch where first > 0 && !(error is CancellationError) && !Task.isCancelled {
                // A reader that starts inside the movie can fail on open-GOP
                // files (known issue 5); read from the start instead, without
                // further pauses.
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
        let reader = try AVAssetReader(asset: asset)
        if first > 0 {
            let time = startTime + (Double(first) - 0.25) / fps
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: time, preferredTimescale: 600_000), duration: .positiveInfinity)
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
            guard wants(frame) else { continue }
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
            count += 1
            if count % request.yieldCheckFrames == 0, await tick() { return .yielded }
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
        let frameBytes = width * 4 * height
        let packed = UnsafeMutableRawPointer.allocate(byteCount: frameBytes, alignment: 64)
        defer { packed.deallocate() }
        let decoded = BGRAFrame(base: packed, width: width, height: height, bytesPerRow: width * 4)
        var frame = first
        var count = 0
        do {
            while try await pipe.readFrame(into: packed, count: frameBytes) {
                if wants(frame) { try await process(frame, decoded: decoded) }
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
