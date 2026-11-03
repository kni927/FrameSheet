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
    /// Presentation time of frame 0: the video stream's start time.
    private let startTime: Double
    /// Frames that can be decoded before a frame shown earlier (ffprobe's
    /// `has_b_frames`).
    private let reorderDepth: Int

    static let concurrency = 5

    private init(tools: FFmpegTools, path: String, info: MediaInfo, startTime: Double, reorderDepth: Int) {
        self.tools = tools
        self.path = path
        self.info = info
        self.startTime = startTime
        self.reorderDepth = reorderDepth
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
        let start = Double(stream.start_time ?? "") ?? Double(probe.format?.start_time ?? "") ?? 0
        return FFmpegBackend(
            tools: tools, path: path, info: info, startTime: start.isFinite ? start : 0,
            reorderDepth: max(0, stream.has_b_frames ?? 0))
    }

    // MARK: - Probe helpers

    private struct Probe: Decodable {
        struct Format: Decodable {
            var duration: String?
            var size: String?
            var start_time: String?
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
            var start_time: String?
            var has_b_frames: Int?
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

    private var frameRate: Double { info.fps > 0 ? info.fps : 25 }

    /// How far before a frame's time the input seek lands, first try and
    /// second. ffmpeg's demuxers seek to the last keyframe whose decode time
    /// is at or before the seek point; a leading frame of an open GOP (shown
    /// before its I frame, decoded after it) lies after that I frame's
    /// decode time, so a seek to the frame itself starts at that I frame and
    /// returns the I frame. Seeking back by twice the reorder depth and a
    /// few frames reaches the keyframe before; the second try, 3 s back,
    /// covers streams with longer reordering.
    private var seekMargins: [Double] {
        let frames = Double(max(6, 2 * (reorderDepth + 2)))
        return [max(0.25, frames / frameRate), 3]
    }

    /// The frame number of a presentation time (rounded, so 6.9999 is 7).
    private func frameNumber(at pts: Double) -> Int {
        max(0, Int(((pts - startTime) * frameRate).rounded()))
    }

    /// Frame-exact on constant-frame-rate files: input-seeks a little before
    /// the frame (see `seekMargins`), keeps the original timestamps
    /// (`-copyts`) and lets `select` pass the first frame from half a frame
    /// before the frame's time on. `showinfo` reports that frame's
    /// timestamp, so the result names the frame actually decoded: when it
    /// is a later one (the seek landed past the frame), the second margin
    /// tries again.
    public func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        let fps = frameRate
        let target = Double(frameNumber) / fps
        let lowerBound = startTime + (Double(frameNumber) - 0.5) / fps
        var firstError = ""
        let margins = seekMargins
        for (attempt, margin) in margins.enumerated() {
            let result = try await extract(seek: max(0, target - margin), from: lowerBound, maxWidth: maxWidth)
            if attempt == 0 { firstError = result.error }
            guard let image = result.image else { break }
            let actual = result.pts.map(self.frameNumber(at:)) ?? frameNumber
            if actual == frameNumber || attempt == margins.count - 1 {
                return DecodedFrame(
                    image: image, requestedFrame: frameNumber, actualFrame: actual,
                    retried: actual != frameNumber, decoder: .ffmpeg)
            }
        }
        // No frame at or after the frame's time: the frame count estimated
        // from the duration can run past the last frame. Retry once 0.5 s
        // earlier (decision 11) and keep the frame that comes back, named
        // by its timestamp.
        let retryBound = max(startTime, lowerBound - 0.5)
        let retrySeek = max(0, retryBound - startTime - margins[0])
        let retry = try await extract(seek: retrySeek, from: retryBound, maxWidth: maxWidth)
        if let image = retry.image {
            let actual = retry.pts.map(self.frameNumber(at:))
                ?? max(0, Int(((retryBound - startTime) * fps - 1e-6).rounded(.up)))
            return DecodedFrame(
                image: image, requestedFrame: frameNumber, actualFrame: actual, retried: true, decoder: .ffmpeg)
        }
        let reason = firstError.isEmpty ? "ffmpeg returned no image" : firstError
        throw DecodeError("Frame \(frameNumber): \(reason)")
    }

    /// One ffmpeg run: the first frame whose timestamp is at or after
    /// `lowerBound` (seconds, in the file's own timestamps), decoding from
    /// the keyframe before `seek` (seconds from the start). Returns the
    /// image, its timestamp and the error lines ffmpeg printed.
    private func extract(
        seek: Double, from lowerBound: Double, maxWidth: Int
    ) async throws -> (image: CGImage?, pts: Double?, error: String) {
        // Even width for the scaler; never wider than the movie.
        let width = max(2, min(maxWidth, info.width > 0 ? info.width : maxWidth) / 2 * 2)
        let result = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "level+info",
            "-copyts",
            "-ss", String(format: "%.6f", seek),
            "-i", path,
            "-frames:v", "1", "-an", "-sn", "-dn",
            "-vf", "select='gte(t,\(String(format: "%.6f", lowerBound)))',showinfo,scale=\(width):-2",
            "-f", "image2pipe", "-c:v", "png", "-",
        ], timeout: .seconds(60))
        let log = Self.parseLog(result.stderrText)
        guard result.status == 0, !result.stdout.isEmpty,
              let source = CGImageSourceCreateWithData(result.stdout as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return (nil, nil, log.error) }
        return (image, log.pts, log.error)
    }

    /// The timestamp of the first frame `showinfo` passed and the error
    /// lines, from ffmpeg's stderr at `-loglevel level+info`.
    static func parseLog(_ text: String) -> (pts: Double?, error: String) {
        var pts: Double?
        var errors: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if pts == nil, line.contains("Parsed_showinfo"), line.contains(" n:"),
               let range = line.range(of: "pts_time:") {
                let value = line[range.upperBound...].prefix { !$0.isWhitespace }
                pts = Double(value)
            } else if let range = line.range(of: "[error] ") ?? line.range(of: "[fatal] ") {
                errors.append(String(line[range.upperBound...]))
            }
        }
        return (pts, errors.joined(separator: "\n"))
    }

    public func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult> {
        concurrentFrames(frameNumbers, maxWidth: maxWidth, concurrency: Self.concurrency)
    }
}
