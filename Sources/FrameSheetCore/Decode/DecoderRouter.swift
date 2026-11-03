import Foundation

/// Opens a movie with AVFoundation, or with ffmpeg when AVFoundation has no
/// decodable video track or the HEVC sample entry is `hev1` (decision 10,
/// §10). An AVFoundation-opened movie reads a frame its exact request misses
/// from one GOP earlier; with `exactFallback` it fetches the frames that
/// read misses too with ffmpeg, frame by frame (decision 25). The file
/// itself stays with AVFoundation.
public enum DecoderRouter {
    public static func open(
        _ url: URL, ffmpeg: FFmpegTools?, exactFallback: Bool = false
    ) async throws -> any DecodeBackend {
        do {
            return try await AVFoundationBackend.open(url, fallback: exactFallback ? ffmpeg : nil)
        } catch let routing as RoutingError {
            guard let ffmpeg else {
                throw DecodeError("\(routing.reason), and ffmpeg was not found. Install it, for example with `brew install ffmpeg`, or choose it in the settings.")
            }
            return try await FFmpegBackend.open(url, tools: ffmpeg)
        }
    }
}
