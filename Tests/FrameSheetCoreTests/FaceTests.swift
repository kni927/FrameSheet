import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import FrameSheetCore

// Faces, Lv1 (T07): thresholds, the face cache, scopes, sort and filter,
// faces sheets, and the face scan through the scan pass with a stub
// analyzer. No face images are committed: Vision itself is checked on a
// blank frame (a face drawn with CoreGraphics, an oval with eyes, brows,
// nose and mouth, was not detected by revision 4, so it is not a test).

/// Returns the same faces for every frame and records the calls.
private final class StubAnalyzer: FaceAnalyzer {
    let faces: [DetectedFace]
    private let calls = Mutex(0)

    init(_ faces: [DetectedFace] = [DetectedFace(confidence: 0.9, box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3))]) {
        self.faces = faces
    }

    var callCount: Int { calls.withLock { $0 } }

    func detect(in frame: BGRAFrame) async throws -> [DetectedFace] {
        calls.withLock { $0 += 1 }
        return faces
    }

    func detect(in image: CGImage) async throws -> [DetectedFace] {
        calls.withLock { $0 += 1 }
        return faces
    }

    func warmUp() async {}
}

/// Takes `delay` per frame and records the frame numbers it was given (the
/// first four bytes of a frame) in call order, and how many frames the
/// collector had queued at most.
private final class SlowAnalyzer: FaceAnalyzer {
    let delay: Duration
    private let state = Mutex<(order: [Int], running: Int, maxRunning: Int)>(([], 0, 0))

    init(delay: Duration) {
        self.delay = delay
    }

    var order: [Int] { state.withLock { $0.order } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    func detect(in frame: BGRAFrame) async throws -> [DetectedFace] {
        let number = Int(frame.base.loadUnaligned(as: UInt32.self))
        state.withLock {
            $0.running += 1
            $0.maxRunning = max($0.maxRunning, $0.running)
        }
        defer { state.withLock { $0.running -= 1 } }
        try await Task.sleep(for: delay)
        state.withLock { $0.order.append(number) }
        return number % 20 == 0 ? [DetectedFace(confidence: 0.9, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3))] : []
    }

    func detect(in image: CGImage) async throws -> [DetectedFace] { [] }

    func warmUp() async {}
}

private func face(_ size: Double, confidence: Double = 90) -> Face {
    Face(confidence: confidence, size: size, x: 0.1, y: 0.1, width: size / 200, height: size / 100)
}

/// A library with one 1000-frame movie and a faces sheet of `faces` per
/// frame (frame numbers 100, 200, …).
private func facesFixture(_ faces: [[Face]]) -> (Library, SheetRef) {
    var library = Library()
    let file = MovieFile(
        url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
        width: 1920, height: 1080, size: 1, fourCC: "avc1")
    library.files.append(file)
    let thumbs = faces.enumerated().map { Thumb(frameNumber: ($0 + 1) * 100, index: $0, faces: $1) }
    let sheet = library.addSheet(to: file.id, type: .faces, thumbs: thumbs)!
    return (library, SheetRef(fileId: file.id, sheetId: sheet.id))
}

private extension Library {
    func faceSheet(_ ref: SheetRef) -> Sheet { sheet(ref.sheetId, of: ref.fileId)! }
    func shownFrames(_ ref: SheetRef) -> [Int] { faceSheet(ref).visibleThumbs.map(\.frameNumber) }
}

