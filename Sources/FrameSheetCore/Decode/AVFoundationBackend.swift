import AVFoundation
import CoreGraphics
import Foundation

// Ported from v2 src/AVFoundationBackend.swift: the probe, the zero-tolerance
// AVAssetImageGenerator with one ±0.5 s retry per failed frame (decision 11),
// and the fourCC naming. Rewritten for Swift 6 concurrency and the async
// AVFoundation loading API; frames are addressed by frame number.

/// In-process decode with VideoToolbox. The asset stays open for the movie,
/// so later requests hit a warm decoder.
public final class AVFoundationBackend: DecodeBackend {
    public let kind = DecoderKind.avFoundation
    public let info: MediaInfo
    private let asset: AVURLAsset
    /// Presentation time of frame 0.
    private let startTime: Double

    private static let retryTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    private init(asset: AVURLAsset, info: MediaInfo, startTime: Double) {
        self.asset = asset
        self.info = info
        self.startTime = startTime
    }

    /// Opens the movie, or throws `RoutingError` when the file should go to
    /// ffmpeg instead (no decodable video track, or HEVC tagged `hev1`).
    public static func open(_ url: URL) async throws -> AVFoundationBackend {
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

        let (decodable, formats, naturalSize, transform, nominalRate, timeRange) = try await track.load(
            .isDecodable, .formatDescriptions, .naturalSize, .preferredTransform, .nominalFrameRate,
            .timeRange)
        let fourCC = formats.first.map { fourCCString(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
        guard decodable else {
            throw RoutingError("AVFoundation cannot decode \(fourCC.isEmpty ? "this codec" : fourCC)")
        }
        // VideoToolbox rejects HEVC with the hev1 sample entry (-12906); the
        // spike found that the track still reports itself decodable.
        guard fourCC != "hev1" else {
            throw RoutingError("HEVC tagged hev1 is not decodable by AVFoundation")
        }

        let duration = try await asset.load(.duration).seconds
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
        let start = timeRange.start.seconds
        return AVFoundationBackend(asset: asset, info: info, startTime: start.isFinite ? start : 0)
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
        return CMTime(seconds: startTime + (Double(frame) + 0.5) / fps, preferredTimescale: 600_000)
    }

    private static func key(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 600_000, method: .roundHalfAwayFromZero).value
    }

    private func frameNumber(at time: CMTime) -> Int {
        let fps = info.fps > 0 ? info.fps : 25
        return max(0, Int(((time.seconds - startTime) * fps).rounded(.down)))
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
        let requested = time(of: frameNumber)
        do {
            let (image, _) = try await makeGenerator(maxWidth: maxWidth, exact: true).image(at: requested)
            return DecodedFrame(image: image, requestedFrame: frameNumber, actualFrame: frameNumber, retried: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await retry(frameNumber, maxWidth: maxWidth)
        }
    }

    /// The bounded-tolerance retry, keeping the frame actually decoded.
    private func retry(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        do {
            let (image, actual) = try await makeGenerator(maxWidth: maxWidth, exact: false)
                .image(at: time(of: frameNumber))
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
                    if let image = try? result.image {
                        let frame = DecodedFrame(
                            image: image, requestedFrame: number, actualFrame: number, retried: false)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .success(frame)))
                    } else {
                        failed.append(index)
                    }
                }
                for index in failed where !Task.isCancelled {
                    let number = frameNumbers[index]
                    do {
                        let frame = try await retry(number, maxWidth: maxWidth)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .success(frame)))
                    } catch {
                        let message = (error as? DecodeError) ?? DecodeError(error.localizedDescription)
                        continuation.yield(FrameResult(index: index, frameNumber: number, result: .failure(message)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// AVFoundation cannot take this file; the router sends it to ffmpeg.
public struct RoutingError: Error, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

