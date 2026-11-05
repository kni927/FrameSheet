import CoreGraphics
import Foundation
import Testing
@testable import FrameSheetCore

// The v3.0.0 pre-release audit (2026-11-05): one test per finding that a
// core test can reach, written to fail on the code the audit read.

// MARK: - 1. A library that could not be read is not overwritten

@Suite struct LibraryLoadFailureTests {
    private func unreadableLibrary() throws -> (URL, Data) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetLibrary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "library.json")
        let bytes = Data("{\"files\": [ not json".utf8)
        try bytes.write(to: url)
        return (url, bytes)
    }

    /// The app's sequence: the load fails, the app goes on with an empty
    /// library, and quitting saves what it holds. (Before the fix the app
    /// called `LibraryStore.save` here and the file was replaced.)
    @Test func failedLoadKeepsTheFile() throws {
        let (url, bytes) = try unreadableLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var persistence = LibraryPersistence(store: LibraryStore(url: url))
        let loaded = persistence.load()
        #expect(loaded.error != nil)
        #expect(loaded.library.files.isEmpty)
        #expect(try persistence.save(Library()) == false)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func readableLibraryIsSaved() throws {
        let (url, _) = try unreadableLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        var persistence = LibraryPersistence(store: LibraryStore(url: url))
        #expect(persistence.load().error == nil)
        #expect(try persistence.save(Library()) == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - 2. Cancelling a process that ignores SIGTERM

@Suite struct ProcessTerminationTests {
    /// A process that ignores SIGTERM and writes nothing for 20 s.
    static let stubborn = (URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; exec sleep 20"])

    @Test func cancelledRunEnds() async {
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(Self.stubborn.0, Self.stubborn.1) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func timedOutRunEnds() async throws {
        let started = ContinuousClock.now
        let result = try await ProcessRunner.run(Self.stubborn.0, Self.stubborn.1, timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func cancelledPipeReadEnds() async throws {
        let pipe = RawVideoPipe(executable: Self.stubborn.0, arguments: Self.stubborn.1)
        try pipe.start()
        let started = ContinuousClock.now
        let task = Task {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
            defer { buffer.deallocate() }
            return try await pipe.readFrame(into: buffer, count: 64)
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        _ = await pipe.finish()
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

// MARK: - 5. Duplicating a shot sheet keeps its scenes

@Suite struct DuplicateShotSheetTests {
    @Test func scenesAreCopiedWithTheNewThumbIds() throws {
        var library = Library()
        let file = MovieFile(
            url: URL(filePath: "/movies/a.mov"), duration: 4, frameCount: 100, fps: 25, width: 64, height: 36,
            size: 0, fourCC: "test")
        library.files = [file]
        let thumbs = [Thumb(frameNumber: 0, index: 0), Thumb(frameNumber: 40, index: 1), Thumb(frameNumber: 90, index: 2)]
        let scenes = [
            Scene(id: thumbs[0].id, start: 0, length: 40, colorRGB: [1, 2, 3]),
            Scene(id: thumbs[1].id, start: 40, length: 50, colorRGB: [4, 5, 6], hidden: true),
            Scene(id: thumbs[2].id, start: 90, length: 10, colorRGB: [7, 8, 9]),
        ]
        var sheet = Sheet(name: "Shots", type: .shot, columnCount: 3, thumbs: thumbs)
        sheet.scenes = scenes
        library.sheets[file.id] = [sheet]
        let ref = SheetRef(fileId: file.id, sheetId: sheet.id)

        let duplicated = library.duplicateSheet(ref)
        let copyRef = try #require(duplicated)
        let copy = try #require(library.sheet(copyRef.sheetId, of: copyRef.fileId))
        #expect(copy.scenes.map(\.start) == [0, 40, 90])
        #expect(copy.scenes.map(\.length) == [40, 50, 10])
        #expect(copy.scenes.map(\.hidden) == [false, true, false])
        #expect(copy.scenes.map(\.colorRGB) == scenes.map(\.colorRGB))
        #expect(copy.scenes.map(\.id) == copy.thumbs.map(\.id))
        #expect(Set(copy.scenes.map(\.id)).isDisjoint(with: scenes.map(\.id)))
    }
}

// MARK: - 6. "These thumbs" face scans analyze only exact frames

/// Returns another frame (the ±0.5 s retry's) for the frames in `shifted`.
private struct ShiftingBackend: DecodeBackend {
    let shifted: Set<Int>
    let kind = DecoderKind.avFoundation
    let info = MediaInfo(duration: 4, frameCount: 100, fps: 25, width: 64, height: 36, fourCC: "test", size: 0)

    static let image: CGImage = {
        let context = CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return context.makeImage()!
    }()

    func frame(_ frameNumber: Int, maxWidth: Int) async throws -> DecodedFrame {
        let actual = shifted.contains(frameNumber) ? frameNumber + 3 : frameNumber
        return DecodedFrame(
            image: Self.image, requestedFrame: frameNumber, actualFrame: actual, retried: actual != frameNumber)
    }

    func frames(_ frameNumbers: [Int], maxWidth: Int) -> AsyncStream<FrameResult> {
        concurrentFrames(frameNumbers, maxWidth: maxWidth, concurrency: 1)
    }

    func frameRun(_ range: ClosedRange<Int>, maxWidth: Int) -> AsyncStream<FrameResult> {
        AsyncStream { $0.finish() }
    }
}

/// Counts its calls; finds no face.
private final class CountingAnalyzer: FaceAnalyzer, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    func detect(in frame: BGRAFrame) async throws -> [DetectedFace] {
        lock.withLock { calls += 1 }
        return []
    }
    func detect(in image: CGImage) async throws -> [DetectedFace] {
        lock.withLock { calls += 1 }
        return []
    }
    func warmUp() async {}
}

@Suite struct SingleFrameFaceScanTests {
    @Test func inexactFramesStayUnanalyzed() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetAuditFaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let analyzer = CountingAnalyzer()
        let request = FaceScanRequest(
            fileId: UUID(), url: URL(filePath: "/movies/a.mov"), frames: [10, 20], thresholds: FaceThresholds(),
            analyzer: analyzer, ffmpeg: nil, singleFrames: ShiftingBackend(shifted: [10]),
            faceStore: FaceCacheStore(directory: dir), scanStore: nil, method: .mean, shotThreshold: 6)
        var analyzed: [Int]?
        for await event in FaceScanner.scan(request) {
            switch event {
            case .finished(let data, _), .cancelled(let data, _), .failed(_, let data):
                analyzed = Array(data.analyzed)
            default:
                break
            }
        }
        #expect(analyzed == [20])
        #expect(analyzer.callCount == 1)
    }
}

// MARK: - 11. Imported numbers out of range do not crash

@Suite struct ImportNumberRangeTests {
    @Test func hugeFrameNumbersInJSON() async {
        await #expect(processExitsWith: .success) {
            _ = try? SheetExchange(json: Data(#"{"columnCount": 4, "frameNumberArray": [1e100, 5]}"#.utf8))
        }
    }

    @Test func hugeSceneValuesInJSON() async {
        await #expect(processExitsWith: .success) {
            _ = try? SheetExchange(json: Data(
                #"{"sceneArray": [{"start": 1e300, "length": 1e300, "colorArray": [1e300, 0, 0]}]}"#.utf8))
        }
    }

    @Test func hugeValuesInPNGText() async {
        await #expect(processExitsWith: .success) {
            _ = SheetExchange(pngText: ["columnCount": "1e100", "frameNumberArray": "[1e100]"])
        }
    }

    /// In a child process, so the crash before the fix fails this test
    /// instead of ending the test run.
    @Test func outOfRangeValuesAreLeftOut() async {
        await #expect(processExitsWith: .success) {
            let data = try SheetExchange(json: Data(#"{"columnCount": 4, "frameNumberArray": [1e100, 5, 7.4]}"#.utf8))
            if data.frameNumbers != [5, 7] { exit(1) }
        }
    }
}

// MARK: - 15. A last long scene adds no empty timeline row

@Suite struct TimelineLastRowTests {
    @Test func lastLongSceneAddsNoEmptyRow() {
        let rows = TimelineLayout.scenesInRows(lengths: [200, 300], framesPerRow: 100)
        #expect(rows.map(\.sceneLengths) == [[200], [300]])
    }
}

// MARK: - 16. "Overwrite off" never overwrites

@Suite struct OutputNameCollisionTests {
    @Test func takenEditNamesGoOn() {
        let folder = URL(filePath: "/out")
        let url = FileNaming.outputURL(
            folder: folder, baseName: "film", fileExtension: "png", overwrite: false,
            exists: { url in
                let name = url.deletingPathExtension().lastPathComponent
                guard name != "film" else { return true }
                return Int(name.replacingOccurrences(of: "film edit ", with: "")).map { $0 <= 999 } ?? false
            })
        #expect(url.lastPathComponent == "film edit 1000.png")
    }
}
