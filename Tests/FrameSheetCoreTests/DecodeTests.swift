import CoreGraphics
import Foundation
import Testing
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
/// stripes (bit 0 on the left), which survive scaling and colour
/// conversion, so the decoded image tells which frame came back.
@Suite(.serialized) struct DecodeIntegrationTests {
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

    private static func makeClip(_ name: String, _ codecArgs: [String]) async throws -> URL {
        let tools = try #require(Self.tools)
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetClips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let result = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=320x180:r=25:d=2,format=yuv420p,geq=lum='16+219*mod(floor(N/pow(2,floor(X*6/W))),2)':cb=128:cr=128",
            "-frames:v", "\(frameCount)",
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
}
