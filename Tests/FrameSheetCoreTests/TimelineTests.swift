import Foundation
import Testing
@testable import FrameSheetCore

private func movie(frameCount: Int = 1000, fps: Double = 25) -> MovieFile {
    MovieFile(
        url: URL(fileURLWithPath: "/movies/a.mp4"), duration: Double(frameCount) / fps, frameCount: frameCount,
        fps: fps, width: 1920, height: 1080, size: 1, fourCC: "avc1")
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) < tolerance }

@Suite struct TimelineLayoutTests {
    @Test func rowsCloseWhenTheSumPassesTheLimit() {
        let rows = TimelineLayout.scenesInRows(lengths: [100, 100, 100], framesPerRow: 250)
        #expect(rows.map(\.sceneLengths) == [[100, 100], [100]])
        #expect(rows.map(\.lastIndex) == [1, 2])
        #expect(rows.map(\.sceneOutPoint) == [200, 300])
        // Exactly at the limit stays in the row.
        #expect(TimelineLayout.scenesInRows(lengths: [100, 100], framesPerRow: 200).map(\.itemCount) == [2])
    }

    @Test func aLongSceneGetsItsOwnRow() {
        let rows = TimelineLayout.scenesInRows(lengths: [500, 50, 60], firstStart: 10, framesPerRow: 250)
        #expect(rows.map(\.sceneLengths) == [[500], [50, 60]])
        #expect(rows.map(\.lastIndex) == [0, 2])
        #expect(rows.map(\.sceneOutPoint) == [510, 620])
        #expect(TimelineLayout.scenesInRows(lengths: [], framesPerRow: 250).isEmpty)
    }

    @Test func pixelPerFrameCountsShortScenesAtTheMinimum() throws {
        let rows = [
            TimelineRow(lastIndex: 1, sceneOutPoint: 105, sceneLengths: [100, 5]),
            TimelineRow(lastIndex: 2, sceneOutPoint: 155, sceneLengths: [50]),
        ]
        let ppf = try #require(TimelineLayout.pixelPerFrameRatio(rows: rows, margin: 1, width: 300, minSceneLength: 10))
        // Row 1: (300 − 2 · 2) / (10 + 100); row 2: (300 − 2) / 50; the minimum.
        #expect(near(ppf, 296.0 / 110))
        #expect(TimelineLayout.pixelPerFrameRatio(rows: [], margin: 1, width: 300, minSceneLength: 10) == nil)
    }

    @Test func widthMultiplier() {
        #expect(near(TimelineLayout.widthMultiplier(sceneWidthRatio: 0), 0.1))
        #expect(near(TimelineLayout.widthMultiplier(sceneWidthRatio: 50), 50 / 55.5555 + 0.1))
        #expect(near(TimelineLayout.widthMultiplier(sceneWidthRatio: 100), 50 / 5.55555 + 1))
    }

    @Test func statsLine() {
        // 10 minutes at 25 fps, 100 shots: round(99 / 10) = 10 cuts per minute.
        #expect(TimelineLayout.statsLine(shots: 100, frameCount: 15_000, fps: 25) == "100 Shots / ~10 Minutes ≈ 10 cut/min")
        #expect(TimelineLayout.statsLine(shots: 1, frameCount: 1500, fps: 25) == "1 Shot / ~1 Minute ≈ 0 cut/min")
        #expect(TimelineLayout.stats(shots: 0, frameCount: 0, fps: 25) == (0, 0))
    }

    @Test func minSceneWidthInSecondsAndFrames() {
        #expect(TimelineLayout.minSceneFrames(seconds: 2, fps: 23.976) == 48)
        #expect(TimelineLayout.minSceneSeconds(frames: 48, fps: 23.976) == 2)
        #expect(TimelineLayout.minSceneSeconds(frames: 10, fps: 25) == 0)
    }
}

@Suite struct TimelineGeometryTests {
    /// Four 100-frame scenes, 8 s per row at 25 fps (200 frames): two rows.
    private func input(expanded: Int? = nil, naturalFlow: Bool = false, secondsPerRow: Double = 8) -> TimelineGeometry.Input {
        TimelineGeometry.Input(
            movieWidth: 1920, movieHeight: 1080, sceneLengths: [100, 100, 100, 100], fps: 25,
            secondsPerRow: secondsPerRow, sceneWidthRatio: 50, minSceneLength: 0, marginRatioHorizontal: 0.02,
            marginRatioVertical: 0.02, naturalFlow: naturalFlow, containerWidth: .greatestFiniteMagnitude,
            containerHeight: 1024, expandedIndex: expanded)
    }

