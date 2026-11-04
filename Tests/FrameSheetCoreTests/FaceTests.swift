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

/// Takes `delay` per frame (or a random 5–30 ms, say) and records the frame
/// numbers it was given (the first four bytes of a frame) in the order the
/// calls ended, and how many calls ran at once at most.
private final class SlowAnalyzer: FaceAnalyzer {
    let delay: Duration
    let randomMilliseconds: ClosedRange<Int>?
    private let state = Mutex<(order: [Int], running: Int, maxRunning: Int)>(([], 0, 0))

    init(delay: Duration) {
        self.delay = delay
        randomMilliseconds = nil
    }

    init(milliseconds: ClosedRange<Int>) {
        delay = .zero
        randomMilliseconds = milliseconds
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
        try await Task.sleep(for: randomMilliseconds.map { .milliseconds(Int.random(in: $0)) } ?? delay)
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

    @Test func staleScansOfRemovedMoviesGo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetFaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let faces = FaceCacheStore(directory: dir)
        let scans = ScanCacheStore(directory: dir)
        let kept = UUID()
        let gone = UUID()
        for id in [kept, gone] {
            try faces.save(FaceData(thresholds: FaceThresholds()), for: id)
            try scans.save(ScanData(method: .mean, expectedFrameCount: 10), for: id)
        }
        let other = dir.appending(path: "notes.txt")
        try Data("x".utf8).write(to: other)
        #expect(StoredScans.removeStale(in: dir, keeping: [kept]) == [gone])
        #expect(try faces.load(kept) != nil && scans.load(kept) != nil)
        #expect(try faces.load(gone) == nil && scans.load(gone) == nil)
        #expect(FileManager.default.fileExists(atPath: other.path))
        // A missing folder is no error.
        #expect(StoredScans.removeStale(in: dir.appending(path: "none"), keeping: []).isEmpty)
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

/// Apply (Settings, Face detection): the stored scan source and the
/// in-place replacement of a faces sheet's thumbs.
@Suite struct FaceSheetRescanTests {
    private func movie() -> (Library, MovieFile) {
        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
            width: 1920, height: 1080, size: 1, fourCC: "avc1")
        library.files.append(file)
        return (library, file)
    }

    private func data(_ thresholds: FaceThresholds, _ frames: [(Int, [Double])]) -> FaceData {
        var data = FaceData(thresholds: thresholds)
        for (frame, sizes) in frames {
            data.record(FaceFrame(frameNumber: frame, faces: sizes.map { face($0) }))
        }
        return data
    }

    @Test func sourceRebuildsTheScopesFrames() throws {
        let thumbs = [600, 100, 1100, 350]
        for scope in FaceScanScope.allCases {
            let source = FaceSheetSource(scope: scope, thumbFrames: thumbs, frameCount: 2000, thresholds: FaceThresholds())
            #expect(source.frames(frameCount: 2000) == scope.frames(thumbFrames: thumbs, frameCount: 2000))
            let decoded = try JSONDecoder().decode(FaceSheetSource.self, from: JSONEncoder().encode(source))
            #expect(decoded == source)
        }
        let sampled = FaceSheetSource(scope: .everyTenth, thumbFrames: thumbs, frameCount: 2000, thresholds: nil)
        #expect(sampled.lowFrame == 100 && sampled.highFrame == 1100 && sampled.thumbFrames == nil)
        let exact = FaceSheetSource(scope: .thumbs, thumbFrames: thumbs + [5000], frameCount: 2000, thresholds: nil)
        #expect(exact.thumbFrames == [100, 350, 600, 1100])
    }

    @Test func sourceDecodesTolerantly() throws {
        let json = #"{"scope": "perShot", "lowFrame": 10, "thresholds": {"bad": 1}}"#
        let source = try JSONDecoder().decode(FaceSheetSource.self, from: Data(json.utf8))
        #expect(source.scope == .everyTenth && source.lowFrame == 10 && source.highFrame == 10)
        #expect(source.thresholds == nil)
        let sort = try JSONDecoder().decode(FaceSheetSort.self, from: Data(#"{"sort": "unknown"}"#.utf8))
        #expect(sort == FaceSheetSort(sort: .faceSize))
        // A sheet saved before Apply decodes without either.
        let sheet = Sheet(name: "Sheet-1", type: .faces)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(sheet)) as? [String: Any])
        object["faceSource"] = nil
        object["faceSort"] = nil
        let old = try JSONDecoder().decode(Sheet.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.faceSource == nil && old.faceSort == nil)
    }

    @Test func addedSheetStoresItsSourceAndOlderSheetsFallBack() throws {
        var (library, file) = movie()
        let thresholds = FaceThresholds(confidence: 70, size: 10)
        let source = FaceSheetSource(scope: .thumbs, thumbFrames: [10, 20, 30], frameCount: 1000, thresholds: thresholds)
        let added = library.addFacesSheet(
            to: file.id, frames: [10, 20, 30], faces: data(thresholds, [(10, [20]), (20, [40]), (30, [])]),
            source: source)
        let sheet = try #require(added)
        let ref = SheetRef(fileId: file.id, sheetId: sheet.id)
        #expect(library.faceSheetSource(ref) == source)
        #expect(!library.faceSheetNeedsRescan(ref, thresholds: thresholds))
        #expect(library.faceSheetNeedsRescan(ref, thresholds: FaceThresholds(confidence: 50, size: 10)))

        // A rotation or crop since (decision 26): the boxes are off, Apply
        // rescans; an aspect ratio alone changes nothing. No stored
        // transform means none (sheets from before transforms).
        #expect(!library.faceSheetTransformChanged(ref))
        library.files[0].transform.aspectRatioInv = 0.75
        #expect(!library.faceSheetTransformChanged(ref))
        library.files[0].transform.cropTop = 10
        #expect(library.faceSheetTransformChanged(ref))
        #expect(library.faceSheetNeedsRescan(ref, thresholds: thresholds))
        library.sheets[file.id]![0].faceSource?.transform = library.files[0].transform
        #expect(!library.faceSheetTransformChanged(ref))
        let coded = try JSONDecoder().decode(
            FaceSheetSource.self, from: JSONEncoder().encode(library.sheets[file.id]![0].faceSource))
        #expect(coded.transform?.cropTop == 10)
        library.files[0].transform = MovieTransform()
        library.sheets[file.id]![0].faceSource?.transform = nil

        // Made before Apply: every 10th frame over its own frames, thresholds unknown.
        library.sheets[file.id]![0].faceSource = nil
        let fallback = try #require(library.faceSheetSource(ref))
        #expect(fallback.scope == .everyTenth && fallback.lowFrame == 10 && fallback.highFrame == 20)
        #expect(fallback.thresholds == nil)
        #expect(library.faceSheetNeedsRescan(ref, thresholds: thresholds))
        // With a parent sheet: over the parent's shown thumbs.
        let interval = library.addDefaultIntervalSheet(to: file.id)
        let parent = try #require(interval)
        library.sheets[file.id]![0].parentSheetId = parent.id
        let fromParent = try #require(library.faceSheetSource(ref))
        #expect(fromParent.lowFrame == parent.thumbs.map(\.frameNumber).min())
        #expect(fromParent.highFrame == parent.thumbs.map(\.frameNumber).max())
        // Not a faces sheet.
        #expect(library.faceSheetSource(SheetRef(fileId: file.id, sheetId: parent.id)) == nil)
    }

    @Test func replacementKeepsNameSortAndFilterAsOneUndoStep() throws {
        var (library, file) = movie()
        let old = FaceThresholds(confidence: 70, size: 10)
        let frames = [100, 200, 300, 400, 500]
        let source = FaceSheetSource(scope: .everyHundredth, thumbFrames: [100, 500], frameCount: 1000, thresholds: old)
        let added = library.addFacesSheet(
            to: file.id, frames: frames, faces: data(old, [(100, [30]), (200, [60]), (300, [55]), (400, []), (500, [80])]),
            source: source)
        let sheet = try #require(added)
        let ref = SheetRef(fileId: file.id, sheetId: sheet.id)
        var filter = FaceFilter()
        filter.size.enabled = true
        library.setFaceFilter(ref, filter)
        library.sortThumbs(ref, by: .frameNumber, includeHidden: false)
        library.sortThumbs(ref, by: .reverse, includeHidden: false)
        #expect(library.faceSheet(ref).faceSort == FaceSheetSort(sort: .frameNumber, reversed: true))
        let before = library

        var document = EditableLibrary(library)
        let new = FaceThresholds(confidence: 50, size: 5)
        let replaced = document.edit {
            $0.replaceFacesSheetThumbs(
                ref, frames: frames,
                faces: data(new, [(100, [70]), (200, [6]), (300, [52, 8]), (400, [90]), (500, [])]),
                source: source.with(new))
        }
        #expect(replaced)
        let after = document.library.faceSheet(ref)
        #expect(after.name == sheet.name && after.id == sheet.id && after.type == .faces)
        #expect(after.faceFilter == filter)
        #expect(after.faceSort == FaceSheetSort(sort: .frameNumber, reversed: true))
        #expect(after.faceSource == source.with(new))
        // New thumbs: frame 500 lost its face, 400 found one; size ≥ 50 shows 100, 300, 400, reversed.
        #expect(Set(after.thumbs.map(\.frameNumber)) == [100, 200, 300, 400])
        #expect(after.visibleThumbs.map(\.frameNumber) == [400, 300, 100])
        #expect(after.thumbs.map(\.index) == Array(0..<4))
        #expect(!document.library.faceSheetNeedsRescan(ref, thresholds: new))
        #expect(document.library.sheets[file.id]?.count == 1)

        let undone = document.undo()
        #expect(undone)
        #expect(document.library == before)
        #expect(!document.history.canUndo)

        // No faces: nothing changes, no undo step.
        var unchanged = EditableLibrary(before)
        let none = unchanged.edit {
            $0.replaceFacesSheetThumbs(ref, frames: frames, faces: data(new, [(100, [])]), source: source.with(new))
        }
        #expect(!none && unchanged.library == before && !unchanged.history.canUndo)
    }
}

/// The analysis queue behind the scan pass's observer, fed like the pass
/// feeds it: frames lent one at a time, reused after each call.
@Suite(.timeLimit(.minutes(1))) struct FaceCollectorTests {
    private static let frames = Array(stride(from: 0, to: 400, by: 10))

    /// Feeds `frames` as a scan pass would, numbering each frame in its
    /// first pixel, calling `each` after every frame; returns the most
    /// frames that were queued, being analyzed or waiting to be recorded at
    /// once.
    private func feed(_ collector: FaceCollector, _ frames: [Int], each: () -> Void = {}) async -> Int {
        let image = OwnedBGRA(width: 64, height: 36)
        var maxWaiting = 0
        for (i, number) in frames.enumerated() {
            if Task.isCancelled { break }
            image.data.storeBytes(of: UInt32(number), as: UInt32.self)
            await collector.scanned(ScanFrame(frameNumber: number, image: image.frame))
            // Reused at once, as the scan's frame is.
            image.data.storeBytes(of: UInt32.max, as: UInt32.self)
            maxWaiting = max(maxWaiting, i + 1 - collector.analyzedNow)
            each()
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
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames), analyzer: analyzer, workers: 1,
            backlog: 4)
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

    /// Frames with faces give thumbnails from the scan frame: only those,
    /// in order, at the width asked for the n-th of them (counting frames
    /// found before), never enlarged.
    @Test func framesWithFacesGiveThumbnails() async throws {
        let frames = Self.frames
        let delivered = Mutex<[(frame: Int, width: Int, size: CGSize)]>([])
        let asked = Mutex<[Int]>([])
        let thumbnails = FaceScanThumbnails(
            width: { n in
                asked.withLock { $0.append(n) }
                return n == 3 ? 640 : 32
            },
            deliver: { frame, image, width in
                delivered.withLock { $0.append((frame, width, CGSize(width: image.width, height: image.height))) }
            })
        let collector = FaceCollector(
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames),
            analyzer: SlowAnalyzer(delay: .zero), workers: 1, backlog: 4, thumbnails: thumbnails,
            facesFramesBefore: 2)
        _ = await collector.analyzing { await feed(collector, frames) }
        let withFaces = frames.filter { $0 % 20 == 0 }
        let got = delivered.withLock { $0 }
        #expect(got.map(\.frame) == withFaces)
        #expect(asked.withLock { $0 } == Array(3..<(3 + withFaces.count)))
        // The first (the third in the scope) asked for more than the frame has.
        #expect(got.first?.width == 64 && got.first?.size == CGSize(width: 64, height: 36))
        #expect(got.dropFirst().allSatisfy { $0.width == 32 && $0.size == CGSize(width: 32, height: 18) })
    }

