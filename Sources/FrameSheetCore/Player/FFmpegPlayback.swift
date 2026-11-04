import CoreGraphics
import Foundation

// Video-only playback of ffmpeg-routed files in the player view (§9): the
// frames of one ffmpeg rawvideo pipe, shown in real time by the app. The
// timing (`PlaybackPacer`, `PlaybackLoop`) needs no ffmpeg and no real
// clock, so tests drive it with a virtual one.

/// One frame of playback: its number, its presentation time (seconds, the
/// file's own timestamps) and the image.
public struct PlaybackFrame: Sendable {
    public var frameNumber: Int
    public var time: Double
    public var image: CGImage

    public init(frameNumber: Int, time: Double, image: CGImage) {
        self.frameNumber = frameNumber
        self.time = time
        self.image = image
    }
}

/// Real-time pacing: each frame is due at its presentation time against a
/// monotonic clock, counted from the first frame (anchored when it
/// arrives, so ffmpeg's start-up does not make the next frames late).
/// A frame that arrives early waits until it is due (playback never runs
/// ahead); one more than a frame late is dropped, unless nothing was shown
/// for `minimumRefresh` seconds (a decode slower than real time still
/// shows a frame now and then; playback then falls behind the clock rather
/// than skipping ahead).
public struct PlaybackPacer: Sendable {
    public enum Decision: Sendable, Equatable {
        /// Show the frame at this clock time (now or later).
        case show(at: Double)
        case drop
    }

    public let frameDuration: Double
    public var minimumRefresh: Double
    private var anchor: (clock: Double, time: Double)?
    private var lastShown: Double?

    public init(fps: Double, minimumRefresh: Double = 0.1) {
        frameDuration = 1 / (fps > 0 ? fps : 25)
        self.minimumRefresh = minimumRefresh
    }

    /// The clock time a frame of presentation time `time` is due at; nil
    /// before the first frame.
    public func due(_ time: Double) -> Double? {
        anchor.map { $0.clock + (time - $0.time) }
    }

    /// What to do with a frame of presentation time `time` that is ready
    /// at clock time `now`.
    public mutating func decide(time: Double, now: Double) -> Decision {
        guard let due = due(time) else {
            anchor = (now, time)
            lastShown = now
            return .show(at: now)
        }
        if now <= due {
            lastShown = due
            return .show(at: due)
        }
        if now - due > frameDuration, let lastShown, now - lastShown < minimumRefresh {
            return .drop
        }
        lastShown = now
        return .show(at: now)
    }
}

/// A monotonic clock in seconds that playback can wait on.
public protocol PlaybackClock: Sendable {
    func now() -> Double
    /// Returns at `time` or later; throws when the task is cancelled.
    func sleep(until time: Double) async throws
}

/// The system's monotonic clock (`ContinuousClock`).
public struct ContinuousPlaybackClock: PlaybackClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Double {
        let elapsed = ContinuousClock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }

    public func sleep(until time: Double) async throws {
        let wait = time - now()
        guard wait > 0 else { return }
        try await Task.sleep(for: .seconds(wait))
    }
}

/// What a playback run did.
public struct PlaybackStats: Sendable, Equatable {
    public var shown = 0
    public var dropped = 0
    /// The last frame shown; nil before the first.
    public var lastFrame: Int?
    /// The largest delay of a shown frame after it was due (seconds).
    public var maxLateness: Double = 0

    public init() {}
}

public enum PlaybackLoop {
    /// Pulls frames from `next` until it returns nil (or the task is
    /// cancelled), paces them with `PlaybackPacer` on `clock` and hands each
    /// frame to show to `show` at its time. Frames come in decode order of
    /// a forward pipe, so their times rise; a frame whose time does not is
    /// shown (or dropped) like a late one. Runs on the caller's actor, so
    /// `show` may draw on the main actor.
    @discardableResult
    nonisolated(nonsending) public static func run(
        fps: Double, clock: some PlaybackClock,
        next: nonisolated(nonsending) () async throws -> PlaybackFrame?,
        show: (PlaybackFrame) -> Void
    ) async throws -> PlaybackStats {
        var pacer = PlaybackPacer(fps: fps)
        var stats = PlaybackStats()
        while let frame = try await next() {
            try Task.checkCancellation()
            let now = clock.now()
            switch pacer.decide(time: frame.time, now: now) {
            case .drop:
                stats.dropped += 1
            case .show(let at):
                try await clock.sleep(until: at)
                if let due = pacer.due(frame.time) { stats.maxLateness = max(stats.maxLateness, at - due) }
                show(frame)
                stats.shown += 1
                stats.lastFrame = frame.frameNumber
            }
        }
        return stats
    }
}

