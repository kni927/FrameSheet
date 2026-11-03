import AVFoundation
import CoreGraphics
import Foundation
import Testing
import VideoToolbox
@testable import FrameSheetCore

@Suite struct FFmpegLocatorTests {
    /// A directory with an executable `ffmpeg` script printing `version`.
    private func fakeFFmpeg(version: String = "9.9-test", ffprobe: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ffprobe ? ["ffmpeg", "ffprobe"] : ["ffmpeg"] {
            let url = dir.appending(path: name)
            try "#!/bin/sh\necho \"\(name) version \(version) Copyright (c) test\"\n"
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func userPathWins() async throws {
        let dir = try fakeFFmpeg()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locator = FFmpegLocator(
            userPath: dir.appending(path: "ffmpeg").path, loginShellLookup: { "/nonexistent/ffmpeg" },
            knownDirectories: [])
        let found = await locator.discover()
        #expect(found.tools?.source == .user)
        #expect(found.tools?.version == "9.9-test")
        #expect(found.tools?.ffprobe?.lastPathComponent == "ffprobe")
        #expect(found.notes.isEmpty)
    }

    @Test func userDirectoryAccepted() async throws {
        let dir = try fakeFFmpeg()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FFmpegLocator(userPath: dir.path, loginShellLookup: { nil }, knownDirectories: [])
            .discover()
        #expect(found.tools?.source == .user)
    }

    @Test func wrongUserPathFallsBackToLoginShell() async throws {
        let dir = try fakeFFmpeg()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "ffmpeg").path
        let found = await FFmpegLocator(
            userPath: "/nonexistent/ffmpeg", loginShellLookup: { path }, knownDirectories: []
        ).discover()
        #expect(found.tools?.source == .loginShell)
        #expect(found.notes.count == 1)
    }

    @Test func wrongUserPathFallsBackToKnownDirectory() async throws {
        let dir = try fakeFFmpeg()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FFmpegLocator(
            userPath: "/nonexistent/ffmpeg", loginShellLookup: { nil },
            knownDirectories: ["/nonexistent", dir.path]
        ).discover()
        #expect(found.tools?.source == .knownLocation)
        #expect(found.tools?.ffmpeg.path == dir.appending(path: "ffmpeg").path)
    }

    @Test func notAnFFmpeg() async throws {
        // /bin/echo exits 0 but prints no "ffmpeg version" line.
        let found = await FFmpegLocator(userPath: "/bin/echo", loginShellLookup: { nil }, knownDirectories: [])
            .discover()
        #expect(found.tools == nil)
        #expect(found.notes.count == 2)
    }

    @Test func versionParsing() {
        #expect(FFmpegLocator.parseVersion("ffmpeg version 8.0 Copyright (c) 2000-2025\nbuilt with") == "8.0")
        #expect(FFmpegLocator.parseVersion("ffmpeg version n7.1-3-gabc Copyright") == "n7.1-3-gabc")
        #expect(FFmpegLocator.parseVersion("something else") == nil)
    }

    @Test func frameRates() {
        #expect(FFmpegBackend.rate("60000/1001").map { abs($0 - 59.94) < 0.001 } == true)
        #expect(FFmpegBackend.rate("25/1") == 25)
        #expect(FFmpegBackend.rate("0/0") == nil)
        #expect(FFmpegBackend.rate(nil) == nil)
    }
}

/// Decodes clips made on the fly by the system ffmpeg (skipped without
/// it). Frame n of each clip shows n in binary as six black or white
/// stripes (bit 0 on the left), which survive scaling and color
/// conversion, so the decoded image tells which frame came back.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DecodeIntegrationTests {
    static let tools: FFmpegTools? = {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found: FFmpegTools?
        Task {
            found = await FFmpegLocator(userPath: nil).discover().tools
            semaphore.signal()
        }
        semaphore.wait()
        return found
    }()

    static let frameCount = 50