    /// Cancel part way: what was analyzed is a prefix of the frames, and a
    /// resumed scan analyzes only the rest.
    @Test func cancelLeavesAConsistentPrefixAndResumes() async throws {
        let frames = Self.frames
        let analyzer = SlowAnalyzer(delay: .milliseconds(10))
        let collector = FaceCollector(
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames), analyzer: analyzer, workers: 1,
            backlog: 4)
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
        let resumed = FaceCollector(data: partial, wanted: Set(missing), analyzer: next, workers: 1, backlog: 4)
        _ = await resumed.analyzing { await feed(resumed, frames) }
        #expect(next.order == missing)
        #expect(Array(resumed.snapshot.analyzed) == frames)
    }

    /// Two workers on an analyzer of uneven speed finish frames out of
    /// order: every frame is analyzed once, at most two at a time, and
    /// recorded in frame order (always a prefix), thumbnails too.
    @Test func twoWorkersRecordInFrameOrder() async {
        let analyzer = SlowAnalyzer(milliseconds: 5...30)
        let frames = Self.frames
        let delivered = Mutex<[Int]>([])
        let asked = Mutex<[Int]>([])
        let thumbnails = FaceScanThumbnails(
            width: { n in
                asked.withLock { $0.append(n) }
                return 16
            },
            deliver: { frame, _, _ in delivered.withLock { $0.append(frame) } })
        let collector = FaceCollector(
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames), analyzer: analyzer, workers: 2,
            thumbnails: thumbnails)
        #expect(collector.backlog == 6)
        var alwaysPrefix = true
        let maxWaiting = await collector.analyzing {
            await feed(collector, frames) {
                let analyzed = Array(collector.snapshot.analyzed)
                if analyzed != Array(frames.prefix(analyzed.count)) { alwaysPrefix = false }
            }
        }
        #expect(alwaysPrefix)
        #expect(analyzer.order.count == frames.count && analyzer.order.sorted() == frames)
        #expect(analyzer.maxRunning >= 1 && analyzer.maxRunning <= 2)
        #expect(maxWaiting <= 6)
        let data = collector.snapshot
        #expect(Array(data.analyzed) == frames)
        #expect(data.frames.keys.sorted() == frames.filter { $0 % 20 == 0 })
        #expect(collector.analyzedNow == frames.count && collector.facesFound == frames.count / 2)
        let withFaces = frames.filter { $0 % 20 == 0 }
        #expect(delivered.withLock { $0 } == withFaces)
        #expect(asked.withLock { $0 } == Array(1...withFaces.count))
        let stats = collector.stats
        #expect(stats.analyzed == frames.count && stats.thumbnails == withFaces.count)
        #expect(stats.wallSeconds > 0 && stats.wallSeconds <= stats.analyzeSeconds + 0.001)
    }

    /// Cancel part way with two workers: what was recorded is a prefix of
    /// the frames (frames analyzed past it are dropped), and a resumed scan
    /// analyzes the rest.
    @Test func twoWorkersCancelLeavesAConsistentPrefixAndResume() async throws {
        let frames = Self.frames
        let analyzer = SlowAnalyzer(milliseconds: 5...30)
        let collector = FaceCollector(
            data: FaceData(thresholds: FaceThresholds()), wanted: Set(frames), analyzer: analyzer, workers: 2)
        let task = Task { await collector.analyzing { await feed(collector, frames) } }
        while collector.analyzedNow < 5 { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        _ = await task.value
        let partial = collector.snapshot
        let count = partial.analyzed.count
        #expect(count >= 5 && count < frames.count)
        #expect(Array(partial.analyzed) == Array(frames.prefix(count)))
        #expect(partial.frames.keys.sorted() == frames.prefix(count).filter { $0 % 20 == 0 })
        #expect(analyzer.maxRunning <= 2)

        let missing = partial.missing(frames)
        #expect(missing == Array(frames.dropFirst(count)))
        let next = SlowAnalyzer(milliseconds: 1...5)
        let resumed = FaceCollector(data: partial, wanted: Set(missing), analyzer: next, workers: 2)
        _ = await resumed.analyzing { await feed(resumed, frames) }
        #expect(next.order.count == missing.count && next.order.sorted() == missing)
        #expect(next.maxRunning <= 2)
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
        #expect(analyzer.maxRunning <= FaceCollector.defaultWorkers)
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

/// Window thumbs are decoded at the size they are drawn (T07 follow-up).
@Suite struct ThumbnailWidthTests {
    private let file = MovieFile(
        url: URL(fileURLWithPath: "/movies/film.mov"), duration: 734, frameCount: 17620, fps: 24,
        width: 1920, height: 800, size: 1, fourCC: "avc1")

    @Test func roundsUpToSteps() {
        #expect(ThumbnailWidth.decodeWidth(points: 50, scale: 2, movieWidth: 1920) == 128)
        #expect(ThumbnailWidth.decodeWidth(points: 108, scale: 2, movieWidth: 1920) == 256)
        #expect(ThumbnailWidth.decodeWidth(points: 400, scale: 2, movieWidth: 1920) == 640)
        #expect(ThumbnailWidth.decodeWidth(points: 0, scale: 2, movieWidth: 1920) == 128)
        // Never wider than the movie.
        #expect(ThumbnailWidth.decodeWidth(points: 300, scale: 2, movieWidth: 320) == 320)
    }

    /// The owner's case: a faces sheet of 400 thumbs (20 columns) of a
    /// 1920 × 800 film fits the default cache at its grid size, in a window
    /// and on a large display; at 640 px it did not.
    @Test func fourHundredThumbFacesSheetFitsTheDefaultCache() throws {
        func image(width: Int) throws -> CGImage {
            let height = Int((Double(width) * 800 / 1920).rounded())
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
            return try #require(context.makeImage())
        }
        func fits(width: Int) throws -> Bool {
            let cache = ThumbnailCache()
            let id = UUID()
            let thumb = try image(width: width)
            for frame in 0..<400 { cache.insert(thumb, file: id, frame: frame * 10, width: 640) }
            return (0..<400).allSatisfy { cache.image(file: id, frame: $0 * 10, width: 640) != nil }
        }
        #expect(ThumbnailCache().limitBytes == Defaults.thumbnailCacheMB * 1024 * 1024)
        #expect(try !fits(width: 640))
        for (width, height) in [(1100.0, 700.0), (1600.0, 1000.0), (3000.0, 1900.0)] {
            let decode = ThumbnailWidth.facesSheetDecodeWidth(
                file: file, thumbCount: 400, settings: Settings(), containerWidth: width, containerHeight: height,
                scale: 2)
            #expect(decode < 640, "\(width) × \(height): \(decode)")
            #expect(try fits(width: decode), "\(width) × \(height): \(decode)")
        }
    }

    /// The scan's thumbnails shrink as the faces found grow, so each is at
    /// least as wide as the finished sheet needs.
    @Test func facesSheetWidthShrinksWithTheCount() {
        let widths = [1, 4, 16, 50, 100, 400, 1000].map {
            ThumbnailWidth.facesSheetDecodeWidth(
                file: file, thumbCount: $0, settings: Settings(), containerWidth: 1400, containerHeight: 900, scale: 2)
        }
        #expect(widths == widths.sorted(by: >), "\(widths)")
        #expect(widths.first == 640)
    }
}