    @Test func rowsAndBoxes() {
        let g = TimelineGeometry(input())
        let width = 1024 * TimelineLayout.widthMultiplier(sceneWidthRatio: 50)
        #expect(g.rows.count == 2)
        #expect(near(g.scale, 1))
        #expect(near(g.printWidth, width))
        // Margin = 0.02 × 50 = 1; row height = (1024 − 1 · 2 · 2) / 2.
        #expect(near(g.marginHorizontal, 1))
        #expect(near(g.rowHeight, 510))
        #expect(near(g.pixelPerFrame, (width - 4) / 200))
        let f = g.sceneFrames
        #expect(f.count == 4)
        #expect(near(f[0].minX, 1) && near(f[0].minY, 1))
        #expect(near(f[0].width, g.pixelPerFrame * 100))
        #expect(near(f[1].minX, 1 + f[0].width + 2))
        #expect(near(f[2].minX, 1) && near(f[2].minY, 510 + 2 + 1))
        #expect(near(f[3].maxX + 1, width, 1e-6))
    }

    @Test func minimumSceneWidth() {
        var i = input()
        i.sceneLengths = [190, 5, 100, 100]
        i.minSceneLength = 10
        let g = TimelineGeometry(i)
        #expect(near(g.sceneFrames[1].width, g.pixelPerFrame * 10))
        #expect(near(g.sceneFrames[0].width, g.pixelPerFrame * 190))
    }

    @Test func expandedSceneHasFullAspectWidth() {
        let g = TimelineGeometry(input(expanded: 0))
        #expect(near(g.sceneFrames[0].width, 510 * 1920 / 1080))
        #expect(near(g.fullWidth, 510 * 1920 / 1080))
        // Without natural flow the row keeps its scenes and grows past the edge.
        #expect(g.sceneFrames[1].minY == g.sceneFrames[0].minY)
        #expect(g.contentSize.width > g.printWidth)
    }

    @Test func naturalFlowWrapsByWidth() {
        // One row of four by time; the expanded first scene pushes the
        // second one to the next line.
        let g = TimelineGeometry(input(expanded: 0, naturalFlow: true, secondsPerRow: 1000))
        #expect(g.rows.count == 1)
        #expect(near(g.sceneFrames[1].minX, 1))
        #expect(g.sceneFrames[1].minY > g.sceneFrames[0].minY)
        let flat = TimelineGeometry(input(naturalFlow: true, secondsPerRow: 1000))
        #expect(Set(flat.sceneFrames.map(\.minY)).count == 1)
    }

    @Test func fitAndScale() {
        var i = input()
        i.containerWidth = 500
        i.containerHeight = 2048
        i.zoom = 2
        let g = TimelineGeometry(i)
        let width = 1024 * TimelineLayout.widthMultiplier(sceneWidthRatio: 50)
        #expect(near(g.fitWidthScale, 500 / width))
        #expect(near(g.scale, 500 / width * 2))
        #expect(near(g.rowHeight, 510 * g.scale))
        #expect(g.hasSpaceAboveAndBelow)
        #expect(!g.hasSpaceAtSides)
    }

    @Test func usesTheMoviesFps() {
        // 120 s per row at 50 fps holds 6000 frames, at 25 fps 3000.
        var sheet = Sheet(name: "Sheet-1", type: .shot)
        sheet.scenes = (0..<4).map { Scene(id: UUID(), start: $0 * 2000, length: 2000, colorRGB: [1, 2, 3]) }
        let at50 = TimelineGeometry(.init(
            file: movie(frameCount: 8000, fps: 50), sheet: sheet, scenes: sheet.scenes, settings: Settings(),
            containerWidth: 1000, containerHeight: 1000))
        let at25 = TimelineGeometry(.init(
            file: movie(frameCount: 8000, fps: 25), sheet: sheet, scenes: sheet.scenes, settings: Settings(),
            containerWidth: 1000, containerHeight: 1000))
        #expect(at50.rows.count == 2)
        #expect(at25.rows.count == 4)
    }
}

@Suite struct TimelineSheetTests {
    private func fixture() -> (Library, SheetRef) {
        var library = Library()
        let file = movie()
        library.files.append(file)
        let spans = [
            SceneSpan(start: 0, length: 300, colorRGB: [10, 20, 30]),
            SceneSpan(start: 300, length: 500, colorRGB: [40, 50, 60]),
            SceneSpan(start: 800, length: 200, colorRGB: [128, 128, 128]),
        ]
        let sheet = library.addShotSheet(to: file.id, scenes: spans)!
        return (library, SheetRef(fileId: file.id, sheetId: sheet.id))
    }

    @Test func shotScenesFollowTheirThumbsHidden() {
        var (library, ref) = fixture()
        let sheet = library.sheet(ref.sheetId, of: ref.fileId)!
        library.setHidden(ref, thumbs: [sheet.thumbs[1].id], hidden: true)
        let hidden = library.sheet(ref.sheetId, of: ref.fileId)!
        #expect(SceneList.timelineScenes(of: hidden, includeHidden: false).map(\.start) == [0, 800])
        let all = SceneList.timelineScenes(of: hidden, includeHidden: true)
        #expect(all.map(\.hidden) == [false, true, false])
        #expect(all.map(\.id) == hidden.thumbs.map(\.id))
    }