    private static func makeClip(
        _ name: String, _ codecArgs: [String], rate: Int = 25, frames: Int = frameCount
    ) async throws -> URL {
        let tools = try #require(Self.tools)
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetClips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let result = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=320x180:r=\(rate):d=\(frames / rate + 1),format=yuv420p,geq=lum='16+219*mod(floor(N/pow(2,floor(X*6/W))),2)':cb=128:cr=128",
            "-frames:v", "\(frames)",
        ] + codecArgs + [url.path])
        #expect(result.status == 0, "\(result.stderrText)")
        return url
    }

    /// Frame number from the six stripes.
    private static func frameNumber(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var number = 0
        for bit in 0..<6 {
            let x = Int((Double(bit) + 0.5) * Double(width) / 6)
            let i = ((height / 2) * width + x) * 4
            if pixels[i] > 128 { number |= 1 << bit }
        }
        return number
    }

    private func check(_ clip: URL, expect kind: DecoderKind) async throws {
        try await withDeadline("decoding \(clip.lastPathComponent)") { try await checkFrames(clip, expect: kind) }
    }

    private func checkFrames(_ clip: URL, expect kind: DecoderKind) async throws {
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools)
        #expect(backend.kind == kind)
        #expect(backend.info.width == 320)
        #expect(backend.info.height == 180)
        #expect(abs(backend.info.fps - 25) < 0.01)
        #expect(backend.info.frameCount == Self.frameCount)

        let wanted = IntervalFrames.frameNumbers(
            amount: 16, start: 0, stop: Self.frameCount - 1, maxValue: Self.frameCount,
            limitToMaxValue: true)
        var seen: [Int: Int] = [:]
        for await result in backend.frames(wanted, maxWidth: 160) {
            let frame = try result.result.get()
            #expect(frame.image.width == 160)
            seen[result.index] = Self.frameNumber(in: frame.image)
        }
        #expect(seen.count == wanted.count)
        for (index, number) in wanted.enumerated() {
            #expect(seen[index] == number, "frame \(number) at index \(index)")
        }
        // Past the last frame: the backend returns a frame it names truthfully.
        let pastEnd = try await backend.frame(Self.frameCount, maxWidth: 160)
        #expect(Self.frameNumber(in: pastEnd.image) == pastEnd.actualFrame)
        #expect(pastEnd.actualFrame < Self.frameCount)

        // The last frame through the batch at a print's larger width, as
        // Save Sheet asks for it (T04: it failed there).
        let last = Self.frameCount - 1
        var lastResults: [FrameResult] = []
        for await result in backend.frames([last - 10, last], maxWidth: 4000) { lastResults.append(result) }
        #expect(lastResults.count == 2)
        for result in lastResults {
            let frame = try result.result.get()
            #expect(frame.image.width == 320)
            #expect(Self.frameNumber(in: frame.image) == frame.actualFrame)
        }
        let lastFrame = try #require(lastResults.first { $0.frameNumber == last }).result.get()
        #expect(lastFrame.actualFrame == last)

        let single = try await backend.frame(7, maxWidth: 4000)
        #expect(single.image.width == 320)
        #expect(Self.frameNumber(in: single.image) == 7)
    }

    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func h264MP4UsesAVFoundation() async throws {
        let clip = try await Self.makeClip("h264.mp4", ["-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p"])
        try await check(clip, expect: .avFoundation)
    }

    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func hevcHvc1UsesAVFoundation() async throws {
        let clip = try await Self.makeClip(
            "hvc1.mp4", ["-c:v", "libx265", "-x265-params", "lossless=1:log-level=error", "-tag:v", "hvc1"])
        try await check(clip, expect: .avFoundation)
    }

    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func hevcHev1GoesToFFmpeg() async throws {
        let clip = try await Self.makeClip(
            "hev1.mp4", ["-c:v", "libx265", "-x265-params", "lossless=1:log-level=error", "-tag:v", "hev1"])
        try await check(clip, expect: .ffmpeg)
    }

    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func mkvGoesToFFmpeg() async throws {
        let clip = try await Self.makeClip("h264.mkv", ["-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p"])
        try await check(clip, expect: .ffmpeg)
    }

    /// The ±0.5 s retry stays inside the movie: at the end it asks half the
    /// tolerance before the end, elsewhere at the frame itself.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func retryWindowStaysInsideTheMovie() async throws {
        let clip = try await Self.makeClip("retry.mov", ["-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p"])
        let backend = try #require(try await DecoderRouter.open(clip, ffmpeg: Self.tools) as? AVFoundationBackend)
        let duration = backend.info.duration
        #expect(abs(duration - 2) < 0.05)
        let last = backend.retryTime(of: Self.frameCount - 1).seconds
        #expect(abs(last - (duration - 0.5)) < 1e-3)
        #expect(abs(backend.retryTime(of: 10).seconds - 10.5 / 25) < 1e-4)
        // The batch at a larger width decodes the last frame of a B-frame clip.
        var results: [FrameResult] = []
        for await result in backend.frames([0, Self.frameCount - 1], maxWidth: 1920) { results.append(result) }
        let frame = try #require(results.first { $0.frameNumber == Self.frameCount - 1 }).result.get()
        #expect(Self.frameNumber(in: frame.image) == frame.actualFrame)
        #expect(frame.actualFrame == Self.frameCount - 1)
    }

    // MARK: Open GOP (decision 25)

    static let openGOPFrames = 64

    /// An open-GOP H.264 movie like the one KNOWN_ISSUES 5 describes: 24 fps,
    /// a keyframe every 16 frames, of which only the first is an IDR frame;
    /// the others are I frames with a recovery point that the muxer marks
    /// as sync samples, each with three leading B frames (13–15, 29–31,
    /// 45–47) that are shown before it and reference the GOP before.
    private static func makeOpenGOPClip() async throws -> URL {
        try await makeClip("open-gop.mov", [
            "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
            "-x264-params", "open-gop=1:keyint=16:min-keyint=16:scenecut=0:bframes=3:b-adapt=0:log-level=error",
        ], rate: 24, frames: openGOPFrames)
    }

    /// Every frame of the clip through the batch, by request index.
    private func decodeAll(_ backend: any DecodeBackend) async throws -> [Int: DecodedFrame] {
        var decoded: [Int: DecodedFrame] = [:]
        for await result in backend.frames(Array(0..<Self.openGOPFrames), maxWidth: 160) {
            decoded[result.index] = try result.result.get()
        }
        #expect(decoded.count == Self.openGOPFrames)
        return decoded
    }

    /// The frames whose read from one GOP earlier starts at the IDR frame 0:
    /// the leading frames of keyframe 16 and the rest of its GOP. The
    /// earlier-GOP reader recovers these (see
    /// `openGOPEarlierGOPReaderIsExact`).
    static let idrStartedFrames = Set(13..<29).subtracting([16])

    /// How many frames each decoder delivered.
    private static func counts(_ decoded: [Int: DecodedFrame]) -> [DecoderKind: Int] {
        decoded.values.reduce(into: [:]) { $0[$1.decoder, default: 0] += 1 }
    }

    /// Without the ffmpeg fallback the exact request and the earlier-GOP
    /// read still miss frames of this clip (the clip reproduces the
    /// failure), the read recovers at least the frames whose previous
    /// keyframe is the IDR frame, and every frame names the frame it shows.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func openGOPWithoutFallbackIsTruthful() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: false)
        #expect(backend.kind == .avFoundation)
        #expect(backend.info.frameCount == Self.openGOPFrames)
        let decoded = try await decodeAll(backend)
        var inexact: [Int] = []
        var exact: Set<Int> = []
        for (index, frame) in decoded {
            #expect(frame.requestedFrame == index)
            #expect(Self.frameNumber(in: frame.image) == frame.actualFrame, "frame \(index)")
            #expect(frame.decoder != .ffmpeg)
            if frame.isExact { exact.insert(index) } else { inexact.append(index) }
            if frame.decoder == .avFoundationReader { #expect(frame.isExact, "frame \(index)") }
        }
        print("openGOP without ffmpeg: decoders \(Self.counts(decoded)); inexact \(inexact.sorted())")
        #expect(!inexact.isEmpty, "AVFoundation decoded every frame of the open-GOP clip exactly")
        #expect(exact.isSuperset(of: Self.idrStartedFrames), "missed \(Self.idrStartedFrames.subtracting(exact).sorted())")
        #expect(Self.counts(decoded)[.avFoundationReader, default: 0] > 0)
        // A single request takes the same path.
        let read = try await backend.frame(14, maxWidth: 160)
        #expect(read.decoder == .avFoundationReader)
        #expect(read.actualFrame == 14)
        #expect(Self.frameNumber(in: read.image) == 14)
        if let first = inexact.min() {
            let single = try await backend.frame(first, maxWidth: 160)
            #expect(Self.frameNumber(in: single.image) == single.actualFrame)
            #expect(!single.isExact)
        }
    }

    /// With the fallback every frame is exact: the exact request first, then
    /// the earlier-GOP read, then ffmpeg.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func openGOPWithFallbackIsExact() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: true)
        #expect(backend.kind == .avFoundation)
        let decoded = try await decodeAll(backend)
        for (index, frame) in decoded {
            #expect(frame.actualFrame == index, "frame \(index)")
            #expect(Self.frameNumber(in: frame.image) == index, "frame \(index)")
            if Self.idrStartedFrames.contains(index) { #expect(frame.decoder != .ffmpeg, "frame \(index)") }
        }
        let counts = Self.counts(decoded)
        print("openGOP with ffmpeg: decoders \(counts)")
        #expect(counts[.avFoundationReader, default: 0] > 0)
        #expect(counts[.ffmpeg, default: 0] > 0)
        for number in [14, 29, 47] {
            let single = try await backend.frame(number, maxWidth: 160)
            #expect(single.actualFrame == number)
            #expect(Self.frameNumber(in: single.image) == number)
        }
    }

    /// The fallback turns on and off on an open backend (the Settings
    /// toggle keeps movies open): a frame neither AVFoundation step decodes
    /// comes from ffmpeg while it is on, and from the retry after it.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func exactFallbackTogglesOnAnOpenBackend() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let backend = try #require(
            try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: false) as? AVFoundationBackend)
        let decoded = try await decodeAll(backend)
        let number = try #require(decoded.values.filter { !$0.isExact }.map(\.requestedFrame).min())
        backend.setExactFallback(Self.tools)
        let on = try await backend.frame(number, maxWidth: 160)
        #expect(on.decoder == .ffmpeg)
        #expect(on.actualFrame == number)
        #expect(Self.frameNumber(in: on.image) == number)
        backend.setExactFallback(nil)
        let off = try await backend.frame(number, maxWidth: 160)
        #expect(off.decoder != .ffmpeg)
        #expect(!off.isExact)
        #expect(Self.frameNumber(in: off.image) == off.actualFrame)
    }

    /// Presentation time (track time) of a full sync sample before the
    /// frame at `time`, found with a sample cursor stepping back in decode
    /// order: `syncsBack` 1 is the sync sample the frame's decode starts
    /// from (for a leading B frame, the I frame shown after it), 2 the one
    /// before that (one GOP earlier). Sample cursors work in media time, so
    /// times go through the edit's mapping (`offset` = track time − media
    /// time). Nil when the track has no sample cursors; the first sample's
    /// time when there are not enough sync samples.
    static func syncTime(
        _ track: AVAssetTrack, before time: CMTime, syncsBack: Int, offset: CMTime
    ) -> CMTime? {
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time - offset) else { return nil }
        var syncFound = 0
        while true {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                syncFound += 1
                if syncFound == syncsBack { return cursor.presentationTimeStamp + offset }
            }
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { return cursor.presentationTimeStamp + offset }
        }
    }

    /// Track time minus media time of the track's first non-empty edit
    /// (zero without an edit list).
    static func mediaOffset(_ track: AVAssetTrack) async throws -> CMTime {
        let segments = try await track.load(.segments)
        guard let segment = segments.first(where: { !$0.isEmpty }) else { return .zero }
        return segment.timeMapping.target.start - segment.timeMapping.source.start
    }

    struct ReaderRead {
        var image: CGImage?
        /// Presentation times of the frames the reader delivered, in order.
        var delivered: [CMTime] = []
        var error: String?
    }

    /// The frame shown at `target` through an `AVAssetReader` (output
    /// provider API) whose range starts at `start` and ends one frame after
    /// the target, decoding forward; a reader error ends the read and is
    /// kept.
    static func readFrame(
        _ asset: AVURLAsset, _ track: AVAssetTrack, from start: CMTime, target: CMTime,
        frameDuration: CMTime, width: Int, height: Int
    ) async throws -> ReaderRead {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: target + frameDuration)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        let slack = frameDuration.seconds / 4
        var read = ReaderRead()
        do {
            while let sample = try await provider.next() {
                let pts = sample.presentationTimeStamp
                let image: CGImage? = sample.withUnsafeSampleBuffer { buffer in
                    guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
                    var image: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
                    return image
                }
                guard let image else { continue }
                read.delivered.append(pts)
                if abs(pts.seconds - target.seconds) < slack {
                    read.image = image
                    break
                }
                if pts.seconds > target.seconds + slack { break }
            }
        } catch {
            read.error = "\((error as NSError).code)/\(((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0)"
        }
        reader.cancelReading()
        return read
    }

    /// HQ hypothesis (TASK T04b, item 6): the frames an exact
    /// AVAssetImageGenerator request misses come out exactly from an
    /// AVAssetReader that starts one GOP earlier and decodes forward. For
    /// comparison the same read also starts at the frame's own sync sample
    /// and at the start of the movie.
    ///
    /// Found on macOS 27.2 (2026-11-03): the sample cursor reports every
    /// keyframe (0, 16, 32, 48) as a full sync sample, none as partial. The
    /// exact generator misses every frame from 13 on except the keyframes
    /// (48 of 64). A reader starting at a non-IDR keyframe fails with
    /// AVErrorDecodeFailed (-11821, underlying -12137) after at most that
    /// keyframe, so the earlier-GOP read recovers only the GOP whose
    /// previous keyframe is the IDR frame 0 (15 of 48); a reader from the
    /// start of the movie recovers all 48. Kept as the record of the limit
    /// of the backend's step 2 (`EarlierGOPReader`), which is why step 3
    /// (ffmpeg) remains; a known issue, so the test notices when the read
    /// starts to work.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func openGOPEarlierGOPReaderIsExact() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let asset = AVURLAsset(url: clip)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (timeRange, canCursor) = try await track.load(.timeRange, .canProvideSampleCursors)
        #expect(canCursor)
        let offset = try await Self.mediaOffset(track)
        let fps = 24.0
        let frameDuration = CMTime(value: 1, timescale: 24)
        func start(of frame: Int) -> CMTime {
            timeRange.start + CMTime(value: CMTimeValue(frame), timescale: 24)
        }
        func number(_ time: CMTime) -> Int { Int(((time - timeRange.start).seconds * fps).rounded()) }

        // The sync table as the sample cursor reports it.
        if let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            var table: [String] = []
            repeat {
                let sync = cursor.currentSampleSyncInfo
                if sync.sampleIsFullSync.boolValue || sync.sampleIsPartialSync.boolValue {
                    table.append("\(number(cursor.presentationTimeStamp + offset))\(sync.sampleIsFullSync.boolValue ? "F" : "")\(sync.sampleIsPartialSync.boolValue ? "P" : "")")
                }
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
            print("openGOP sync samples (frame, F full / P partial): \(table); edit offset \(offset.seconds) s")
        }

        // Exact generator requests, as the backend makes them (frame middle,
        // zero tolerance); a frame counts as failed when the request throws
        // or the image shows another number.
        var failed: [Int] = []
        for frame in 0..<Self.openGOPFrames {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 160, height: 0)
            let middle = timeRange.start + CMTime(seconds: (Double(frame) + 0.5) / fps, preferredTimescale: 600_000)
            if let result = try? await generator.image(at: middle), Self.frameNumber(in: result.image) == frame {
                continue
            }
            failed.append(frame)
        }
        print("openGOP exact generator failed \(failed.count): \(failed)")

        var recovered: [String: [Int]] = [:]
        var notRecovered: [String: [String]] = [:]
        let variants: [(String, (Int) -> CMTime?)] = [
            ("previous GOP", { Self.syncTime(track, before: start(of: $0), syncsBack: 2, offset: offset) }),
            ("own GOP", { Self.syncTime(track, before: start(of: $0), syncsBack: 1, offset: offset) }),
            ("movie start", { _ in timeRange.start }),
        ]
        for (name, from) in variants {
            for frame in failed {
                let begin = try #require(from(frame))
                let read = try await Self.readFrame(
                    asset, track, from: begin, target: start(of: frame), frameDuration: frameDuration,
                    width: 160, height: 90)
                if let image = read.image, Self.frameNumber(in: image) == frame {
                    recovered[name, default: []].append(frame)
                } else {
                    let got = read.image.map { "\(Self.frameNumber(in: $0))" } ?? "none"
                    notRecovered[name, default: []].append(
                        "\(frame)->\(got) from \(number(begin)), read \(read.delivered.map(number)), error \(read.error ?? "-")")
                }
            }
            print("openGOP reader from \(name): recovered \(recovered[name]?.count ?? 0) of \(failed.count); not recovered \(notRecovered[name] ?? [])")
        }
        #expect(!failed.isEmpty, "the exact generator decoded every frame of the open-GOP clip")
        #expect(notRecovered["movie start"] == nil, "a read from the start missed \(notRecovered["movie start"] ?? [])")
        withKnownIssue("a reader starting at a non-IDR keyframe fails to decode (-11821/-12137)") {
            #expect(notRecovered["previous GOP"] == nil, "earlier-GOP read missed \(notRecovered["previous GOP"] ?? [])")
        }
    }

    /// The ffmpeg path is frame-exact on the open-GOP clip, leading frames
    /// included (a seek to the frame itself returned frame 16 for 14).
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func ffmpegIsExactOnOpenGOP() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let backend = try await FFmpegBackend.open(clip, tools: try #require(Self.tools))
        #expect(backend.info.frameCount == Self.openGOPFrames)
        let decoded = try await decodeAll(backend)
        for (index, frame) in decoded {
            #expect(frame.actualFrame == index, "frame \(index)")
            #expect(Self.frameNumber(in: frame.image) == index, "frame \(index)")
        }
    }

    @Test func ffmpegLogParsing() {
        let log = """
            [info] Stream mapping:
            [h264 @ 0x1] [error] mmco: unref short failure
            [Parsed_showinfo_1 @ 0x2] [info] config in time_base: 1/12288, frame_rate: 24/1
            [Parsed_showinfo_1 @ 0x2] [info] n:   0 pts:   8704 pts_time:0.708333 duration:    512
            [Parsed_showinfo_1 @ 0x2] [info] n:   1 pts:   9216 pts_time:0.75    duration:    512
            """
        let parsed = FFmpegBackend.parseLog(log)
        #expect(parsed.pts == 0.708333)
        #expect(parsed.error == "mmco: unref short failure")
        #expect(FFmpegBackend.parseLog("[info] nothing").pts == nil)
    }

    // MARK: Frame runs (the player's frame strip, §9)

    /// A run's results by frame; each names the frame its image shows.
    private func run(
        _ backend: any DecodeBackend, _ range: ClosedRange<Int>
    ) async throws -> [Int: DecodedFrame] {
        var decoded: [Int: DecodedFrame] = [:]
        for await result in backend.frameRun(range, maxWidth: 160) {
            let frame = try result.result.get()
            #expect(result.index == result.frameNumber - range.lowerBound)
            #expect(frame.requestedFrame == result.frameNumber)
            #expect(Self.frameNumber(in: frame.image) == frame.actualFrame, "frame \(result.frameNumber)")
            #expect(frame.image.width == 160)
            decoded[result.frameNumber] = frame
        }
        #expect(Set(decoded.keys) == Set(range), "missing \(Set(range).subtracting(decoded.keys).sorted())")
        return decoded
    }

    /// A closed-GOP movie: the whole run from the one sequential read.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func frameRunReadsOnePass() async throws {
        let clip = try await Self.makeClip("run.mp4", ["-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p"])
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools)
        let decoded = try await withDeadline("frame run") { try await run(backend, 20...39) }
        for (number, frame) in decoded {
            #expect(frame.isExact, "frame \(number)")
            #expect(frame.decoder == .avFoundationReader, "frame \(number)")
        }
        // The ends of the movie: the range is kept inside it.
        let ends = try await withDeadline("frame run at the end") { try await run(backend, 45...49) }
        #expect(ends.values.allSatisfy { $0.isExact })
    }

    /// The open-GOP clip: with the ffmpeg fallback every frame of a run
    /// across leading frames is exact; without it every frame names the
    /// frame it shows.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func frameRunOnOpenGOP() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let exact = try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: true)
        let decoded = try await withDeadline("open-GOP run") { try await run(exact, 26...49) }
        for (number, frame) in decoded {
            #expect(frame.actualFrame == number, "frame \(number)")
        }
        print("openGOP run with ffmpeg: decoders \(Self.counts(decoded))")
        let truthful = try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: false)
        let shown = try await withDeadline("open-GOP run without ffmpeg") { try await run(truthful, 26...49) }
        #expect(shown.values.allSatisfy { $0.decoder != .ffmpeg })
        print("openGOP run without ffmpeg: inexact \(shown.values.filter { !$0.isExact }.map(\.requestedFrame).sorted())")
    }

    /// The later steps of a run: with no closed GOP allowed before it, the
    /// read of 40–49 starts at the non-IDR keyframe 16 and stops; ffmpeg
    /// (fallback on) delivers the frames exactly in one run, and without it
    /// the single-frame steps name the frames they show.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func frameRunFallsBackOnOpenGOP() async throws {
        let clip = try await Self.makeOpenGOPClip()
        let range = 40...49
        func collect(_ backend: AVFoundationBackend) async throws -> [Int: DecodedFrame] {
            var decoded: [Int: DecodedFrame] = [:]
            for await result in backend.frameRun(range, maxWidth: 160, preRoll: .zero) {
                let frame = try result.result.get()
                #expect(Self.frameNumber(in: frame.image) == frame.actualFrame, "frame \(result.frameNumber)")
                decoded[result.frameNumber] = frame
            }
            #expect(Set(decoded.keys) == Set(range))
            return decoded
        }
        let exact = try #require(
            try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: true) as? AVFoundationBackend)
        let withFFmpeg = try await withDeadline("open-GOP run, ffmpeg") { try await collect(exact) }
        #expect(withFFmpeg.values.allSatisfy { $0.isExact })
        print("openGOP short pre-roll with ffmpeg: decoders \(Self.counts(withFFmpeg))")
        #expect(Self.counts(withFFmpeg)[.ffmpeg, default: 0] > 0)
        let truthful = try #require(
            try await DecoderRouter.open(clip, ffmpeg: Self.tools, exactFallback: false) as? AVFoundationBackend)
        let without = try await withDeadline("open-GOP run, no ffmpeg") { try await collect(truthful) }
        #expect(without.values.allSatisfy { $0.decoder != .ffmpeg })
        #expect(without.values.contains { !$0.isExact })
    }

    /// ffmpeg-routed files: one rawvideo run, each frame named by its time.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func frameRunOnTheFFmpegPath() async throws {
        let clip = try await Self.makeClip("run.mkv", ["-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p"])
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools)
        #expect(backend.kind == .ffmpeg)
        let decoded = try await withDeadline("ffmpeg run") { try await run(backend, 5...24) }
        for (number, frame) in decoded {
            #expect(frame.actualFrame == number, "frame \(number)")
            #expect(frame.decoder == .ffmpeg)
        }
    }

    /// Playback that starts on a leading frame of an open GOP shows frames
    /// from its keyframe on; elsewhere, and in closed-GOP movies, from the
    /// frame itself.
    @Test(.enabled(if: DecodeIntegrationTests.tools != nil)) func firstPlayableFrame() async throws {
        let open = try #require(
            try await DecoderRouter.open(try await Self.makeOpenGOPClip(), ffmpeg: Self.tools) as? AVFoundationBackend)
        #expect(await open.firstPlayableFrame(from: 13) == 16)
        #expect(await open.firstPlayableFrame(from: 15) == 16)
        #expect(await open.firstPlayableFrame(from: 16) == 16)
        #expect(await open.firstPlayableFrame(from: 20) == 20)
        let clip = try await Self.makeClip("closed.mp4", ["-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p"])
        let closed = try #require(try await DecoderRouter.open(clip, ffmpeg: Self.tools) as? AVFoundationBackend)
        #expect(await closed.firstPlayableFrame(from: 13) == 13)
    }

    @Test func showinfoTimesInOrder() {
        let log = """
            [Parsed_showinfo_1 @ 0x2] [info] config in time_base: 1/12288, frame_rate: 24/1
            [Parsed_showinfo_1 @ 0x2] [info] n:   0 pts:   8704 pts_time:0.708333 duration:    512
            [h264 @ 0x1] [error] mmco: unref short failure
            [Parsed_showinfo_1 @ 0x2] [info] n:   1 pts:   9216 pts_time:0.75    duration:    512
            """
        #expect(FFmpegBackend.showinfoTimes(log) == [0.708333, 0.75])
    }

    @Test func mkvWithoutFFmpegExplains() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-a-movie-\(UUID()).mkv")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: DecodeError.self) { try await DecoderRouter.open(url, ffmpeg: nil) }
    }
}

