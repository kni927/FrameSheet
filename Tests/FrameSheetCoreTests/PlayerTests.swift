import Foundation
import Testing
@testable import FrameSheetCore

@Suite struct PlayerNavigationTests {
    /// Scenes 0–9, 10–29, 30–59 of a 60-frame movie.
    private let scenes = [
        Scene(id: UUID(), start: 0, length: 10, colorRGB: [0, 0, 0]),
        Scene(id: UUID(), start: 10, length: 20, colorRGB: [0, 0, 0]),
        Scene(id: UUID(), start: 30, length: 30, colorRGB: [0, 0, 0]),
    ]

    @Test func arrowSteps() {
        #expect(PlayerNavigation.arrowStep(shift: false, option: false) == 10)
        #expect(PlayerNavigation.arrowStep(shift: true, option: false) == 1)
        #expect(PlayerNavigation.arrowStep(shift: false, option: true) == 100)
    }

    @Test func stepsStayInsideTheMovie() {
        #expect(PlayerNavigation.step(50, by: 10, frameCount: 100) == 60)
        #expect(PlayerNavigation.step(95, by: 10, frameCount: 100) == 99)
        #expect(PlayerNavigation.step(5, by: -100, frameCount: 100) == 0)
        #expect(PlayerNavigation.step(0, by: -1, frameCount: 100) == 0)
        #expect(PlayerNavigation.step(99, by: 1, frameCount: 100) == 99)
        #expect(PlayerNavigation.step(3, by: 1, frameCount: 0) == 0)
    }

    @Test func sceneAtAFrame() {
        #expect(PlayerNavigation.scene(containing: 0, in: scenes)?.id == scenes[0].id)
        #expect(PlayerNavigation.scene(containing: 10, in: scenes)?.id == scenes[1].id)
        #expect(PlayerNavigation.scene(containing: 29, in: scenes)?.id == scenes[1].id)
        // Outside the scenes' span: the nearest end.
        #expect(PlayerNavigation.scene(containing: -5, in: scenes)?.id == scenes[0].id)
        #expect(PlayerNavigation.scene(containing: 80, in: scenes)?.id == scenes[2].id)
        #expect(PlayerNavigation.scene(containing: 3, in: []) == nil)
        #expect(PlayerNavigation.selection(at: 31, scenes: scenes) == scenes[2].id)
    }

    @Test func cutJumps() {
        // Back from inside a scene: its first frame, the selection stays.
        let inside = PlayerNavigation.cutJump(.previous, from: 15, scenes: scenes, frameCount: 60)
        #expect(inside?.frame == 10)
        #expect(inside?.scene == nil)
        // Back from a cut: the previous scene's first frame.
        let atCut = PlayerNavigation.cutJump(.previous, from: 10, scenes: scenes, frameCount: 60)
        #expect(atCut?.frame == 0)
        #expect(atCut?.scene == scenes[0].id)
        // Back at the movie's start stays there.
        #expect(PlayerNavigation.cutJump(.previous, from: 0, scenes: scenes, frameCount: 60)?.frame == 0)
        // Forward: the next scene's first frame.
        let next = PlayerNavigation.cutJump(.next, from: 15, scenes: scenes, frameCount: 60)
        #expect(next?.frame == 30)
        #expect(next?.scene == scenes[2].id)
        // Forward from the last scene: the movie's last frame.
        let end = PlayerNavigation.cutJump(.next, from: 40, scenes: scenes, frameCount: 60)
        #expect(end?.frame == 59)
        #expect(end?.scene == scenes[2].id)
        #expect(PlayerNavigation.cutJump(.next, from: 3, scenes: [], frameCount: 60) == nil)
    }

    @Test func thumbJumpsOnShotSheets() {
        let thumbs = scenes.enumerated().map { i, scene in
            Thumb(id: scene.id, frameNumber: scene.start + scene.length / 2, index: i)
        }
        let back = PlayerNavigation.thumbJump(
            .previous, from: 15, selected: nil, sheetType: .shot, thumbs: thumbs, scenes: scenes, frameCount: 60)
        #expect(back?.thumb == scenes[0].id)
        #expect(back?.frame == 5)
        let forward = PlayerNavigation.thumbJump(
            .next, from: 15, selected: nil, sheetType: .shot, thumbs: thumbs, scenes: scenes, frameCount: 60)
        #expect(forward?.thumb == scenes[2].id)
        #expect(forward?.frame == 45)
        // The first scene's previous is itself (getSceneFromFrameNumber clamps).
        let first = PlayerNavigation.thumbJump(
            .previous, from: 2, selected: nil, sheetType: .shot, thumbs: thumbs, scenes: scenes, frameCount: 60)
        #expect(first?.thumb == scenes[0].id)
    }