    @Test func intervalSheetsSplitAtMidpoints() {
        var library = Library()
        let file = movie()
        library.files.append(file)
        let sheet = library.addSheet(to: file.id, type: .interval, thumbs: [0, 100, 300].enumerated().map {
            Thumb(frameNumber: $1, index: $0)
        })!
        let scenes = SceneList.timelineScenes(of: sheet, includeHidden: true)
        #expect(scenes.map(\.start) == [0, 51, 201])
        #expect(scenes.map(\.id) == sheet.thumbs.map(\.id))
        #expect(SceneList.timelineScenes(of: Sheet(name: "F", type: .faces), includeHidden: true).isEmpty)
    }

    @Test func viewTypeAndSecondsPerRow() {
        var (library, ref) = fixture()
        #expect(library.sheet(ref.sheetId, of: ref.fileId)?.view == .timeline)
        library.setView(ref, .grid)
        #expect(library.sheet(ref.sheetId, of: ref.fileId)?.view == .grid)
        library.setSecondsPerRow(ref, 5)
        #expect(library.sheet(ref.sheetId, of: ref.fileId)?.secondsPerRow == 10)
        library.setSecondsPerRow(ref, 5000)
        #expect(library.sheet(ref.sheetId, of: ref.fileId)?.secondsPerRow == 1800)
        library.convertToInterval(ref)
        let converted = library.sheet(ref.sheetId, of: ref.fileId)!
        #expect(converted.type == .interval)
        #expect(converted.thumbs.count == 3)

        var faces = library
        let facesSheet = faces.addSheet(to: ref.fileId, type: .faces, thumbs: [])!
        let facesRef = SheetRef(fileId: ref.fileId, sheetId: facesSheet.id)
        faces.setView(facesRef, .timeline)
        #expect(faces.sheet(facesSheet.id, of: ref.fileId)?.view == .grid)
    }

    @Test func expandUsesTheShotScene() throws {
        var (library, ref) = fixture()
        let thumb = library.sheet(ref.sheetId, of: ref.fileId)!.thumbs[1]
        let expanded = library.expand(ref, thumb: thumb.id)
        let child = try #require(expanded)
        let sheet = try #require(library.sheet(child.sheetId, of: ref.fileId))
        // §3: an expanded shot is named by its number.
        #expect(sheet.name == "Shot #2")
        #expect(sheet.thumbs.first?.frameNumber == 300)
        #expect(sheet.thumbs.last?.frameNumber == 799)
    }

    @Test func savePlanInTimelineView() {
        let (library, ref) = fixture()
        let file = library.file(ref.fileId)!
        let sheet = library.sheet(ref.sheetId, of: ref.fileId)!
        var settings = Settings()
        let plan = PrintOutput.Plan(file: file, sheet: sheet, settings: settings)
        // The size is the height; width = height × multiplier.
        #expect(plan.height == 4096)
        #expect(plan.width == Int((4096 * TimelineLayout.widthMultiplier(sceneWidthRatio: 50)).rounded()))
        #expect(plan.thumbs.map(\.id) == sheet.thumbs.map(\.id))
        guard case .timeline(let geometry, let scenes) = plan.layout else {
            Issue.record("timeline layout expected")
            return
        }
        #expect(near(geometry.printHeight, 4096))
        #expect(scenes.count == 3)
        // Max with a wide timeline keeps the width within 16384.
        settings.timelineSceneWidthRatio = 100
        settings.outputSizeMax = true
        let wide = PrintOutput.Plan(file: file, sheet: sheet, settings: settings)
        #expect(wide.width <= OutputSize.limit)
        #expect(wide.height == PrintOutput.timelineHeight(
            selected: 4096, useMax: true, widthMultiplier: TimelineLayout.widthMultiplier(sceneWidthRatio: 100)))
        #expect(PrintOutput.timelineHeight(selected: 4096, useMax: true, widthMultiplier: 0.5) == 16384)
    }
}

@Suite struct ThumbLabelFormatTests {
    @Test func frameFormats() {
        #expect(FrameInfoText.text(.frames, frame: 9920, fps: 25, frameFormat: .frame, frameCount: 17605) == "9920")
        #expect(FrameInfoText.text(.frames, frame: 9920, fps: 25, frameFormat: .frameOfLast, frameCount: 17605) == "9920 / 17604")
        #expect(FrameInfoText.text(.frames, frame: 42, fps: 25, frameFormat: .frameOfLast, frameCount: 1000) == "0042 / 0999")
        // Timecode ignores the frame format.
        #expect(FrameInfoText.text(.timecode, frame: 25 * 61 + 3, fps: 25, frameFormat: .frameOfLast, frameCount: 1000) == "00:01:01:03")
        #expect(FrameInfoText.text(.hidden, frame: 1, fps: 25, frameFormat: .frameOfLast, frameCount: 1000) == nil)
    }

    @Test func settingsDecodeTolerantly() throws {
        var settings = Settings()
        settings.frameInfoFrameFormat = .frameOfLast
        settings.timelineShowImages = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.frameInfoFrameFormat == .frameOfLast)
        #expect(decoded.timelineShowImages == false)
        let odd = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"frameInfoFrameFormat": "bogus", "timelineShowImages": 3}"#.utf8))
        #expect(odd.frameInfoFrameFormat == .frame)
        #expect(odd.timelineShowImages == true)
        let empty = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(empty.frameInfoFrameFormat == .frame)
    }
}