@Suite struct ThumbnailCacheTests {
    @Test func storesAndLimits() throws {
        let cache = ThumbnailCache(limitMB: 256)
        #expect(cache.limitBytes == 256 * 1024 * 1024)
        let context = CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try #require(context.makeImage())
        let id = UUID()
        cache.insert(image, file: id, frame: 3, width: 64)
        #expect(cache.image(file: id, frame: 3, width: 64) != nil)
        #expect(cache.image(file: id, frame: 4, width: 64) == nil)
        cache.removeAll()
        #expect(cache.image(file: id, frame: 3, width: 64) == nil)
    }

    /// Images stay until the limit is passed; then the least recently used
    /// go first. One image can be dropped on its own.
    @Test func evictsLeastRecentlyUsedOnlyPastTheLimit() throws {
        let cache = ThumbnailCache(limitMB: 1)
        let context = CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try #require(context.makeImage())
        #expect(ThumbnailCache.cost(of: image) == 256 * 1024)
        let id = UUID()
        for frame in 0..<4 { cache.insert(image, file: id, frame: frame, width: 256) }
        #expect(cache.totalBytes == 1024 * 1024)
        #expect((0..<4).allSatisfy { cache.image(file: id, frame: $0, width: 256) != nil })
        // Frame 0 is used again, so frame 1 is now the oldest.
        _ = cache.image(file: id, frame: 0, width: 256)
        cache.insert(image, file: id, frame: 4, width: 256)
        #expect(cache.image(file: id, frame: 1, width: 256) == nil)
        #expect([0, 2, 3, 4].allSatisfy { cache.image(file: id, frame: $0, width: 256) != nil })
        #expect(cache.totalBytes == 1024 * 1024)
        cache.remove(file: id, frame: 2, width: 256)
        #expect(cache.image(file: id, frame: 2, width: 256) == nil)
        #expect(cache.totalBytes == 768 * 1024)
        // Re-inserting a key replaces its cost instead of adding to it.
        cache.insert(image, file: id, frame: 3, width: 256)
        #expect(cache.totalBytes == 768 * 1024)
    }
}
