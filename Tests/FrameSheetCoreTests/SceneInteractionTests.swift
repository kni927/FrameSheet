import Foundation
import Testing
@testable import FrameSheetCore

/// A 300-frame movie with a shot sheet of three scenes: 0–99, 100–199,
/// 200–299 (thumbs at 50, 150, 250).
private func shotFixture() -> (Library, SheetRef) {
    var library = Library()
    let file = MovieFile(
        url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 12, frameCount: 300, fps: 25,
        width: 640, height: 360, size: 1, fourCC: "avc1")
    library.files.append(file)
    let spans = [
        SceneSpan(start: 0, length: 100, colorRGB: [10, 20, 30]),
        SceneSpan(start: 100, length: 100, colorRGB: [40, 50, 60]),
        SceneSpan(start: 200, length: 100, colorRGB: [128, 128, 128]),
    ]
    let sheet = library.addShotSheet(to: file.id, scenes: spans)!
    return (library, SheetRef(fileId: file.id, sheetId: sheet.id))
}

private extension Library {
    func scenes(_ ref: SheetRef) -> [Scene] { sheet(ref.sheetId, of: ref.fileId)!.scenes }
    func thumbs(_ ref: SheetRef) -> [Thumb] { sheet(ref.sheetId, of: ref.fileId)!.thumbs }
}

@Suite struct SelectedSceneEditingTests {
    @Test func cutAtTheThumbsFrame() throws {
        var (library, ref) = shotFixture()
        let second = library.scenes(ref)[1]
        // The scene scrub moves the thumb to the frame to cut at.
        library.changeThumb(ref, thumb: second.id, to: 130)
        let result = library.cutSceneAtThumb(ref, scene: second.id)
        guard case .cut(let newId) = result else {
            Issue.record("expected a cut, got \(result)")
            return
        }
        #expect(library.scenes(ref).map(\.start) == [0, 100, 130, 200])
        #expect(library.scenes(ref).map(\.length) == [100, 30, 70, 100])
        #expect(library.scenes(ref)[2].id == newId)
        // Both parts' thumbs move to their middle frames.
        #expect(library.thumbs(ref).map(\.frameNumber) == [50, 115, 165, 250])
    }

    @Test func cutAtTheFirstFrameFindsACut() {
        var (library, ref) = shotFixture()
        let second = library.scenes(ref)[1]
        library.changeThumb(ref, thumb: second.id, to: 100)
        #expect(library.cutSceneAtThumb(ref, scene: second.id) == .alreadyCut)
        #expect(library.scenes(ref).count == 3)
        #expect(library.cutSceneAtThumb(ref, scene: UUID()) == .notFound)
    }

    @Test func cutsOnEitherSide() {
        let (library, ref) = shotFixture()
        let ids = library.scenes(ref).map(\.id)
        #expect(library.cut(ref, scene: ids[0], .previous) == nil)
        #expect(library.cut(ref, scene: ids[0], .next) == 100)
        #expect(library.cut(ref, scene: ids[1], .previous) == 100)
        #expect(library.cut(ref, scene: ids[1], .next) == 200)
        #expect(library.cut(ref, scene: ids[2], .next) == nil)
    }

    @Test func mergeWithPreviousAndNext() {
        var (library, ref) = shotFixture()
        let ids = library.scenes(ref).map(\.id)
        // Previous: the earlier scene takes both and stays.
        #expect(library.mergeScene(ref, scene: ids[1], with: .previous) == ids[0])
        #expect(library.scenes(ref).map(\.length) == [200, 100])
        #expect(library.thumbs(ref).map(\.frameNumber) == [100, 250])
        // Next: the selected scene takes the next one.
        #expect(library.mergeScene(ref, scene: ids[0], with: .next) == ids[0])
        #expect(library.scenes(ref).map(\.length) == [300])
        #expect(library.thumbs(ref).map(\.id) == [ids[0]])
        #expect(library.mergeScene(ref, scene: ids[0], with: .next) == nil)
        #expect(library.mergeScene(ref, scene: ids[0], with: .previous) == nil)
    }

