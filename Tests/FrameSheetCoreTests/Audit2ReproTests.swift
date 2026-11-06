import CoreGraphics
import Foundation
import Testing
@testable import FrameSheetCore

// The second pre-release audit (2026-11-06): reproductions that use only
// what the audited code already had, run once on it before the fixes.

private func movie(frames: Int = 1000) -> MovieFile {
    MovieFile(
        url: URL(filePath: "/movies/a.mov"), duration: Double(frames) / 25, frameCount: frames, fps: 25,
        width: 1920, height: 1080, size: 0, fourCC: "avc1")
}

private func importJSON(_ json: String) throws -> (Library, MovieFile, Sheet) {
    var library = Library()
    let ref = try library.importSheet(SheetExchange(json: Data(json.utf8)))
    library.applyProbe(ref.fileId, info: MediaInfo(
        duration: 40, frameCount: 1000, fps: 25, width: 1920, height: 1080, fourCC: "avc1", size: 0))
    let file = try #require(library.file(ref.fileId))
    let sheet = try #require(library.sheet(ref.sheetId, of: ref.fileId))
    return (library, file, sheet)
}

// MARK: - A3. Imported numbers through layout and save planning

@Suite struct ImportedSheetLayoutTests {
    /// Saving the imported one-thumb grid plans a print (in a child process:
    /// before the fix the plan's height conversion trapped).
    @Test func extremeAspectRatioPlansAPrint() async {
        await #expect(processExitsWith: .success) {
            var library = Library()
            let ref = try library.importSheet(SheetExchange(json: Data(
                #"{"filePath": "/m/a.mov", "transformObject": {"aspectRatioInv": 1e100}, "frameNumberArray": [1]}"#.utf8)))
            library.applyProbe(ref.fileId, info: MediaInfo(
                duration: 40, frameCount: 1000, fps: 25, width: 1920, height: 1080, fourCC: "avc1", size: 0))
            let file = library.file(ref.fileId)!
            let sheet = library.sheet(ref.sheetId, of: ref.fileId)!
            let plan = PrintOutput.Plan(file: file, sheet: sheet, settings: Settings())
            if plan.width < 1 || plan.height < 1 || plan.height > 1_000_000 { exit(1) }
        }
    }

    /// A column count of 2147483647 made the grid ask for that many cells.
    @Test func columnCountStaysInRange() throws {
        let (_, file, sheet) = try importJSON(
            #"{"filePath": "/m/a.mov", "columnCount": 2147483647, "frameNumberArray": [1]}"#)
        #expect(sheet.columnCount <= 100)
        let plan = PrintOutput.Plan(file: file, sheet: sheet, settings: Settings())
        #expect(plan.width <= 16384 && plan.height <= 16384)
    }

    @Test func colorsAndScenesStayInRange() throws {
        let (_, _, sheet) = try importJSON(
            #"{"filePath": "/m/a.mov", "sceneArray": [{"start": 0, "length": 10, "colorArray": [300, -5, 7]}, {"start": -20, "length": 5}, {"start": 10, "length": 0}]}"#)
        #expect(sheet.scenes.count == 1)
        #expect(sheet.scenes.first?.colorRGB == [255, 0, 7])
    }

    @Test func negativeFramesAreLeftOut() throws {
        let (_, _, sheet) = try importJSON(#"{"filePath": "/m/a.mov", "frameNumberArray": [-3, 4]}"#)
        #expect(sheet.thumbs.map(\.frameNumber) == [4])
    }
}

// MARK: - B10. Replacing a shot movie with a shorter one

@Suite struct ShorterReplacementTests {
    @Test func scenesEndInsideTheNewMovie() {
        var library = Library()
        let file = movie(frames: 1000)
        library.files = [file]
        let thumbs = [Thumb(frameNumber: 250, index: 0), Thumb(frameNumber: 750, index: 1)]
        library.sheets[file.id] = [Sheet(name: "Shots", type: .shot, thumbs: thumbs, scenes: [
            Scene(id: thumbs[0].id, start: 0, length: 500, colorRGB: [1, 2, 3]),
            Scene(id: thumbs[1].id, start: 500, length: 500, colorRGB: [4, 5, 6]),
        ])]
        library.applyProbe(file.id, info: MediaInfo(
            duration: 4, frameCount: 100, fps: 25, width: 1920, height: 1080, fourCC: "avc1", size: 0))
        let sheet = library.sheets[file.id]![0]
        #expect(sheet.scenes.map(\.start) == [0])
        #expect(sheet.scenes.map(\.length) == [100])
        #expect(sheet.thumbs.map(\.id) == [thumbs[0].id])
        #expect(sheet.thumbs.allSatisfy { $0.frameNumber < 100 })
    }
}

// MARK: - C. A child that keeps the pipes open

@Suite struct DescendantPipeTests {
    /// The shell exits at once; the `sleep` it left keeps stdout open.
    @Test func runEndsWhenTheProcessDoes() async throws {
        let started = ContinuousClock.now
        let result = try await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "sleep 20 & echo hi"])
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(result.stdoutText == "hi\n")
    }
}

// MARK: - B4, B5. ffmpeg: one video stream, one buffer per timestamp

@Suite(.serialized, .timeLimit(.minutes(1))) struct FFmpegStreamTests {
    static var tools: FFmpegTools? { DecodeIntegrationTests.tools }

    private static func make(_ name: String, _ arguments: [String]) async throws -> URL {
        let tools = try #require(tools)
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetAudit2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let result = try await ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"]
            + arguments + [url.path])
        #expect(result.status == 0, "\(result.stderrText)")
        return url
    }

    /// The center pixel's red and blue, 0–255.
    private static func center(_ image: CGImage) -> (red: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[2]))
    }