@Suite struct FaceDetectionTests {
    @Test func thresholdsAppliedWhenScanned() {
        let detected = [
            DetectedFace(confidence: 0.904, box: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.204)),
            DetectedFace(confidence: 0.695, box: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.4)),
            DetectedFace(confidence: 0.95, box: CGRect(x: 0.7, y: 0.7, width: 0.05, height: 0.094)),
            DetectedFace(confidence: 0.70, box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.6)),
        ]
        let frame = FaceDetection.frame(42, detected: detected, thresholds: FaceThresholds())
        // 69.5 % rounds to 70 and passes; 9.4 % is below 10 % and drops.
        #expect(frame.frameNumber == 42)
        #expect(frame.faceCount == 3)
        #expect(frame.faces.map(\.size) == [60, 40, 20])
        #expect(frame.faces.map(\.confidence) == [70, 70, 90])
        #expect(frame.largestSize == 60)
        #expect(frame.faces[2].height == 0.204)

        let strict = FaceDetection.frame(42, detected: detected, thresholds: FaceThresholds(confidence: 90, size: 50))
        #expect(strict.faceCount == 0 && strict.largestSize == 0)
    }

    @Test func settingsDefaultsAndClamps() throws {
        let settings = Settings()
        #expect(settings.faceThresholds == FaceThresholds(confidence: 70, size: 10))
        #expect(settings.showFaceRectangles && !settings.includeFaceRectanglesInPrint)
        let decoded = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"faceConfidenceThreshold": 150, "faceSizeThreshold": 25}"#.utf8))
        #expect(decoded.faceConfidenceThreshold == 100 && decoded.faceSizeThreshold == 25)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.faceThresholds == FaceThresholds())
    }

    @Test func changingAThumbsFrameDropsItsFaces() {
        var (library, ref) = facesFixture([[face(40)]])
        let id = library.faceSheet(ref).thumbs[0].id
        library.changeThumb(ref, thumb: id, to: 100)
        #expect(library.faceSheet(ref).thumbs[0].faces.count == 1)
        library.changeThumb(ref, thumb: id, to: 150)
        #expect(library.faceSheet(ref).thumbs[0].faces.isEmpty)
    }
}

@Suite struct FaceCacheTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetFaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FaceCacheStore(directory: dir)
        let id = UUID()
        #expect(try store.load(id) == nil)
        var data = FaceData(thresholds: FaceThresholds(confidence: 60, size: 15))
        data.record(FaceFrame(frameNumber: 30, faces: [face(20), face(45, confidence: 80)]))
        data.record(FaceFrame(frameNumber: 10, faces: []))
        #expect(data.isAnalyzed(10) && data.isAnalyzed(30) && !data.isAnalyzed(20))
        #expect(data.frame(10)?.faceCount == 0)
        #expect(data.frame(20) == nil)
        #expect(data.frame(30)?.largestSize == 45)
        #expect(data.missing([0, 10, 20, 30]) == [0, 20])
        try store.save(data, for: id)
        #expect(try store.load(id) == data)
        #expect(store.url(for: id).lastPathComponent == "\(id.uuidString).fsfaces")
        store.delete(id)
        #expect(try store.load(id) == nil)
    }

    @Test func unknownVersionThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetFaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FaceCacheStore(directory: dir)
        let id = UUID()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "thresholds": {"confidence": 70, "size": 10}, "analyzed": [], "frames": []}"#.utf8)
            .write(to: store.url(for: id))
        #expect(throws: (any Error).self) { try store.load(id) }
    }
}

@Suite struct FaceScopeTests {
    @Test func everyTenthAndHundredthBetweenTheThumbs() {
        let thumbs = [600, 100, 1100, 350]
        let tenth = FaceScanScope.everyTenth.frames(thumbFrames: thumbs, frameCount: 2000)
        // round(1000 × 0.1) = 100 frames from 100 to 1100.
        #expect(tenth.count == 100)
        #expect(tenth.first == 100 && tenth.last == 1100)
        #expect(zip(tenth, tenth.dropFirst()).allSatisfy { (10...11).contains($1 - $0) })
        let hundredth = FaceScanScope.everyHundredth.frames(thumbFrames: thumbs, frameCount: 2000)
        #expect(hundredth == [100, 211, 322, 433, 544, 656, 767, 878, 989, 1100])
    }

    @Test func theseThumbs() {
        let frames = FaceScanScope.thumbs.frames(thumbFrames: [600, 100, 600, 1100, 5000], frameCount: 2000)
        #expect(frames == [100, 600, 1100])
    }

    @Test func edgeCases() {
        #expect(FaceScanScope.everyTenth.frames(thumbFrames: [], frameCount: 2000).isEmpty)
        // One thumb: that frame (MoviePrint's interval array would give 0).
        #expect(FaceScanScope.everyTenth.frames(thumbFrames: [500], frameCount: 2000) == [500])
        #expect(FaceScanScope.everyHundredth.frames(thumbFrames: [500, 520], frameCount: 2000) == [500])
    }