    @Test func jumpToCutSelectsTheSceneAtTheCut() {
        let (library, ref) = shotFixture()
        let ids = library.scenes(ref).map(\.id)
        // Start: the scene itself; end: the next scene (MoviePrint).
        #expect(library.jumpToCut(ref, scene: ids[1], .previous).map { [$0.frame] } == [100])
        #expect(library.jumpToCut(ref, scene: ids[1], .previous)?.scene == ids[1])
        #expect(library.jumpToCut(ref, scene: ids[1], .next)?.frame == 200)
        #expect(library.jumpToCut(ref, scene: ids[1], .next)?.scene == ids[2])
        #expect(library.jumpToCut(ref, scene: ids[0], .previous) == nil)
        #expect(library.jumpToCut(ref, scene: ids[2], .next) == nil)
    }

    @Test func hidingAShotHidesItsScene() {
        var (library, ref) = shotFixture()
        let ids = library.scenes(ref).map(\.id)
        library.toggleHidden(ref, thumb: ids[1])
        #expect(library.scenes(ref).map(\.hidden) == [false, true, false])
        #expect(library.thumbs(ref).map(\.hidden) == [false, true, false])
        let sheet = library.sheet(ref.sheetId, of: ref.fileId)!
        #expect(SceneList.timelineScenes(of: sheet, includeHidden: false).map(\.id) == [ids[0], ids[2]])
        #expect(SceneList.timelineScenes(of: sheet, includeHidden: true).map(\.hidden) == [false, true, false])
        library.toggleHidden(ref, thumb: ids[1])
        #expect(library.scenes(ref).map(\.hidden) == [false, false, false])
        // A scene hidden on its own (an imported sheet) shows with its thumb.
        library.withSheet(ref) { sheet, _ in sheet.scenes[2].hidden = true }
        library.toggleHidden(ref, thumb: ids[2])
        #expect(library.scenes(ref)[2].hidden == false && library.thumbs(ref)[2].hidden == false)
        // Hide all after the first scene.
        library.hideAll(ref, .after, of: ids[0])
        #expect(library.scenes(ref).map(\.hidden) == [false, true, true])
    }

    @Test func intervalScenesWithHiddenThumbs() {
        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
            width: 1920, height: 1080, size: 1, fourCC: "avc1")
        library.files.append(file)
        let sheet = library.addDefaultIntervalSheet(to: file.id)!
        let ref = SheetRef(fileId: file.id, sheetId: sheet.id)
        let hidden = sheet.thumbs[3].id
        library.toggleHidden(ref, thumb: hidden)
        let edited = library.sheet(ref.sheetId, of: ref.fileId)!
        let visible = SceneList.timelineScenes(of: edited, includeHidden: false)
        let all = SceneList.timelineScenes(of: edited, includeHidden: true)
        #expect(visible.count == 15 && !visible.contains { $0.id == hidden })
        #expect(all.count == 16 && all[3].id == hidden && all[3].hidden)
        #expect(all.filter(\.hidden).count == 1)
    }
}

@Suite struct SceneScrubTests {
    /// Scene 100–199 with its thumb at 150; live frame from x 100 to 300 in
    /// a 410-wide overlay.
    private func mapping(thumb: Int = 150, pressX: Double? = nil) -> ScrubMapping {
        .scene(
            Scene(id: UUID(), start: 100, length: 100, colorRGB: []), thumbFrame: thumb, frameCount: 1000,
            liveMinX: 100, liveMaxX: 300, containerWidth: 410, pressX: pressX)
    }

