import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import Synchronization

// The face scan (§10): Vision on the frames of a scope, read in the scan
// pass. Frames the shot scan has already read get a faces-only pass over
// them; the rest are read by the shot scan itself (the combined pass), which
// then stops after the last sampled frame and resumes later like a cancelled
// one. The scopes follow MoviePrint's `onAddFaceSheetClick`
// (app/containers/App.js, MIT, docs/licenses/MoviePrint-LICENSE).
//
// Vision (about 16 ms a frame) runs off the reader's loop: the pass copies
// each sampled frame into a pooled buffer and hands it to one analysis
// worker through a short queue (`FaceCollector.backlog`). When the queue is
// full the pass waits, so every sampled frame is analyzed; results are
// recorded in frame order, and a scan ends once the queue has drained.
//
// A frame found to have faces also gives its thumbnail (`FaceScanThumbnails`)
// from the scan's own 720 px frame, so the new faces sheet shows without
// decoding its frames again: on open-GOP films most of them miss the exact
// image request and took the earlier-GOP read or ffmpeg (0.1–0.4 s each,
// minutes for a sheet of 400).

/// Which frames a face scan analyzes (Add faces sheet, §4).
public enum FaceScanScope: String, CaseIterable, Sendable {
    /// MoviePrint "Scan every 10th frame": scan resolution 0.1.
    case everyTenth
    /// "Scan every 100th frame": 0.01.
    case everyHundredth
    /// "Scan these thumbs": the shown thumbs' own frames.
    case thumbs

    public var label: String {
        switch self {
        case .everyTenth: "Every 10th frame"
        case .everyHundredth: "Every 100th frame"
        case .thumbs: "These thumbs"
        }
    }

    public var help: String {
        switch self {
        case .everyTenth: "Scan every 10th frame from the first to the last thumb"
        case .everyHundredth: "Scan every 100th frame from the first to the last thumb"
        case .thumbs: "Scan the frames of the shown thumbs"
        }
    }

    /// Frames analyzed per frame of the range.
    public var resolution: Double? {
        switch self {
        case .everyTenth: 0.1
        case .everyHundredth: 0.01
        case .thumbs: nil
        }
    }

    /// Every 10th frame, or every 100th on the ffmpeg path, where software
    /// decoding and detection compete for the CPU (docs/v3-measurements.md).
    public static func defaultScope(for decoder: DecoderKind) -> FaceScanScope {
        decoder == .ffmpeg ? .everyHundredth : .everyTenth
    }

    /// The frames to analyze, sorted and unique: for the sampled scopes
    /// round(max(1, range × resolution)) frames spread evenly from the
    /// lowest to the highest thumb (MoviePrint `scanBetweenInAndOut` with
    /// `getIntervalArray`); for `thumbs` the thumbs' frames.
    public func frames(thumbFrames: [Int], frameCount: Int) -> [Int] {
        let frames = thumbFrames.filter { $0 >= 0 && $0 < max(1, frameCount) }
        guard let low = frames.min(), let high = frames.max() else { return [] }
        guard let resolution else { return Array(Set(frames)).sorted() }
        let amount = Int(IntervalFrames.jsRound(max(1, Double(high - low) * resolution)))
        // A single frame: `getIntervalArray` would give frame 0.
        guard amount > 1 else { return [low] }
        let list = IntervalFrames.frameNumbers(amount: amount, start: low, stop: high, maxValue: frameCount)
        return Array(Set(list)).sorted()
    }
}

/// Thumbnails of the frames found to have faces, made from the scan's own
/// upright frames (exact: each is the frame scanned), for the window's cache.
public struct FaceScanThumbnails: Sendable {
    /// The width for the n-th frame with faces in the scope (1-based,
    /// frames found by earlier scans counted), so they are made at the size
    /// a faces sheet of that many thumbs draws them; never wider than the
    /// scan frame.
    public var width: @Sendable (Int) -> Int
    /// Receives a frame's thumbnail and the width it was made for, on the
    /// analysis worker.
    public var deliver: @Sendable (_ frame: Int, _ image: CGImage, _ width: Int) -> Void

    public init(
        width: @escaping @Sendable (Int) -> Int,
        deliver: @escaping @Sendable (_ frame: Int, _ image: CGImage, _ width: Int) -> Void
    ) {
        self.width = width
        self.deliver = deliver
    }
}