    @Test func ffmpegDefaultsToEveryHundredth() {
        #expect(FaceScanScope.defaultScope(for: .avFoundation) == .everyTenth)
        #expect(FaceScanScope.defaultScope(for: .ffmpeg) == .everyHundredth)
    }
}

@Suite struct FaceSortFilterTests {
    /// Frames 100…500: sizes and face counts differ; 400 has no faces.
    private func fixture() -> (Library, SheetRef) {
        facesFixture([
            [face(30, confidence: 95)],
            [face(60, confidence: 72), face(20, confidence: 99), face(15)],
            [face(45, confidence: 80), face(55, confidence: 75)],
            [],
            [face(80, confidence: 71)],
        ])
    }

    @Test func sortsLikeMoviePrint() {
        var (library, ref) = fixture()
        library.sortThumbs(ref, by: .faceSize, includeHidden: false)
        #expect(library.shownFrames(ref) == [500, 200, 300, 100])
        // The frame without faces is hidden and goes to the end.
        #expect(library.faceSheet(ref).thumbs.last?.frameNumber == 400)
        #expect(library.faceSheet(ref).thumbs.last?.hidden == true)
        #expect(library.faceSheet(ref).thumbs.map(\.index) == Array(0..<5))
        #expect(library.faceSheet(ref).columnCount == 2)

        library.sortThumbs(ref, by: .faceConfidence, includeHidden: false)
        #expect(library.shownFrames(ref) == [200, 100, 300, 500])
        library.sortThumbs(ref, by: .faceCount, includeHidden: false)
        #expect(library.shownFrames(ref) == [200, 300, 100, 500])
        library.sortThumbs(ref, by: .frameNumber, includeHidden: false)
        #expect(library.shownFrames(ref) == [100, 200, 300, 500])
        library.sortThumbs(ref, by: .reverse, includeHidden: false)
        #expect(library.faceSheet(ref).thumbs.map(\.frameNumber) == [400, 500, 300, 200, 100])
        // With Show hidden thumbs, the frame sort takes the hidden one too.
        library.sortThumbs(ref, by: .frameNumber, includeHidden: true)
        #expect(library.shownFrames(ref) == [100, 200, 300, 400, 500])
    }

    @Test func filterHidesThumbsWithoutPassingFaces() {
        var (library, ref) = fixture()
        var filter = FaceFilter()
        #expect(!filter.isActive)
        #expect(filter.faceCount == FaceRangeFilter(enabled: false, lower: 1, upper: 3))
        #expect(filter.size == FaceRangeFilter(enabled: false, lower: 50, upper: 100))

        filter.size.enabled = true
        library.setFaceFilter(ref, filter)
        #expect(library.shownFrames(ref) == [200, 300, 500])
        #expect(library.faceSheet(ref).faceFilter == filter)
        #expect(library.faceSheet(ref).columnCount == 2)
        // Sorting by size counts only the faces that pass.
        library.sortThumbs(ref, by: .faceConfidence, includeHidden: false)
        #expect(library.shownFrames(ref) == [300, 200, 500])

        filter.size.enabled = false
        filter.faceCount.enabled = true
        filter.faceCount.lower = 2
        library.setFaceFilter(ref, filter)
        #expect(Set(library.shownFrames(ref)) == [200, 300])
        filter.faceCount.lower = 3
        filter.faceCount.upper = 10
        library.setFaceFilter(ref, filter)
        #expect(library.shownFrames(ref) == [200])
        // Off again: every thumb shows.
        library.setFaceFilter(ref, FaceFilter())
        #expect(library.faceSheet(ref).visibleThumbs.count == 5)
    }

    @Test func rangesAtTheirMaximumLetLargerValuesPass() {
        var filter = FaceFilter()
        filter.faceCount = FaceRangeFilter(enabled: true, lower: 1, upper: 10)
        #expect(filter.passes(face(30), faceCount: 12))
        filter.faceCount.upper = 9
        #expect(!filter.passes(face(30), faceCount: 12))
        filter = FaceFilter()
        filter.size = FaceRangeFilter(enabled: true, lower: 50, upper: 100)
        #expect(filter.passes(face(120), faceCount: 1))
        #expect(!filter.passes(face(49), faceCount: 1))
        filter.size.upper = 70
        #expect(!filter.passes(face(71), faceCount: 1))
        let both = [face(60), face(20)]
        #expect(filter.passing(both).map(\.size) == [60])
    }

