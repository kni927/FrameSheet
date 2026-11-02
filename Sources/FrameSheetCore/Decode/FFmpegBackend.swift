import CoreGraphics
import Foundation
import ImageIO

// Ported from v2 src/FFmpegBackend.swift: the ffprobe JSON probe, the
// two-attempt packet-timestamp scan for files without a duration
// (docs/DEV_LOG.md, "Phase 4"), and one input-seeking ffmpeg run per frame,
// five at a time, in software decode. v3 runs the tools without a shell,
// reads the frame from a PNG pipe instead of temporary JPEG files, and
// addresses frames by number.

/// Fallback decode through the system ffmpeg for files AVFoundation cannot
/// take (WebM, MKV, WMV3, HEVC tagged hev1, …).
public final class FFmpegBackend: DecodeBackend {
    public let kind = DecoderKind.ffmpeg
    public let info: MediaInfo
    private let tools: FFmpegTools
    private let path: String

    static let concurrency = 5

    private init(tools: FFmpegTools, path: String, info: MediaInfo) {
        self.tools = tools
        self.path = path
        self.info = info
    }

    public static func open(_ url: URL, tools: FFmpegTools) async throws -> FFmpegBackend {
        guard let ffprobe = tools.ffprobe else {
            throw DecodeError("ffprobe was not found next to \(tools.ffmpeg.path).")
        }
        let path = url.nfcPath
        let result = try await ProcessRunner.run(
            ffprobe, ["-v", "error", "-show_format", "-show_streams", "-print_format", "json", path],
            timeout: .seconds(60))
        guard result.status == 0 else {
            throw DecodeError("ffprobe could not read the file: \(result.stderrText)")
        }
        let probe: Probe
        do {
            probe = try JSONDecoder().decode(Probe.self, from: result.stdout)
        } catch {
            throw DecodeError("ffprobe output could not be parsed: \(error.localizedDescription)")
        }
        guard let stream = probe.streams?.first(where: { $0.codec_type == "video" }) else {
            throw DecodeError("The file has no video stream.")
        }

        let fps = rate(stream.avg_frame_rate) ?? rate(stream.r_frame_rate) ?? 0
        var duration = positive(probe.format?.duration) ?? positive(stream.duration) ?? 0
        if duration == 0 {
            duration = await estimateDuration(path: path, ffprobe: ffprobe) ?? 0
        }
        guard duration > 0 else { throw DecodeError("The duration of the file could not be found.") }

        var width = stream.width ?? 0
        var height = stream.height ?? 0
        // ffmpeg rotates on decode by default, so report the display size.
        if let rotation = stream.rotation, abs(rotation) % 180 == 90 { swap(&width, &height) }
        let frameCount = Int(stream.nb_frames ?? "").flatMap { $0 > 0 ? $0 : nil }
            ?? Int((duration * fps).rounded())
        let size = Int64(probe.format?.size ?? "")
            ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let tag = stream.codec_tag_string ?? ""
        let fourCC = tag.isEmpty || tag.hasPrefix("[") ? (stream.codec_name ?? "") : tag

        let info = MediaInfo(
            duration: duration, frameCount: frameCount, fps: fps, width: width, height: height,
            fourCC: fourCC, size: size)
        return FFmpegBackend(tools: tools, path: path, info: info)
    }

    // MARK: - Probe helpers

    private struct Probe: Decodable {
        struct Format: Decodable {
            var duration: String?
            var size: String?
        }
        struct Stream: Decodable {
            var codec_type: String?
            var codec_name: String?
            var codec_tag_string: String?
            var width: Int?
            var height: Int?
            var avg_frame_rate: String?
            var r_frame_rate: String?
            var nb_frames: String?
            var duration: String?
            var side_data_list: [SideData]?
            var tags: [String: String]?

            var rotation: Int? {
                side_data_list?.compactMap(\.rotation).first ?? tags?["rotate"].flatMap { Int($0) }
            }
        }
        struct SideData: Decodable {
            var rotation: Int?
        }
        var format: Format?
        var streams: [Stream]?
    }

    /// "60000/1001" → 59.94; nil for "0/0" and the like.
    static func rate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        let value = parts.count == 2 ? (parts[1] != 0 ? parts[0] / parts[1] : 0) : (parts.first ?? 0)
        return value.isFinite && value > 0 ? value : nil
    }

    private static func positive(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Duration from packet timestamps. Attempt 1 reads only the trailing
    /// packets (instant for indexed containers; a cues-less WebM falls back
    /// to a linear, IO-bound scan); attempt 2 lists every packet.
    static func estimateDuration(path: String, ffprobe: URL) async -> Double? {
        let base = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "csv=p=0"]
        for extra in [["-read_intervals", "9999999"], []] {
            guard let result = try? await ProcessRunner.run(ffprobe, base + extra + [path]),
                  result.status == 0 else { continue }
            let maxPTS = result.stdoutText.split(whereSeparator: \.isNewline)
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .punctuationCharacters)) }
                .max()
            if let maxPTS, maxPTS.isFinite, maxPTS > 0 { return maxPTS }
        }
        return nil
    }

    // MARK: - Frames

    /// Seek to half a frame before the frame's start: ffmpeg's accurate
    /// input seek then returns the first frame at or after that time, which
    /// is the requested one.
    private func seconds(of frame: Int) -> Double {
        let fps = info.fps > 0 ? info.fps : 25
        return max(0, (Double(frame) - 0.5) / fps)
    }

    public func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        // Even width for the scaler; never wider than the movie.
        let width = max(2, min(maxWidth, info.width > 0 ? info.width : maxWidth) / 2 * 2)
        let result = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-ss", String(format: "%.6f", seconds(of: frameNumber)),
            "-i", path,
            "-frames:v", "1", "-an", "-sn",
            "-vf", "scale=\(width):-2",
            "-f", "image2pipe", "-c:v", "png", "-",
        ], timeout: .seconds(60))
        guard result.status == 0, !result.stdout.isEmpty,
              let source = CGImageSourceCreateWithData(result.stdout as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            let reason = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DecodeError("Frame \(frameNumber): \(reason.isEmpty ? "ffmpeg returned no image" : reason)")
        }
        return DecodedFrame(image: image, requestedFrame: frameNumber, actualFrame: frameNumber, retried: false)
    }

    public func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult> {
        concurrentFrames(frameNumbers, maxWidth: maxWidth, concurrency: Self.concurrency)
    }
}