public struct FaceScanRequest: Sendable {
    public var fileId: UUID
    public var url: URL
    /// Sorted, unique; frames already in the cache are not read again.
    public var frames: [Int]
    public var thresholds: FaceThresholds
    public var analyzer: any FaceAnalyzer
    public var ffmpeg: FFmpegTools?
    /// Each frame decoded on its own through this backend (decision 25's
    /// steps, one at a time) instead of a sequential pass: the "these
    /// thumbs" scope, whose frames lie far apart.
    public var singleFrames: (any DecodeBackend)?
    public var faceStore: FaceCacheStore?
    /// The shot scan cache: what the combined pass resumes and stores.
    public var scanStore: ScanCacheStore?
    /// Shot scan settings of the combined pass.
    public var method: ShotDetectionMethod
    public var shotThreshold: Double
    /// Thumbnails of the frames with faces; nil makes none.
    public var thumbnails: FaceScanThumbnails?

    /// Tuning, changed by tests and the probe.
    var checkpointInterval: Duration = .seconds(30)
    /// Stops the pass as if cancelled after this many frames (tests; see
    /// `ScanRequest.stopAfterFrames`).
    var stopAfterFrames: Int?
    var yieldCheckFrames = 30
    /// Pauses for thumb requests (tests, the probe).
    var minimumRunBeforeYield: Duration?
    /// Counters of the passes' decoder sharing (the probe).
    var diagnostics: ScanDiagnostics?

    public init(
        fileId: UUID, url: URL, frames: [Int], thresholds: FaceThresholds, analyzer: any FaceAnalyzer,
        ffmpeg: FFmpegTools?, singleFrames: (any DecodeBackend)? = nil, faceStore: FaceCacheStore?,
        scanStore: ScanCacheStore?, method: ShotDetectionMethod, shotThreshold: Double,
        thumbnails: FaceScanThumbnails? = nil
    ) {
        self.fileId = fileId
        self.url = url
        self.frames = frames
        self.thresholds = thresholds
        self.analyzer = analyzer
        self.ffmpeg = ffmpeg
        self.singleFrames = singleFrames
        self.faceStore = faceStore
        self.scanStore = scanStore
        self.method = method
        self.shotThreshold = shotThreshold
        self.thumbnails = thumbnails
    }
}

extension FaceScanRequest {
    /// Copies the tuning onto a pass.
    func tune(_ pass: inout ScanRequest) {
        pass.stopAfterFrames = stopAfterFrames
        pass.yieldCheckFrames = yieldCheckFrames
        if let minimumRunBeforeYield { pass.minimumRunBeforeYield = minimumRunBeforeYield }
        pass.diagnostics = diagnostics
    }
}

public enum FaceScanEvent: Sendable {
    /// Frames to analyze in this scan (those not in the cache), and whether
    /// the shot scan reads some of them (the combined pass).
    case started(missing: Int, combined: Bool)
    /// 0–1 over the passes of this scan.
    case progress(Double)
    /// The faces of every scanned movie frame so far (also stored), and the
    /// shot scan the combined pass left (complete, or stopped part way).
    case finished(FaceData, shotScan: ScanData?)
    case cancelled(FaceData, shotScan: ScanData?)
    case failed(String, FaceData)
}