    @Test func staysInsideTheScene() {
        let m = mapping()
        #expect(m.limitedToRange)
        #expect(m.leftFrame == 100 && m.rightFrame == 199)
        #expect(m.frame(atX: 100, modifiers: []) == 100)
        #expect(m.frame(atX: 300, modifiers: []) == 199)
        // Beside the live frame it holds at the scene's ends, also with ⌃.
        #expect(m.frame(atX: 20, modifiers: .control) == 100)
        #expect(m.frame(atX: 400, modifiers: .control) == 199)
        // ⇧ and ⌥ change nothing: always the whole scene.
        #expect(m.frame(atX: 300, modifiers: .shift) == 199)
        #expect(m.frame(atX: 100, modifiers: .option) == 100)
        #expect(m.keyboardRange(modifiers: [.control, .shift]) == 100...199)
    }

    @Test func startsAtTheThumbsFrame() {
        let m = mapping(pressX: 60)
        #expect(m.frame(atX: 60, modifiers: []) == 150)
        // Left of the press it reaches the scene's start within the window.
        #expect(m.frame(atX: 10, modifiers: []) == 100)
        #expect(m.frame(atX: 0, modifiers: .control) == 100)
        #expect(m.frame(atX: 400, modifiers: .control) == 199)
        let between = m.frame(atX: 100, modifiers: [])
        #expect(between > 150 && between < 199)
    }

    @Test func thumbOnTheScenesFirstFrameDoesNotReachTheMovieStart() {
        let m = mapping(thumb: 100, pressX: 200)
        #expect(m.frame(atX: 10, modifiers: []) == 100)
        let absolute = mapping(thumb: 100)
        #expect(absolute.frame(atX: 20, modifiers: []) == 100)
        // A thumb outside its scene is clamped into it.
        #expect(mapping(thumb: 400).thumbFrame == 199)
    }
}

@Suite struct DetectionChartTests {
    @Test func histogramRoundsAndClamps() {
        let bins = DetectionChart.histogram([0, 0.4, 0.6, 2.4, 2.6, 255, 300, -3, .nan])
        #expect(bins.count == 256)
        #expect(bins[0] == 4)  // 0, 0.4, -3, NaN
        #expect(bins[1] == 1)
        #expect(bins[2] == 1)
        #expect(bins[3] == 1)
        #expect(bins[255] == 2)
        #expect(bins.reduce(0, +) == 9)
    }

    @Test func calculatedThresholdFromTheMainCluster() {
        // Most frames differ by 1–3; 20 cuts at 100.
        var differences = [Float](repeating: 2, count: 2000)
        differences += [Float](repeating: 1, count: 1000)
        differences += [Float](repeating: 3, count: 1000)
        differences += [Float](repeating: 100, count: 20)
        #expect(DetectionChart.calculatedThreshold(differences) == 5)
        // Repeatable.
        #expect(DetectionChart.calculatedThreshold(differences) == DetectionChart.calculatedThreshold(differences))
        #expect(DetectionChart.calculatedThreshold([]) == nil)
    }

    @Test func kMeansFindsThreeClusters() {
        var points: [KMeans.Point] = []
        for (cx, cy) in [(0.0, 0.0), (50.0, 50.0), (100.0, 0.0)] {
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] { points.append(KMeans.Point(x: cx + dx, y: cy + dy)) }
            }
        }
        let result = KMeans.cluster(points, k: 3, attempts: 5, maxIterations: 100, epsilon: 0.1, seed: 1)
        let centers = result.centers.sorted { $0.x < $1.x }
        #expect(centers.count == 3)
        for (center, expected) in zip(centers, [(0.0, 0.0), (50.0, 50.0), (100.0, 0.0)]) {
            #expect(abs(center.x - expected.0) < 1e-9 && abs(center.y - expected.1) < 1e-9)
        }
        // Each group of nine shares a label.
        for group in 0..<3 {
            #expect(Set(result.labels[(group * 9)..<(group * 9 + 9)]).count == 1)
        }
        #expect(abs(result.compactness - 3 * 12) < 1e-9)
    }
}