    @Test func shotSheetsAreNotSortedAndIntervalSheetsOnlyByFrame() {
        var (library, ref) = fixture()
        let fileId = ref.fileId
        let shot = library.addShotSheet(
            to: fileId, scenes: [SceneSpan(start: 0, length: 500, colorRGB: [0, 0, 0]),
                                 SceneSpan(start: 500, length: 500, colorRGB: [0, 0, 0])])!
        let shotRef = SheetRef(fileId: fileId, sheetId: shot.id)
        let before = library.faceSheet(shotRef).thumbs
        library.sortThumbs(shotRef, by: .reverse, includeHidden: false)
        #expect(library.faceSheet(shotRef).thumbs == before)

        let interval = library.addDefaultIntervalSheet(to: fileId)!
        let intervalRef = SheetRef(fileId: fileId, sheetId: interval.id)
        let frames = library.faceSheet(intervalRef).thumbs.map(\.frameNumber)
        library.sortThumbs(intervalRef, by: .faceSize, includeHidden: false)
        #expect(library.faceSheet(intervalRef).visibleThumbs.count == frames.count)
        library.sortThumbs(intervalRef, by: .reverse, includeHidden: false)
        #expect(library.faceSheet(intervalRef).thumbs.map(\.frameNumber) == frames.reversed())
        library.sortThumbs(intervalRef, by: .frameNumber, includeHidden: false)
        #expect(library.faceSheet(intervalRef).thumbs.map(\.frameNumber) == frames)
        // The filter is for faces sheets only.
        var filter = FaceFilter()
        filter.size.enabled = true
        library.setFaceFilter(intervalRef, filter)
        #expect(library.faceSheet(intervalRef).faceFilter == nil)
    }

    @Test func facesSheetFromScanResults() throws {
        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
            width: 1920, height: 1080, size: 1, fourCC: "avc1")
        library.files.append(file)
        var data = FaceData(thresholds: FaceThresholds())
        for (frame, sizes) in [(0, [Double]()), (10, [20]), (20, [70, 30]), (30, [40]), (40, [12])] {
            data.record(FaceFrame(frameNumber: frame, faces: sizes.map { face($0) }))
        }
        // 50 was not analyzed.
        let added = library.addFacesSheet(to: file.id, frames: [0, 10, 20, 30, 40, 50], faces: data)
        let sheet = try #require(added)
        #expect(sheet.type == .faces && sheet.view == .grid)
        #expect(sheet.thumbs.map(\.frameNumber) == [20, 30, 10, 40])
        #expect(sheet.thumbs.allSatisfy { !$0.hidden })
        #expect(sheet.thumbs[0].faces.map(\.size) == [70, 30])
        #expect(sheet.columnCount == 2)
        #expect(library.addFacesSheet(to: file.id, frames: [0, 50], faces: data) == nil)
    }
}