public enum FaceScanner {
    /// Scans the request's frames for faces. Cancelling the consuming task
    /// cancels the scan, which stores what it found (and the shot scan its
    /// partial result).
    public static func scan(_ request: FaceScanRequest) -> AsyncStream<FaceScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ request: FaceScanRequest, _ continuation: AsyncStream<FaceScanEvent>.Continuation) async {
        var start = FaceData(thresholds: request.thresholds)
        if let stored = (try? request.faceStore?.load(request.fileId)) ?? nil, stored.thresholds == request.thresholds {
            start = stored
        }
        let missing = start.missing(request.frames)
        // Frames with faces an earlier scan found in this scope.
        let found = request.frames.reduce(0) { $0 + ((start.frame($1)?.faceCount ?? 0) > 0 ? 1 : 0) }
        let collector = FaceCollector(
            data: start, wanted: Set(missing), analyzer: request.analyzer, thumbnails: request.thumbnails,
            facesFramesBefore: found)
        let saver = Saver(request: request, collector: collector)
        guard !missing.isEmpty else {
            continuation.yield(.started(missing: 0, combined: false))
            continuation.yield(.finished(start, shotScan: nil))
            return
        }
        if let backend = request.singleFrames {
            continuation.yield(.started(missing: missing.count, combined: false))
            await runSingleFrames(missing, backend: backend, collector: collector, continuation, saver: saver)
            return
        }
        let source: ScanSource
        do {
            source = try await ScanSource.open(request.url, ffmpeg: request.ffmpeg)
        } catch {
            continuation.yield(.failed(error.localizedDescription, start))
            return
        }
        let (outcome, shotScan) = await collector.analyzing {
            await runPasses(request, source: source, missing: missing, collector: collector, continuation, saver: saver)
        }
        let data = saver.save()
        switch outcome {
        case .finished: continuation.yield(.finished(data, shotScan: shotScan))
        case .cancelled: continuation.yield(.cancelled(data, shotScan: shotScan))
        case .failed(let message): continuation.yield(.failed(message, data))
        }
    }

    /// The faces-only and combined passes, feeding the collector's queue.
    private static func runPasses(
        _ request: FaceScanRequest, source: ScanSource, missing: [Int], collector: FaceCollector,
        _ continuation: AsyncStream<FaceScanEvent>.Continuation, saver: Saver
    ) async -> (Outcome, ScanData?) {
        // Which frames the shot scan has read: a complete scan, or the
        // partial one it would resume (same method and frame count).
        let cached = (try? request.scanStore?.load(request.fileId)) ?? nil
        var covered = 0
        if let cached {
            if cached.complete {
                covered = Int.max
            } else if cached.method == request.method, cached.expectedFrameCount == source.info.frameCount {
                covered = cached.frameCount
            }
        }
        let facesOnly = missing.filter { $0 < covered }
        let combined = missing.filter { $0 >= covered }
        continuation.yield(.started(missing: missing.count, combined: !combined.isEmpty))
        // Progress weights: the frames each pass decodes.
        let facesOnlyWork = facesOnly.isEmpty ? 0 : Double(facesOnly.last! - facesOnly.first! + 1)
        let combinedWork = combined.isEmpty ? 0 : Double(combined.last! + 1 - covered)
        let totalWork = max(1, facesOnlyWork + combinedWork)

        var shotScan: ScanData?
        var outcome: Outcome = .finished
        if !facesOnly.isEmpty {
            var pass = ScanRequest(
                fileId: request.fileId, url: request.url, method: request.method, threshold: request.shotThreshold,
                ffmpeg: request.ffmpeg, store: nil, observer: collector)
            pass.frameList = facesOnly
            request.tune(&pass)
            outcome = await consume(ShotScanner.scan(pass), saver: saver) { scanned, count in
                continuation.yield(.progress(facesOnlyWork * Double(scanned) / Double(max(1, count)) / totalWork))
            } ended: { _ in }
        }
        if outcome == .finished, !combined.isEmpty {
            var pass = ScanRequest(
                fileId: request.fileId, url: request.url, method: request.method, threshold: request.shotThreshold,
                ffmpeg: request.ffmpeg, store: request.scanStore, observer: collector)
            let last = combined.last!
            // Up to the last sampled frame, unless that is the movie's end.
            pass.endFrame = last >= source.info.frameCount - 1 ? nil : last
            request.tune(&pass)
            let base = facesOnlyWork
            outcome = await consume(ShotScanner.scan(pass), saver: saver) { scanned, _ in
                let done = Double(max(0, min(scanned, last + 1) - min(covered, last + 1)))
                continuation.yield(.progress((base + done) / totalWork))
            } ended: { shotScan = $0 }
        }
        return (outcome, shotScan)
    }

    private enum Outcome: Equatable {
        case finished, cancelled
        case failed(String)
    }

    /// Runs one pass to its end, saving the faces at checkpoints.
    private static func consume(
        _ events: AsyncStream<ScanEvent>, saver: Saver, progress: (Int, Int) -> Void,
        ended: (ScanData) -> Void
    ) async -> Outcome {
        var outcome: Outcome?
        for await event in events {
            switch event {
            case .progress(let scanned, let count):
                progress(scanned, count)
                saver.checkpoint()
            case .finished(let data), .stopped(let data):
                ended(data)
                outcome = .finished
            case .cancelled(let data):
                ended(data)
                outcome = .cancelled
            case .failed(let message):
                outcome = .failed(message)
            case .started, .scenes:
                break
            }
        }
        // Cancel ends the stream before the pass's last event.
        return outcome ?? .cancelled
    }

    private static func runSingleFrames(
        _ frames: [Int], backend: any DecodeBackend, collector: FaceCollector,
        _ continuation: AsyncStream<FaceScanEvent>.Continuation, saver: Saver
    ) async {
        let size = ScanGeometry.fit(width: backend.info.width, height: backend.info.height, maxSide: ScanGeometry.decodeSide)
        let failures = await collector.analyzing {
            var failures = 0
            for (i, number) in frames.enumerated() {
                if Task.isCancelled { break }
                do {
                    // One at a time: each request takes the DecodeGate; the
                    // next frame decodes while the last one is analyzed.
                    let decoded = try await backend.frame(number, maxWidth: size.width)
                    await collector.enqueue(number, image: decoded.image)
                } catch {
                    if Task.isCancelled { break }
                    failures += 1
                }
                continuation.yield(.progress(Double(i + 1) / Double(frames.count)))
                saver.checkpoint()
            }
            return failures
        }
        let data = saver.save()
        if Task.isCancelled {
            continuation.yield(.cancelled(data, shotScan: nil))
        } else if failures == frames.count {
            continuation.yield(.failed("No frame could be decoded", data))
        } else {
            continuation.yield(.finished(data, shotScan: nil))
        }
    }

    /// Writes the collected faces at most every `checkpointInterval`, and
    /// at the end.
    private final class Saver {
        let request: FaceScanRequest
        let collector: FaceCollector
        var last = ContinuousClock.now

        init(request: FaceScanRequest, collector: FaceCollector) {
            self.request = request
            self.collector = collector
        }

        func checkpoint() {
            guard ContinuousClock.now - last >= request.checkpointInterval else { return }
            _ = save()
        }

        @discardableResult
        func save() -> FaceData {
            last = ContinuousClock.now
            let data = collector.snapshot
            try? request.faceStore?.save(data, for: request.fileId)
            return data
        }
    }
}