    @Test func thumbJumpsOnIntervalSheets() {
        let thumbs = [10, 20, 30].enumerated().map { Thumb(frameNumber: $1, index: $0) }
        func jump(_ direction: SceneNeighbor, _ selected: UUID?) -> (frame: Int, thumb: UUID)? {
            PlayerNavigation.thumbJump(
                direction, from: 0, selected: selected, sheetType: .interval, thumbs: thumbs, scenes: [],
                frameCount: 25)
        }
        #expect(jump(.next, thumbs[0].id)?.thumb == thumbs[1].id)
        #expect(jump(.previous, thumbs[1].id)?.thumb == thumbs[0].id)
        // Stops at the ends.
        #expect(jump(.previous, thumbs[0].id)?.thumb == thumbs[0].id)
        #expect(jump(.next, thumbs[2].id)?.thumb == thumbs[2].id)
        // Frames past the movie are kept inside it.
        #expect(jump(.next, thumbs[1].id)?.frame == 24)
        // Without a selection: the first or last thumb.
        #expect(jump(.next, nil)?.thumb == thumbs[0].id)
        #expect(jump(.previous, nil)?.thumb == thumbs[2].id)
        #expect(PlayerNavigation.thumbJump(
            .next, from: 0, selected: nil, sheetType: .interval, thumbs: [], scenes: [], frameCount: 25) == nil)
    }

    @Test func playerScenes() {
        var sheet = Sheet(name: "Sheet-1", type: .shot)
        sheet.scenes = scenes
        sheet.scenes[1].hidden = true
        sheet.thumbs = scenes.enumerated().map { Thumb(id: $1.id, frameNumber: $1.start, index: $0) }
        // A shot sheet's cuts include hidden scenes.
        #expect(PlayerNavigation.scenes(of: sheet, includeHidden: false).count == 3)
        sheet.type = .faces
        #expect(PlayerNavigation.scenes(of: sheet, includeHidden: true).isEmpty)
    }

    @Test func frameAtPlayerTime() {
        #expect(PlayerNavigation.frame(atSeconds: 0, startTime: 0, fps: 25, frameCount: 100) == 0)
        #expect(PlayerNavigation.frame(atSeconds: 0.039, startTime: 0, fps: 25, frameCount: 100) == 0)
        #expect(PlayerNavigation.frame(atSeconds: 0.04, startTime: 0, fps: 25, frameCount: 100) == 1)
        // A time a hair before a frame's start through rounding.
        #expect(PlayerNavigation.frame(atSeconds: 0.4 - 1e-9, startTime: 0, fps: 25, frameCount: 100) == 10)
        #expect(PlayerNavigation.frame(atSeconds: 1.1, startTime: 0.1, fps: 25, frameCount: 100) == 25)
        #expect(PlayerNavigation.frame(atSeconds: 10, startTime: 0, fps: 25, frameCount: 100) == 99)
        #expect(PlayerNavigation.frame(atSeconds: .nan, startTime: 0, fps: 25, frameCount: 100) == 0)
    }

    @Test func modes() {
        #expect(PlayerMode.cut.toggled == .thumb)
        #expect(FrameStripGeometry.sliceCount(for: .cut) == 20)
        #expect(FrameStripGeometry.sliceCount(for: .thumb) == 19)
    }
}

@Suite struct FrameStripGeometryTests {
    @Test func evenCountHasTwoMiddleSlices() {
        // 1000 − 8 − 20 × 1 = 972; a quarter is 243.
        let widths = FrameStripGeometry.sliceWidths(stripWidth: 1000, frameWidth: 400, count: 20)
        #expect(widths.count == 20)
        #expect(widths[9] == 243)
        #expect(widths[10] == 243)
        #expect(widths[8] == 121)
        #expect(widths[11] == 121)
        #expect(widths[7] == 60)
        #expect(widths[0] == 1)
        #expect(widths[19] == 1)
    }

    @Test func oddCountHasOneMiddleSlice() {
        // 1000 − 8 − 19 = 973; a third is 324; one more slice on the right.
        let widths = FrameStripGeometry.sliceWidths(stripWidth: 1000, frameWidth: 400, count: 19)
        #expect(widths[8] == 324)
        #expect(widths[7] == 162)
        #expect(widths[9] == 162)
        #expect(widths[10] == 81)
        #expect(widths[0] == 1)
        #expect(widths[18] == 1)
    }