    /// Track 1 red and small, track 2 blue, larger and the default one:
    /// without `-map` ffmpeg picks track 2 (0,0,255 against 254,0,0 with
    /// `-map 0:v:0`, checked with the CLI on 2026-11-06).
    @Test(.enabled(if: FFmpegStreamTests.tools != nil)) func everyExtractionReadsTheFirstTrack() async throws {
        let url = try await Self.make("two-tracks.mkv", [
            "-f", "lavfi", "-i", "color=red:s=160x90:r=25:d=2",
            "-f", "lavfi", "-i", "color=blue:s=320x180:r=25:d=2",
            "-map", "0", "-map", "1", "-disposition:v:0", "0", "-disposition:v:1", "default",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
        ])
        let backend = try await FFmpegBackend.open(url, tools: try #require(Self.tools))
        let single = Self.center(try await backend.frame(10, maxWidth: 160).image)
        #expect(single.red > 200 && single.blue < 60, "single frame: \(single)")
        let run = try await backend.runFrames(10...12, maxWidth: 160)
        let strip = try Self.center(#require(run.first).image)
        #expect(strip.red > 200 && strip.blue < 60, "frame run: \(strip)")
    }

    /// Frames at 0, 0.04, 0.08 s, then 0.40, 0.44, 0.48 s: six frames, each
    /// named by its own timestamp (constant-rate output added duplicates).
    @Test(.enabled(if: FFmpegStreamTests.tools != nil)) func framesPairWithTheirTimestamps() async throws {
        let url = try await Self.make("gap.mkv", [
            "-f", "lavfi", "-i", "testsrc=s=160x90:r=25:d=0.24",
            "-vf", "setpts='if(lt(N,3),N,N+7)/25/TB'", "-fps_mode", "vfr",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
        ])
        let backend = try await FFmpegBackend.open(url, tools: try #require(Self.tools))
        let frames = try await backend.runFrames(0...14, maxWidth: 160)
        #expect(frames.map(\.actualFrame) == [0, 1, 2, 10, 11, 12])
    }
}