/// The scan pass's observer: queues the wanted frames not yet analyzed for
/// one analysis worker, which runs the analyzer on them in order and records
/// them with the thresholds applied.
final class FaceCollector: ScanFrameObserver {
    /// Frames queued for the worker at most (about 0.1 s of a 24 fps film
    /// sampled every 10th frame, 0.9 MB a 720 px frame).
    static let defaultBacklog = 6

    let wanted: Set<Int>
    let analyzer: any FaceAnalyzer
    let backlog: Int
    let thumbnails: FaceScanThumbnails?
    private let state: Mutex<State>
    private let copier = FrameCopier()
    private let queue: AsyncStream<Item>
    private let input: AsyncStream<Item>.Continuation

    struct State {
        var data: FaceData
        /// Frames analyzed by this scan.
        var analyzedNow = 0
        var facesFound = 0
        /// Frames with faces in the scope: found before this scan, and now.
        var facesFrames = 0
        /// Frames handed to the queue (each frame once per scan).
        var taken = Set<Int>()
        /// Frames in the queue or being analyzed.
        var queued = 0
        /// The worker has stopped: nothing more is queued.
        var closed = false
        /// The pass waiting for room in the queue.
        var producer: CheckedContinuation<Bool, Never>?
    }

    private struct Item: @unchecked Sendable {
        enum Image {
            case buffer(CVPixelBuffer)
            case image(CGImage)
        }

        var frameNumber: Int
        var image: Image
    }

    init(
        data: FaceData, wanted: Set<Int>, analyzer: any FaceAnalyzer, backlog: Int = FaceCollector.defaultBacklog,
        thumbnails: FaceScanThumbnails? = nil, facesFramesBefore: Int = 0
    ) {
        self.wanted = wanted
        self.analyzer = analyzer
        self.backlog = max(1, backlog)
        self.thumbnails = thumbnails
        state = Mutex(State(data: data, facesFrames: facesFramesBefore))
        (queue, input) = AsyncStream.makeStream(of: Item.self)
    }

    var snapshot: FaceData { state.withLock { $0.data } }
    var analyzedNow: Int { state.withLock { $0.analyzedNow } }
    var facesFound: Int { state.withLock { $0.facesFound } }

    /// Runs `body`, which queues frames, beside the analysis worker, and
    /// returns once the worker has analyzed every queued frame. Cancelling
    /// the task stops both; frames queued but not analyzed stay missing.
    /// Call once.
    func analyzing<T>(_ body: () async -> T) async -> T {
        async let worker: Void = analyzeQueued()
        let result = await body()
        input.finish()
        await worker
        return result
    }

    func scanned(_ frame: ScanFrame) async {
        guard take(frame.frameNumber), await reserve() else { return }
        do {
            // The scan's frame is reused once this returns.
            let buffer = try copier.copy(frame.image)
            input.yield(Item(frameNumber: frame.frameNumber, image: .buffer(buffer)))
        } catch {
            // Stays missing for the next scan.
            release()
        }
    }

