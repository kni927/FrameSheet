import CoreGraphics
import Foundation

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
    case ffmpeg
}

public struct DecodedFrame: Sendable {
    public var image: CGImage
    public var requestedFrame: Int
    /// The frame actually decoded; differs from the request after the
    /// ±0.5 s retry (decision 11).
    public var actualFrame: Int
    public var retried: Bool
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