/// The analysis queue behind the scan pass's observer, fed like the pass
/// feeds it: frames lent one at a time, reused after each call.
@Suite(.timeLimit(.minutes(1))) struct FaceCollectorTests {
    private static let frames = Array(stride(from: 0, to: 400, by: 10))

    /// Feeds `frames` as a scan pass would, numbering each frame in its
    /// first pixel; returns the most frames that were queued or being
    /// analyzed at once.
    private func feed(_ collector: FaceCollector, _ frames: [Int]) async -> Int {
        let image = OwnedBGRA(width: 64, height: 36)
        var maxWaiting = 0
        for (i, number) in frames.enumerated() {
            if Task.isCancelled { break }
            image.data.storeBytes(of: UInt32(number), as: UInt32.self)
            await collector.scanned(ScanFrame(frameNumber: number, image: image.frame))
            // Reused at once, as the scan's frame is.
            image.data.storeBytes(of: UInt32.max, as: UInt32.self)
            maxWaiting = max(maxWaiting, i + 1 - collector.analyzedNow)
        }
        withExtendedLifetime(image) {}
        return maxWaiting
    }

    /// A slow analyzer holds the pass back instead of losing frames: every
    /// frame is analyzed, in order, with at most the backlog waiting.
    @Test func backPressureKeepsEverySampleInOrder() async {
        let analyzer = SlowAnalyzer(delay: .milliseconds(5))
        let frames = Self.frames
        let collector = FaceCollector(
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames), analyzer: analyzer, backlog: 4)
        let maxWaiting = await collector.analyzing { await feed(collector, frames) }
        #expect(analyzer.order == frames)
        #expect(analyzer.maxRunning == 1)
        // The queue filled (the analyzer is the slower side) but never
        // held more than the backlog, the frame being analyzed included.
        #expect(maxWaiting >= 2 && maxWaiting <= 4)
        let data = collector.snapshot
        #expect(Array(data.analyzed) == frames)
        #expect(data.frames.keys.sorted() == frames.filter { $0 % 20 == 0 })
        #expect(collector.analyzedNow == frames.count && collector.facesFound == frames.count / 2)
    }

    /// Cancel part way: what was analyzed is a prefix of the frames, and a
    /// resumed scan analyzes only the rest.
    @Test func cancelLeavesAConsistentPrefixAndResumes() async throws {
        let frames = Self.frames
        let analyzer = SlowAnalyzer(delay: .milliseconds(10))
        let collector = FaceCollector(
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames), analyzer: analyzer, backlog: 4)
        let task = Task { await collector.analyzing { await feed(collector, frames) } }
        while collector.analyzedNow < 5 { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        _ = await task.value
        let partial = collector.snapshot
        let count = partial.analyzed.count
        #expect(count >= 5 && count < frames.count)
        #expect(Array(partial.analyzed) == Array(frames.prefix(count)))
        #expect(analyzer.order.starts(with: Array(frames.prefix(count))))
        #expect(partial.frames.keys.sorted() == frames.prefix(count).filter { $0 % 20 == 0 })

        let missing = partial.missing(frames)
        let next = SlowAnalyzer(delay: .milliseconds(1))
        let resumed = FaceCollector(data: partial, wanted: Set(missing), analyzer: next, backlog: 4)
        _ = await resumed.analyzing { await feed(resumed, frames) }
        #expect(next.order == missing)
        #expect(Array(resumed.snapshot.analyzed) == frames)
    }
}