    func enqueue(_ number: Int, image: CGImage) async {
        guard take(number), await reserve() else { return }
        input.yield(Item(frameNumber: number, image: .image(image)))
    }

    /// Whether to queue a frame: wanted, not analyzed and not queued yet.
    private func take(_ frame: Int) -> Bool {
        guard wanted.contains(frame) else { return false }
        return state.withLock {
            guard !$0.closed, !$0.data.isAnalyzed(frame), !$0.taken.contains(frame) else { return false }
            $0.taken.insert(frame)
            return true
        }
    }

    /// Waits for room in the queue (back-pressure on the pass); false once
    /// the worker has stopped or the pass is cancelled.
    private func reserve() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                let ready: Bool? = state.withLock {
                    if $0.closed || Task.isCancelled { return false }
                    if $0.queued < backlog {
                        $0.queued += 1
                        return true
                    }
                    $0.producer = waiter
                    return nil
                }
                if let ready { waiter.resume(returning: ready) }
            }
        } onCancel: {
            state.withLock { s -> CheckedContinuation<Bool, Never>? in
                defer { s.producer = nil }
                return s.producer
            }?.resume(returning: false)
        }
    }

    /// Frees a place in the queue, handing it to a waiting pass.
    private func release() {
        state.withLock { s -> CheckedContinuation<Bool, Never>? in
            guard let producer = s.producer else {
                s.queued -= 1
                return nil
            }
            // The place goes straight to the waiting pass.
            s.producer = nil
            return producer
        }?.resume(returning: true)
    }

    private func analyzeQueued() async {
        for await item in queue {
            if Task.isCancelled { break }
            // A frame the analyzer fails on stays missing for the next scan.
            let detected: [DetectedFace]? = switch item.image {
            case .buffer(let buffer): try? await analyzer.detect(in: buffer)
            case .image(let image): try? await analyzer.detect(in: image)
            }
            if let detected, !Task.isCancelled, let nth = record(item.frameNumber, detected),
               let thumbnails, case .buffer(let buffer) = item.image {
                let width = thumbnails.width(nth)
                if let image = Self.thumbnail(of: buffer, width: width) {
                    thumbnails.deliver(item.frameNumber, image, min(width, image.width))
                }
            }
            release()
        }
        // Cancelled (or done): let a waiting pass go on without queueing.
        state.withLock { s -> CheckedContinuation<Bool, Never>? in
            s.closed = true
            defer { s.producer = nil }
            return s.producer
        }?.resume(returning: false)
    }

    /// Records a frame; for a frame with faces, which one in the scope it
    /// is (1-based), else nil.
    private func record(_ number: Int, _ detected: [DetectedFace]) -> Int? {
        state.withLock {
            let frame = FaceDetection.frame(number, detected: detected, thresholds: $0.data.thresholds)
            $0.data.record(frame)
            $0.analyzedNow += 1
            $0.facesFound += frame.faceCount
            guard frame.faceCount > 0 else { return nil }
            $0.facesFrames += 1
            return $0.facesFrames
        }
    }

    /// A thumbnail of a scan frame, at most `width` pixels wide (aspect
    /// kept, never enlarged). The scan's BGRA frames carry the movie's
    /// colors without conversion; they are tagged Rec. 709, as HD video and
    /// the image generator's thumbs of it are.
    static func thumbnail(of buffer: CVPixelBuffer, width: Int) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let w = min(max(1, width), sourceWidth)
        let h = max(1, Int((Double(w) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data
        else { return nil }
        var source = vImage_Buffer(
            data: base, height: vImagePixelCount(sourceHeight), width: vImagePixelCount(sourceWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var target = vImage_Buffer(
            data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: context.bytesPerRow)
        guard vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
        else { return nil }
        return context.makeImage()
    }
}

/// Copies scan frames into pooled 32BGRA buffers for the analysis queue.
/// Used only from the scan pass's loop (one caller at a time).
private final class FrameCopier: @unchecked Sendable {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    func copy(_ frame: BGRAFrame) throws -> CVPixelBuffer {
        if pool == nil || frame.width != width || frame.height != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: frame.width,
                kCVPixelBufferHeightKey: frame.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            width = frame.width
            height = frame.height
        }
        var created: CVPixelBuffer?
        let status = pool.map { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, $0, &created) } ?? kCVReturnError
        guard status == kCVReturnSuccess, let buffer = created else {
            throw DecodeError("Could not create a frame for face detection (\(status))")
        }
        try VisionFaceAnalyzer.copy(frame, into: buffer)
        return buffer
    }
}
