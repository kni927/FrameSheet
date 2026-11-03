import Foundation

// Shot sheets and their scenes (§5, §10). Ported from MoviePrint v0.2.23
// (MIT, docs/licenses/MoviePrint-LICENSE): `calculateSceneListFromDifferenceArray`
// (app/utils/utils.js), the shot sheet built from it in app/containers/App.js
// (one thumb per scene at `start + floor(length / 2)`, the thumb id is the
// scene id), and `cutScene` / `mergeScenes` (app/actions/index.js). The
// artificial scenes of interval sheets (`createSceneArray`) are
// `SceneList.intervalScenes(of:)` in IntervalEditing.swift.

/// A scene without an id: what the scan's scene list yields.
public struct SceneSpan: Sendable, Equatable {
    public var start: Int
    public var length: Int
    /// sRGB, 0–255.
    public var colorRGB: [Int]

    public init(start: Int, length: Int, colorRGB: [Int]) {
        self.start = start
        self.length = length
        self.colorRGB = colorRGB
    }

    /// The frame of the scene's thumb.
    public var middleFrame: Int { start + length / 2 }
}

extension SceneList {
    /// Frames a new cut must lie after the previous one
    /// (`SCENE_DETECTION_MIN_SCENE_LENGTH`).
    public static let minimumSceneLength = 10
    public static let lastSceneColor = [128, 128, 128]

    /// MoviePrint's `calculateSceneListFromDifferenceArray`: a cut where the
    /// difference reaches the threshold at least `minimumSceneLength` frames
    /// after the last cut. A difference at or above the threshold inside that
    /// window moves the last cut there when it is larger than the difference
    /// of the frame just before it (MoviePrint compares with the previous
    /// frame's value, which it updates on every frame). Each scene takes the
    /// mean color of its middle frame; the last scene is gray.
    public static func scenes(
        differences: [Float], threshold: Double, color: (Int) -> [Int]
    ) -> [SceneSpan] {
        guard !differences.isEmpty else { return [] }
        var lastCut = 0
        var previous: Double?
        var list: [SceneSpan] = []
        func span(_ start: Int, _ end: Int) -> SceneSpan {
            let length = end - start
            return SceneSpan(start: start, length: length, colorRGB: color(start + length / 2))
        }
        for (index, value) in differences.enumerated() {
            let difference = Double(value)
            if difference >= threshold {
                if index - lastCut >= minimumSceneLength {
                    list.append(span(lastCut, index))
                    lastCut = index
                } else if let previous, difference > previous {
                    // A more distinct cut inside the window replaces the last one.
                    let start = list.popLast()?.start ?? 0
                    list.append(span(start, index))
                    lastCut = index
                }
            }
            previous = difference
        }
        list.append(SceneSpan(start: lastCut, length: differences.count - lastCut, colorRGB: lastSceneColor))
        return list
    }

    /// The scene list of a (possibly partial) scan.
    public static func scenes(from scan: ScanData, threshold: Double) -> [SceneSpan] {
        scenes(differences: scan.differences, threshold: threshold) { scan.color(at: $0).array }
    }

    /// The scenes and thumbs of a shot sheet: one thumb per scene at its
    /// middle frame, sharing the scene's id.
    public static func shotSheetContent(_ spans: [SceneSpan], frameCount: Int) -> (thumbs: [Thumb], scenes: [Scene]) {
        let last = max(0, frameCount - 1)
        var thumbs: [Thumb] = []
        var scenes: [Scene] = []
        for (index, span) in spans.enumerated() {
            let id = UUID()
            thumbs.append(Thumb(id: id, frameNumber: min(max(0, span.middleFrame), last), index: index))
            scenes.append(Scene(id: id, start: span.start, length: span.length, colorRGB: span.colorRGB))
        }
        return (thumbs, scenes)
    }
}

extension SceneList {
    /// The scenes a sheet shows in timeline view: a shot sheet's own scenes
    /// (a scene counts as hidden when it or its thumb is; hidden ones only
    /// with `includeHidden`), or an interval sheet's artificial scenes split
    /// at the midpoints between visible thumbs. Faces sheets have none.
    public static func timelineScenes(of sheet: Sheet, includeHidden: Bool) -> [Scene] {
        switch sheet.type {
        case .shot:
            let hiddenThumbs = Set(sheet.thumbs.filter(\.hidden).map(\.id))
            return sheet.scenes.compactMap { scene in
                var scene = scene
                scene.hidden = scene.hidden || hiddenThumbs.contains(scene.id)
                return includeHidden || !scene.hidden ? scene : nil
            }
        case .interval:
            return intervalScenes(of: sheet)
        case .faces:
            return []
        }
    }
}

extension Library {
    /// Grid or timeline view; faces sheets stay in grid view (§4).
    public mutating func setView(_ ref: SheetRef, _ view: SheetView) {
        withSheet(ref) { sheet, _ in
            guard view == .grid || sheet.type != .faces else { return }
            sheet.view = view
        }
    }

    /// Convert to interval: a type change only (§5); the thumbs stay, and
    /// the timeline view splits scenes at their midpoints from then on.
    public mutating func convertToInterval(_ ref: SheetRef) {
        withSheet(ref) { sheet, _ in sheet.type = .interval }
    }

