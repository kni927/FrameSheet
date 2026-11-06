import CoreGraphics
import Foundation
import Synchronization

/// What the probe of a movie found. Width and height are the display size
/// (rotation applied).
public struct MediaInfo: Sendable, Equatable {
    public var duration: Double
    public var frameCount: Int
    public var fps: Double
    public var width: Int
    public var height: Int
    public var fourCC: String
    public var size: Int64

    public init(
        duration: Double, frameCount: Int, fps: Double, width: Int, height: Int, fourCC: String,
        size: Int64
    ) {
        self.duration = duration
        self.frameCount = frameCount
        self.fps = fps
        self.width = width
        self.height = height
        self.fourCC = fourCC
        self.size = size
    }
}

public enum DecoderKind: String, Sendable {
    case avFoundation = "AVFoundation"
    /// An `AVAssetReader` read from one GOP earlier, for a frame the exact
    /// image-generator request missed (decision 25).
    case avFoundationReader = "AVFoundation reader"
    case ffmpeg
}

public struct DecodedFrame: Sendable {
    public var image: CGImage
    public var requestedFrame: Int
    /// The frame actually decoded; differs from the request after the
    /// ±0.5 s retry (decision 11).
    public var actualFrame: Int
    public var retried: Bool
    /// The decoder that produced the image: the reader or ffmpeg for a
    /// frame the AVFoundation backend fetched with a fallback (decision 25).
    public var decoder: DecoderKind = .avFoundation

    /// The image shows the requested frame.
    public var isExact: Bool { actualFrame == requestedFrame }
}

public struct FrameResult: Sendable {
    /// Position in the requested list.
    public var index: Int
    public var frameNumber: Int
    public var result: Result<DecodedFrame, DecodeError>
}

public struct DecodeError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One opened movie. AVFoundationBackend is the default;
/// FFmpegBackend takes what AVFoundation cannot decode (§10).
public protocol DecodeBackend: Sendable {
    var kind: DecoderKind { get }
    var info: MediaInfo { get }

    /// One frame, scaled to at most `maxWidth` pixels wide (aspect kept,
    /// never enlarged).
    func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame

    /// Several frames; results arrive as they are decoded, in any order.
    /// Cancelling the consuming task stops the work.
    func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult>

    /// The consecutive frames of `range` (the player's frame strip, §9),
    /// read in one sequential pass rather than one request per frame;
    /// results arrive as they are decoded, indexed by their offset in the
    /// range. Frames the pass does not deliver exactly go through the
    /// single-frame steps (decision 25). Cancelling the consuming task stops
    /// the work.
    func frameRun(_ range: ClosedRange<Int>, maxWidth: Int) -> AsyncStream<FrameResult>
}

extension DecodeBackend {
    /// Default batch: up to `concurrency` single-frame requests at a time.
    func concurrentFrames(
        _ frameNumbers: [Int], maxWidth: Int, concurrency: Int
    ) -> AsyncStream<FrameResult> {
        AsyncStream { continuation in
            let task = Task {
                let work: @Sendable (Int) async -> FrameResult = { index in
                    let number = frameNumbers[index]
                    do {
                        let frame = try await self.frame(number, maxWidth: maxWidth)
                        return FrameResult(index: index, frameNumber: number, result: .success(frame))
                    } catch let error as DecodeError {
                        return FrameResult(index: index, frameNumber: number, result: .failure(error))
                    } catch {
                        return FrameResult(
                            index: index, frameNumber: number,
                            result: .failure(DecodeError(error.localizedDescription)))
                    }
                }
                await withTaskGroup(of: FrameResult.self) { group in
                    var next = 0
                    while next < min(concurrency, frameNumbers.count) {
                        let index = next
                        group.addTask { await work(index) }
                        next += 1
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        if Task.isCancelled { group.cancelAll(); break }
                        if next < frameNumbers.count {
                            let index = next
                            group.addTask { await work(index) }
                            next += 1
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The value of a task that other callers share, awaited so that cancelling
/// the caller stops its wait at once (`task.value` would wait for the shared
/// task, which is not cancelled with one of its callers).
func cancellableValue<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
    let pending = Mutex<CheckedContinuation<T, any Error>?>(nil)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            if Task.isCancelled {
                pending.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
                return
            }
            Task {
                let result = await task.result
                pending.withLock { $0?.resume(with: result); $0 = nil }
            }
        }
    } onCancel: {
        pending.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
    }
}
