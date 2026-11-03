import FrameSheetCore
import Foundation

/// What the detection chart shows (§10): the stored scan of one movie (a
/// partial one too), MoviePrint's calculated threshold, and the scan's
/// largest difference for the scale.
struct DetectionChartData: Identifiable {
    let id = UUID()
    var fileId: UUID
    var fileName: String
    var fps: Double
    var method: ShotDetectionMethod
    var differences: [Float]
    var complete: Bool
    var calculatedThreshold: Int?
    var maxDifference: Float
}

/// Scene interactions (§7) of shot sheets and timelines: Jump to cut, Hide
/// all before/after, Cut and Merge on the selected scene, and the detection
/// chart.
extension AppModel {
    // MARK: - Scenes

    /// The selected scene of the current shot sheet, for Cut and Merge.
    var selectedScene: FrameSheetCore.Scene? {
        guard let sheet = currentSheet, sheet.type == .shot, let id = selectedThumbId else { return nil }
        return sheet.scenes.first { $0.id == id }
    }

    /// Whether Merge with previous / next has a cut to merge at.
    func canMergeSelectedScene(_ neighbor: SceneNeighbor) -> Bool {
        guard let ref = currentRef, let scene = selectedScene else { return false }
        return library.cut(ref, scene: scene.id, neighbor) != nil
    }

    /// Cut: splits the selected scene at its thumb's frame (scrub the thumb
    /// first to cut elsewhere), one undo step; the first part stays selected.
    func cutSelectedScene() {
        guard let ref = currentRef, let scene = selectedScene else { return }
        cancelScrub()
        guard let thumb = currentSheet?.thumbs.first(where: { $0.id == scene.id }) else { return }
        switch edit({ $0.cutSceneAtThumb(ref, scene: scene.id) }) {
        case .cut:
            showNotice("Cut at frame \(thumb.frameNumber)")
        case .alreadyCut:
            // MoviePrint's message, with the way to cut elsewhere.
            toast = "There is already a cut at frame \(thumb.frameNumber). Scrub the thumb to the frame to cut at."
        case .notFound:
            break
        }
    }

    /// Merge with previous / next, one undo step; the merged scene is
    /// selected (MoviePrint's `onMergeSceneClick`).
    func mergeSelectedScene(_ neighbor: SceneNeighbor) {
        guard let ref = currentRef, let scene = selectedScene else { return }
        cancelScrub()
        if let merged = edit({ $0.mergeScene(ref, scene: scene.id, with: neighbor) }) {
            selectedThumbId = merged
        }
    }

    /// Jump to cut at the start (previous) or end (next) of a scene, as
    /// MoviePrint's `onJumpToCutSceneClick`: the scene that starts at the
    /// cut is selected. From the grid the sheet switches to the timeline
    /// first (`onJumpToCutThumbClick`). MoviePrint also opens the player at
    /// the cut; the player view comes with T06.
    func jumpToCut(_ neighbor: SceneNeighbor, of scene: UUID) {
        guard let ref = currentRef, let sheet = currentSheet, sheet.type == .shot else { return }
        cancelScrub()
        guard let target = library.jumpToCut(ref, scene: scene, neighbor) else {
            showNotice(neighbor == .previous ? "The first scene has no cut before it." : "The last scene has no cut after it.")
            return
        }
        if !isTimeline(sheet) { edit { $0.setView(ref, .timeline) } }
        selectedThumbId = target.scene
    }

    /// Hide all before / after a scene of the timeline (IN and OUT of its
    /// hover overlay, MoviePrint's `onHideBeforeAfterClick`), then deselect.
    func hideAll(_ position: InsertPosition, of scene: UUID) {
        guard let ref = currentRef else { return }
        edit { $0.hideAll(ref, position, of: scene) }
        selectedThumbId = nil
    }

    // MARK: - Detection chart (§10)

    /// Key F and View → Detection Chart: opens the chart for the current
    /// movie's stored scan, or closes it.
    func toggleDetectionChart() {
        if detectionChart != nil {
            detectionChart = nil
            return
        }
        guard let file = currentFile else { return }
        let data = completeScan(file.id) ?? ((try? scanStore?.load(file.id)) ?? nil)
        guard let data, !data.differences.isEmpty else {
            toast = "\(file.name) has no shot scan yet (Add shot-detection sheet)."
            return
        }
        detectionChart = DetectionChartData(
            fileId: file.id, fileName: file.name, fps: file.fps, method: data.method,
            differences: data.differences, complete: data.complete,
            calculatedThreshold: DetectionChart.calculatedThreshold(data.differences),
            maxDifference: data.differences.max() ?? 0)
    }

    /// The cuts the chart marks: the current sheet's when it is a shot
    /// sheet of the charted movie, else the scene list at the threshold.
    func chartCuts(_ chart: DetectionChartData) -> (frames: [Int], source: String) {
        if let sheet = currentSheet, sheet.type == .shot, library.currentFileId == chart.fileId {
            return (sheet.scenes.dropFirst().map(\.start), "cuts of \(sheet.name)")
        }
        let threshold = library.settings.shotDetectionThreshold
        let spans = SceneList.scenes(differences: chart.differences, threshold: threshold) { _ in [] }
        return (spans.dropFirst().map(\.start), "cuts at the threshold")
    }
}