    /// Minutes per row of a sheet's timeline, 10–1800 s.
    public mutating func setSecondsPerRow(_ ref: SheetRef, _ seconds: Double) {
        let range = TimelineLayout.secondsPerRowRange
        withSheet(ref) { sheet, _ in sheet.secondsPerRow = min(max(seconds, range.lowerBound), range.upperBound) }
    }

    /// Adds a shot sheet built from a scene list; it opens in timeline view.
    @discardableResult
    public mutating func addShotSheet(to fileId: UUID, scenes spans: [SceneSpan]) -> Sheet? {
        guard let file = file(fileId) else { return nil }
        let content = SceneList.shotSheetContent(spans, frameCount: file.frameCount)
        guard let sheet = addSheet(to: fileId, type: .shot, view: .timeline, thumbs: content.thumbs) else { return nil }
        withSheet(SheetRef(fileId: fileId, sheetId: sheet.id)) { sheet, _ in sheet.scenes = content.scenes }
        return self.sheet(sheet.id, of: fileId)
    }

    /// Replaces a shot sheet's scenes and thumbs with a new scene list, for
    /// a threshold change rebuilt from the scan cache and for the scene lists
    /// a running scan streams. A scene that starts where one did keeps that
    /// scene's id (and its thumb's), so views, selection and an expanded
    /// child follow it.
    public mutating func replaceScenes(_ ref: SheetRef, with spans: [SceneSpan]) {
        withSheet(ref) { sheet, file in
            var content = SceneList.shotSheetContent(spans, frameCount: file.frameCount)
            let ids = Dictionary(sheet.scenes.map { ($0.start, $0.id) }, uniquingKeysWith: { first, _ in first })
            for i in content.scenes.indices {
                guard let id = ids[content.scenes[i].start] else { continue }
                content.scenes[i].id = id
                content.thumbs[i].id = id
            }
            sheet.thumbs = content.thumbs
            sheet.scenes = content.scenes
        }
    }

    /// MoviePrint's `cutScene`: splits a scene at `frame` (which must lie
    /// inside it, after its first frame). The first part keeps the scene's
    /// id; the second part gets a new id, the scene's color, and a new thumb
    /// after the first part's thumb. Both thumbs move to their part's middle
    /// frame. Returns the new scene's id.
    @discardableResult
    public mutating func cutScene(_ ref: SheetRef, scene id: UUID, at frame: Int) -> UUID? {
        withSheet(ref) { sheet, file -> UUID? in
            guard let s = sheet.scenes.firstIndex(where: { $0.id == id }) else { return nil }
            let scene = sheet.scenes[s]
            guard frame > scene.start, frame < scene.start + scene.length else { return nil }
            let firstLength = frame - scene.start
            let nextLength = scene.start + scene.length - frame
            let nextId = UUID()
            sheet.scenes[s].length = firstLength
            sheet.scenes.insert(
                Scene(id: nextId, start: frame, length: nextLength, colorRGB: scene.colorRGB), at: s + 1)
            let firstThumb = sheet.thumbs.firstIndex { $0.id == id }
            if let firstThumb {
                sheet.thumbs[firstThumb].frameNumber = file.clampFrame(scene.start + firstLength / 2)
            }
            let thumb = Thumb(id: nextId, frameNumber: file.clampFrame(frame + nextLength / 2), index: 0)
            sheet.thumbs.insert(thumb, at: firstThumb.map { $0 + 1 } ?? sheet.thumbs.count)
            sheet.reindex()
            return nextId
        } ?? nil
    }

    /// MoviePrint's `getAdjacentSceneIndicesFromCut`: the scene starting at
    /// `frame` and the one before it, or nil when no cut lies there.
    public func adjacentSceneIndices(_ ref: SheetRef, cut frame: Int) -> (Int, Int)? {
        guard let scenes = sheet(ref.sheetId, of: ref.fileId)?.scenes,
              let i = scenes.firstIndex(where: { $0.start == frame }), i > 0
        else { return nil }
        return (i - 1, i)
    }

    /// MoviePrint's `mergeScenes`: joins the scene starting at `frame` with
    /// the one before it. The first keeps its id and color, takes both
    /// lengths, and its thumb moves to the joined middle frame; the second
    /// scene and its thumb go. Returns whether a cut was merged.
    @discardableResult
    public mutating func mergeScenes(_ ref: SheetRef, cut frame: Int) -> Bool {
        guard let pair = adjacentSceneIndices(ref, cut: frame) else { return false }
        let (first, second) = pair
        return withSheet(ref) { sheet, file -> Bool in
            let a = sheet.scenes[first]
            let b = sheet.scenes[second]
            let length = a.length + b.length
            sheet.scenes[first].length = length
            sheet.scenes.remove(at: second)
            sheet.thumbs.removeAll { $0.id == b.id }
            if let t = sheet.thumbs.firstIndex(where: { $0.id == a.id }) {
                sheet.thumbs[t].frameNumber = file.clampFrame(a.start + length / 2)
            }
            sheet.reindex()
            return true
        } ?? false
    }
}