    @Test func slicesAreAtMostTheFrameWide() {
        let widths = FrameStripGeometry.sliceWidths(stripWidth: 1000, frameWidth: 200, count: 20)
        #expect(widths[9] == 200)
        #expect(widths[8] == 121)
    }

    @Test func framesAroundTheCurrentOne() {
        let even = FrameStripGeometry(
            stripWidth: 1000, frameWidth: 400, count: 20, currentFrame: 100, frameCount: 1000, cuts: [])
        #expect(even.slices.first?.frame == 90)
        #expect(even.slices.last?.frame == 109)
        #expect(even.currentIndex == 10)
        #expect(even.slices[even.currentIndex].frame == 100)
        #expect(even.slices[even.currentIndex].width == 243)
        let odd = FrameStripGeometry(
            stripWidth: 1000, frameWidth: 400, count: 19, currentFrame: 100, frameCount: 1000, cuts: [])
        #expect(odd.slices.first?.frame == 92)
        #expect(odd.currentIndex == 8)
        #expect(odd.slices[odd.currentIndex].frame == 100)
        #expect(odd.slices[odd.currentIndex].width == 324)
    }

    @Test func gapsAndCrops() {
        let strip = FrameStripGeometry(
            stripWidth: 1000, frameWidth: 400, count: 20, currentFrame: 100, frameCount: 1000, cuts: [100])
        let s = strip.slices
        // 1 pt between slices, 8 before the slice that starts a scene.
        #expect(s[1].x == s[0].x + s[0].width + 1)
        #expect(s[10].x == s[9].x + s[9].width + 8)
        #expect(s[11].x == s[10].x + s[10].width + 1)
        // The middle of the frame: 200 − 121.
        #expect(s[10].cropX == 79)
        #expect(s[10].x + s[10].width <= 1000)
        #expect((s.last.map { $0.x + $0.width } ?? 0) <= 1000)
    }

    @Test func slicesOutsideTheMovieStayEmpty() {
        let start = FrameStripGeometry(
            stripWidth: 1000, frameWidth: 400, count: 20, currentFrame: 3, frameCount: 50, cuts: [])
        #expect(start.slices.prefix(7).allSatisfy { !$0.inMovie })
        #expect(start.frames.first == 0)
        #expect(start.frames.count == 13)
        let end = FrameStripGeometry(
            stripWidth: 1000, frameWidth: 400, count: 19, currentFrame: 49, frameCount: 50, cuts: [])
        #expect(end.frames.last == 49)
        #expect(end.frames.count == 9)
    }
}

@Suite struct PlayerTimelineTests {
    @Test func movieBar() {
        let bar = PlayerTimelineGeometry(width: 1000, frameCount: 1001, sceneIn: 10, sceneOut: 19)
        #expect(bar.frameWidth == 2)
        #expect(bar.playheadX(frame: 0) == 0)
        #expect(bar.playheadX(frame: 500) == 499)
        #expect(bar.playheadX(frame: 1000) == 998)
        #expect(bar.frame(atX: 499) == 500)
        #expect(bar.frame(atX: -20) == 0)
        #expect(bar.frame(atX: 5000) == 1000)
        let range = bar.range(from: 100, to: 100)
        #expect(range.width == PlayerTimelineGeometry.minimumRangeWidth)
    }

    @Test func sceneBar() {
        let bar = PlayerTimelineGeometry(width: 1000, frameCount: 1001, sceneIn: 10, sceneOut: 19)
        #expect(bar.sceneLength == 10)
        #expect(bar.sceneFrameWidth == 100)
        #expect(bar.scenePlayheadX(frame: 10) == 0)
        #expect(bar.scenePlayheadX(frame: 19) == 900)
        #expect(bar.sceneFrame(atX: 0) == 10)
        #expect(bar.sceneFrame(atX: 450) == 14)
        #expect(bar.sceneFrame(atX: 900) == 19)
        #expect(bar.sceneFrame(atX: 2000) == 19)
        let single = PlayerTimelineGeometry(width: 1000, frameCount: 100, sceneIn: 5, sceneOut: 5)
        #expect(single.sceneFrame(atX: 600) == 5)
    }

    @Test func sceneBars() {
        let scenes = [
            Scene(id: UUID(), start: 0, length: 100, colorRGB: []),
            Scene(id: UUID(), start: 100, length: 5, colorRGB: []),
        ]
        let widths = PlayerSceneBars.widths(scenes: scenes, minSceneLength: 10, selected: nil, fullWidth: 160)
        #expect(widths == [30, 3])
        let selected = PlayerSceneBars.widths(scenes: scenes, minSceneLength: 10, selected: scenes[1].id, fullWidth: 160.7)
        #expect(selected == [30, 160])
    }
}