/// The face scan through the scan pass on clips made by the system ffmpeg
/// (skipped without it), with a stub analyzer.
@Suite(.serialized, .timeLimit(.minutes(1))) struct FaceScanIntegrationTests {
    static var tools: FFmpegTools? { DecodeIntegrationTests.tools }
    static let frameCount = 120

    private static func makeClip(_ name: String) async throws -> URL {
        let tools = try #require(tools)
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetFaceClips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let result = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=s=320x180:r=25:d=6",
            "-frames:v", "\(frameCount)", "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", url.path,
        ])
        #expect(result.status == 0, "\(result.stderrText)")
        return url
    }

    private struct Stores {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetFaceScans-\(UUID().uuidString)")
        var faces: FaceCacheStore { FaceCacheStore(directory: dir) }
        var scans: ScanCacheStore { ScanCacheStore(directory: dir) }
    }

    private struct Result {
        var data: FaceData?
        var shotScan: ScanData?
        var cancelled = false
        var failure: String?
        var combined: Bool?
        var missing: Int?
    }

    private func scan(_ request: FaceScanRequest) async -> Result {
        await withDeadline("face scan of \(request.url.lastPathComponent)") {
            var result = Result()
            for await event in FaceScanner.scan(request) {
                switch event {
                case .started(let missing, let combined):
                    result.missing = missing
                    result.combined = combined
                case .finished(let data, let shotScan):
                    result.data = data
                    result.shotScan = shotScan
                case .cancelled(let data, let shotScan):
                    result.data = data
                    result.shotScan = shotScan
                    result.cancelled = true
                case .failed(let message, _):
                    result.failure = message
                case .progress:
                    break
                }
            }
            return result
        }
    }

    private func request(
        _ url: URL, frames: [Int], stores: Stores, analyzer: any FaceAnalyzer, id: UUID,
        thresholds: FaceThresholds = FaceThresholds()
    ) -> FaceScanRequest {
        FaceScanRequest(
            fileId: id, url: url, frames: frames, thresholds: thresholds, analyzer: analyzer, ffmpeg: Self.tools,
            faceStore: stores.faces, scanStore: stores.scans, method: .mean, shotThreshold: 6)
    }

    /// No shot scan yet: the combined pass reads up to the last sampled
    /// frame, a cancel keeps both partial results, and the next scan
    /// resumes both; frames the shot scan has read get a faces-only pass.
    @Test(.enabled(if: FaceScanIntegrationTests.tools != nil)) func combinedPassCancelsAndResumes() async throws {
        for name in ["clip.mp4", "clip.mkv"] {
            let clip = try await Self.makeClip(name)
            let stores = Stores()
            defer { try? FileManager.default.removeItem(at: stores.dir) }
            let id = UUID()
            let frames = Array(stride(from: 0, through: 110, by: 10))
            let analyzer = StubAnalyzer()

            var first = request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id)
            first.stopAfterFrames = 45
            let stopped = await scan(first)
            #expect(stopped.failure == nil, "\(name): \(stopped.failure ?? "")")
            #expect(stopped.cancelled && stopped.combined == true, "\(name)")
            let partial = try #require(stopped.data)
            #expect(Array(partial.analyzed) == [0, 10, 20, 30, 40], "\(name)")
            #expect(try stores.faces.load(id) == partial, "\(name)")
            #expect(try stores.scans.load(id)?.frameCount == 45, "\(name)")

            let resumed = await scan(request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id))
            #expect(resumed.failure == nil && !resumed.cancelled, "\(name)")
            #expect(resumed.missing == 7, "\(name)")
            #expect(analyzer.callCount == 12, "\(name)")
            let data = try #require(resumed.data)
            #expect(Array(data.analyzed) == frames, "\(name)")
            #expect(data.frame(50)?.faceCount == 1, "\(name)")
            // The shot scan stopped after the last sampled frame.
            let shots = try #require(resumed.shotScan)
            #expect(shots.frameCount == 111 && !shots.complete, "\(name)")

            // Frames before 111 are read by a faces-only pass, the last
            // frame by the shot scan, which now reaches the end.
            let more = await scan(request(clip, frames: [5, 15, 119], stores: stores, analyzer: analyzer, id: id))
            #expect(more.failure == nil, "\(name): \(more.failure ?? "")")
            #expect(analyzer.callCount == 15, "\(name)")
            #expect(Array(try #require(more.data).analyzed) == (frames + [5, 15, 119]).sorted(), "\(name)")
            #expect(more.shotScan?.complete == true, "\(name)")
            #expect(try stores.scans.load(id)?.complete == true, "\(name)")

            // Everything cached: nothing is read.
            let cached = await scan(request(clip, frames: [5, 50], stores: stores, analyzer: analyzer, id: id))
            #expect(cached.missing == 0 && analyzer.callCount == 15, "\(name)")
        }
    }

    /// A faces-only pass after a complete shot scan, cancelled part way:
    /// the next scan reads only the frames still missing.
    @Test(.enabled(if: FaceScanIntegrationTests.tools != nil)) func facesOnlyPassResumes() async throws {
        let clip = try await Self.makeClip("clip.mp4")
        let stores = Stores()
        defer { try? FileManager.default.removeItem(at: stores.dir) }
        let id = UUID()
        var shots: ScanData?
        for await event in ShotScanner.scan(ScanRequest(
            fileId: id, url: clip, method: .mean, threshold: 6, ffmpeg: Self.tools, store: stores.scans)) {
            if case .finished(let data) = event { shots = data }
        }
        #expect(shots?.complete == true)

        let analyzer = StubAnalyzer()
        let frames = [3, 33, 63, 93, 119]
        var first = request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id)
        first.stopAfterFrames = 2
        let stopped = await scan(first)
        #expect(stopped.cancelled && stopped.combined == false)
        #expect(Array(try #require(stopped.data).analyzed) == [3, 33])
        let resumed = await scan(request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id))
        #expect(resumed.failure == nil && resumed.missing == 3)
        #expect(Array(try #require(resumed.data).analyzed) == frames)
        #expect(analyzer.callCount == 5)
        #expect(resumed.shotScan == nil)
    }

    /// An analyzer slower than decoding: the combined pass waits for it and
    /// every sampled frame is analyzed.
    @Test(.enabled(if: FaceScanIntegrationTests.tools != nil)) func slowAnalyzerKeepsEverySample() async throws {
        let clip = try await Self.makeClip("clip.mp4")
        let stores = Stores()
        defer { try? FileManager.default.removeItem(at: stores.dir) }
        let id = UUID()
        let analyzer = SlowAnalyzer(delay: .milliseconds(30))
        let frames = Array(stride(from: 0, through: 110, by: 5))
        let result = await scan(request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id))
        #expect(result.failure == nil && !result.cancelled)
        let data = try #require(result.data)
        #expect(Array(data.analyzed) == frames)
        #expect(analyzer.maxRunning == 1)
        #expect(try stores.faces.load(id) == data)
    }

    /// Faces below the thresholds are not stored; other thresholds scan
    /// again.
    @Test(.enabled(if: FaceScanIntegrationTests.tools != nil)) func thresholdsTakeEffectOnTheNextScan() async throws {
        let clip = try await Self.makeClip("clip.mp4")
        let stores = Stores()
        defer { try? FileManager.default.removeItem(at: stores.dir) }
        let id = UUID()
        let analyzer = StubAnalyzer([
            DetectedFace(confidence: 0.9, box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.5)),
            DetectedFace(confidence: 0.5, box: CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.5)),
            DetectedFace(confidence: 0.9, box: CGRect(x: 0.5, y: 0.7, width: 0.05, height: 0.05)),
        ])
        let frames = [10, 20]
        let first = await scan(request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id))
        #expect(first.data?.frame(10)?.faceCount == 1)
        #expect(first.data?.frame(10)?.faces.first?.confidence == 90)

        let lower = FaceThresholds(confidence: 40, size: 1)
        let second = await scan(request(clip, frames: frames, stores: stores, analyzer: analyzer, id: id, thresholds: lower))
        #expect(second.missing == 2 && analyzer.callCount == 4)
        #expect(second.data?.frame(20)?.faceCount == 3)
        #expect(try stores.faces.load(id)?.thresholds == lower)
    }

    /// "These thumbs": one exact frame at a time through the backend.
    @Test(.enabled(if: FaceScanIntegrationTests.tools != nil)) func singleFramesThroughTheBackend() async throws {
        let clip = try await Self.makeClip("clip.mp4")
        let stores = Stores()
        defer { try? FileManager.default.removeItem(at: stores.dir) }
        let id = UUID()
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools)
        let analyzer = StubAnalyzer()
        var single = request(clip, frames: [7, 64, 101], stores: stores, analyzer: analyzer, id: id)
        single.singleFrames = backend
        let result = await scan(single)
        #expect(result.failure == nil && result.combined == false)
        #expect(Array(try #require(result.data).analyzed) == [7, 64, 101])
        #expect(analyzer.callCount == 3)
        #expect(try stores.scans.load(id) == nil)
    }
}

/// Vision itself, without a face photo: the request runs on a scan frame
/// and finds no face in a blank one.
@Suite struct VisionFaceAnalyzerTests {
    private func frame(drawing draw: (CGContext) -> Void) -> (OwnedBGRA, BGRAFrame) {
        let image = OwnedBGRA(width: 720, height: 406)
        let context = CGContext(
            data: image.data, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(context)
        return (image, image.frame)
    }

    @Test func blankFrameHasNoFaces() async throws {
        let (owner, blank) = frame { $0.setFillColor(gray: 0.5, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 720, height: 406)) }
        let faces = try await VisionFaceAnalyzer.shared.detect(in: blank)
        withExtendedLifetime(owner) {}
        #expect(faces.isEmpty)
    }
}