/// The frames of one ffmpeg playback pipe (`FFmpegBackend.playbackSource`).
/// Reads block on the pipe's queue, not on the caller; each frame takes the
/// next `showinfo` timestamp from stderr (or, when none comes within
/// `timestampWait`, the previous one plus a frame, and from then on always
/// so). `close()` stops ffmpeg and waits until it has exited.
public final class FFmpegPlaybackSource: @unchecked Sendable {
    private let pipe: RawVideoPipe
    private let times: TimestampQueue
    private let width: Int
    private let height: Int
    private let fps: Double
    private let firstFrame: Int
    private let frameCount: Int
    private let frameNumber: @Sendable (Double) -> Int
    private let lock = NSLock()
    private var buffer: UnsafeMutableRawPointer?
    private var lastTime: Double?
    private var estimating = false
    private var closed = false

    /// How long a frame waits for its `showinfo` line.
    static let timestampWait: Duration = .milliseconds(500)

    init(
        executable: URL, arguments: [String], width: Int, height: Int, fps: Double, firstFrame: Int,
        frameCount: Int, frameNumber: @escaping @Sendable (Double) -> Int
    ) {
        let times = TimestampQueue()
        self.times = times
        self.width = width
        self.height = height
        self.fps = fps > 0 ? fps : 25
        self.firstFrame = firstFrame
        self.frameCount = frameCount
        self.frameNumber = frameNumber
        pipe = RawVideoPipe(executable: executable, arguments: arguments) { line in
            if let time = FFmpegBackend.showinfoTime(line) { times.push(time) }
        }
    }

    deinit { buffer?.deallocate() }

    public var frameSize: (width: Int, height: Int) { (width, height) }

    public func start() throws {
        try pipe.start()
    }

    /// The next frame, or nil at the end of the stream (or after `close`).
    @concurrent
    public func next() async throws -> PlaybackFrame? {
        let count = width * 4 * height
        let target: UnsafeMutableRawPointer? = lock.withLock {
            if closed { return nil }
            if buffer == nil { buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64) }
            return buffer
        }
        guard let target, try await pipe.readFrame(into: target, count: count) else { return nil }
        let data = Data(bytes: target, count: count)
        let time: Double
        if !lock.withLock({ estimating }), let reported = await times.next(timeout: Self.timestampWait) {
            time = reported
        } else {
            lock.withLock { estimating = true }
            time = lock.withLock { lastTime }.map { $0 + 1 / fps } ?? Double(firstFrame) / fps
        }
        lock.withLock { lastTime = time }
        guard let image = FFmpegBackend.image(bgra: data, width: width, height: height) else { return nil }
        let number = min(frameNumber(time), max(0, frameCount - 1))
        return PlaybackFrame(frameNumber: number, time: time, image: image)
    }

    /// Stops ffmpeg (closing the pipe, then SIGKILL after a grace period, as
    /// `RawVideoPipe.finish`) and returns once it has exited.
    public func close() async {
        lock.withLock { closed = true }
        pipe.terminate()
        _ = await pipe.finish()
        times.close()
    }
}

/// `showinfo` timestamps in arrival order, for the frames read after them.
final class TimestampQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<Double?, Never>)?
    private var closed = false

    func push(_ time: Double) {
        let waiting: CheckedContinuation<Double?, Never>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter.continuation
            }
            times.append(time)
            return nil
        }
        waiting?.resume(returning: time)
    }

    func close() {
        let waiting = lock.withLock { () -> CheckedContinuation<Double?, Never>? in
            closed = true
            defer { waiter = nil }
            return waiter?.continuation
        }
        waiting?.resume(returning: nil)
    }

    /// The next timestamp; nil after `timeout` or once closed.
    func next(timeout: Duration) async -> Double? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let ready: Double?? = lock.withLock {
                if !times.isEmpty { return .some(times.removeFirst()) }
                if closed { return .some(nil) }
                waiter = (id, continuation)
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let expired = lock.withLock { () -> CheckedContinuation<Double?, Never>? in
                    guard let waiter, waiter.id == id else { return nil }
                    self.waiter = nil
                    return waiter.continuation
                }
                expired?.resume(returning: nil)
            }
        }
    }
}
