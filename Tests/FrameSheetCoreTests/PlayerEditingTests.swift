import CoreGraphics
import Foundation
import Testing
@testable import FrameSheetCore

/// A 300-frame movie with a shot sheet of three scenes, 0–99, 100–199 and
/// 200–299, and a default interval sheet.
private func fixture() -> (Library, shot: SheetRef, interval: SheetRef) {
    var library = Library()
    let file = MovieFile(
        url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 12, frameCount: 300, fps: 25,
        width: 640, height: 360, size: 1, fourCC: "avc1")
    library.files.append(file)
    let shot = library.addShotSheet(to: file.id, scenes: [
        SceneSpan(start: 0, length: 100, colorRGB: [10, 20, 30]),
        SceneSpan(start: 100, length: 100, colorRGB: [40, 50, 60]),
        SceneSpan(start: 200, length: 100, colorRGB: [128, 128, 128]),
    ])!
    let interval = library.addDefaultIntervalSheet(to: file.id)!
    return (library, SheetRef(fileId: file.id, sheetId: shot.id), SheetRef(fileId: file.id, sheetId: interval.id))
}

private extension Library {
    func scenes(_ ref: SheetRef) -> [Scene] { sheet(ref.sheetId, of: ref.fileId)!.scenes }
    func thumbs(_ ref: SheetRef) -> [Thumb] { sheet(ref.sheetId, of: ref.fileId)!.thumbs }
}

@Suite struct PlayerEditingTests {
    @Test func cutOrMergeByFrame() {
        let (library, shot, _) = fixture()
        #expect(library.playerCutAction(shot, at: 100) == .merge)
        #expect(library.playerCutAction(shot, at: 200) == .merge)
        #expect(library.playerCutAction(shot, at: 150) == .cut)
        // The movie's first frame is no cut.
        #expect(library.playerCutAction(shot, at: 0) == .cut)
    }

    @Test func cutAtAFrame() throws {
        var (library, shot, _) = fixture()
        let result = library.cutScene(shot, at: 130)
        guard case .cut(let id) = result else {
            Issue.record("expected a cut, got \(result)")
            return
        }
        #expect(library.scenes(shot).map(\.start) == [0, 100, 130, 200])
        #expect(library.scenes(shot).map(\.length) == [100, 30, 70, 100])
        #expect(library.scenes(shot)[2].id == id)
        // Both parts' thumbs at their middle frames.
        #expect(library.thumbs(shot).map(\.frameNumber) == [50, 115, 165, 250])
        #expect(library.playerCutAction(shot, at: 130) == .merge)
    }

    @Test func cutAtAnExistingCutOrTheStart() {
        var (library, shot, _) = fixture()
        let before = library
        let atCut = library.cutScene(shot, at: 100)
        let atStart = library.cutScene(shot, at: 0)
        let outside = library.cutScene(shot, at: 300)
        #expect(atCut == .alreadyCut)
        #expect(atStart == .alreadyCut)
        #expect(outside == .notFound)
        #expect(library == before)
    }

    @Test func mergeAtACutsFirstFrame() {
        var (library, shot, _) = fixture()
        let first = library.scenes(shot)[0].id
        let merged = library.mergeScenes(shot, atCut: 100)
        #expect(merged == first)
        #expect(library.scenes(shot).map(\.start) == [0, 200])
        #expect(library.scenes(shot).map(\.length) == [200, 100])
        #expect(library.thumbs(shot).map(\.frameNumber) == [100, 250])
        // Inside a scene there is nothing to merge.
        let inside = library.mergeScenes(shot, atCut: 150)
        let atStart = library.mergeScenes(shot, atCut: 0)
        #expect(inside == nil)
        #expect(atStart == nil)
    }

    @Test func cutThenMergeIsOneUndoStepEach() {
        let (start, shot, _) = fixture()
        var document = EditableLibrary(start)
        _ = document.edit { $0.cutScene(shot, at: 130) }
        _ = document.edit { $0.mergeScenes(shot, atCut: 130) }
        #expect(document.library.scenes(shot).map(\.start) == [0, 100, 200])
        let undone = document.undo()
        #expect(undone)
        #expect(document.library.scenes(shot).map(\.start) == [0, 100, 130, 200])
        let undoneAgain = document.undo()
        #expect(undoneAgain)
        #expect(document.library.scenes(shot) == start.scenes(shot))
    }

    @Test func thumbActionKeys() {
        #expect(PlayerThumbAction.forKeys(shift: false, option: false, sheetType: .interval) == .change)
        #expect(PlayerThumbAction.forKeys(shift: true, option: false, sheetType: .interval) == .add(.before))
        #expect(PlayerThumbAction.forKeys(shift: false, option: true, sheetType: .interval) == .add(.after))
        // Shot sheets only change (MoviePrint's grid view of scenes).
        #expect(PlayerThumbAction.forKeys(shift: true, option: false, sheetType: .shot) == .change)
        #expect(PlayerThumbAction.forKeys(shift: false, option: true, sheetType: .shot) == .change)
    }

    @Test func changeOnAShotSheetMovesTheScenesThumb() {
        var (library, shot, _) = fixture()
        let second = library.scenes(shot)[1].id
        let changed = library.applyPlayerThumbAction(shot, .add(.after), at: 120, selected: nil)
        #expect(changed == second)
        #expect(library.thumbs(shot).map(\.frameNumber) == [50, 120, 250])
        #expect(library.thumbs(shot).count == 3)
        // The scene at the frame, whatever is selected.
        let first = library.scenes(shot)[0].id
        let changedFirst = library.applyPlayerThumbAction(shot, .change, at: 7, selected: second)
        #expect(changedFirst == first)
        #expect(library.thumbs(shot).map(\.frameNumber) == [7, 120, 250])
    }

    @Test func changeAndAddOnAnIntervalSheet() throws {
        var (library, _, interval) = fixture()
        let thumbs = library.thumbs(interval)
        let selected = thumbs[2]
        // Change.
        let changed = library.applyPlayerThumbAction(interval, .change, at: 77, selected: selected.id)
        #expect(changed == selected.id)
        #expect(library.thumbs(interval)[2].frameNumber == 77)
        #expect(library.thumbs(interval).count == thumbs.count)
        // Add before: a new thumb at the frame, in the selected one's place.
        let added = library.applyPlayerThumbAction(interval, .add(.before), at: 70, selected: selected.id)
        let before = try #require(added)
        #expect(library.thumbs(interval)[2].id == before)
        #expect(library.thumbs(interval)[2].frameNumber == 70)
        #expect(library.thumbs(interval)[3].id == selected.id)
        // Add after: right after the selected one.
        let addedAfter = library.applyPlayerThumbAction(interval, .add(.after), at: 80, selected: selected.id)
        let after = try #require(addedAfter)
        #expect(library.thumbs(interval)[4].id == after)
        #expect(library.thumbs(interval)[4].frameNumber == 80)
        #expect(library.thumbs(interval).map(\.index) == Array(0..<(thumbs.count + 2)))
        // No selected thumb: nothing changes.
        let unchanged = library
        let noSelection = library.applyPlayerThumbAction(interval, .change, at: 5, selected: nil)
        let unknown = library.applyPlayerThumbAction(interval, .add(.after), at: 5, selected: UUID())
        #expect(noSelection == nil)
        #expect(unknown == nil)
        #expect(library == unchanged)
    }

    /// Save frame: the single-thumb scheme, named by the frame decoded.
    @Test func saveFrameNaming() {
        let settings = Settings()
        #expect(settings.singleThumbNameTemplate == "[MN].[ME]-frame[FN]")
        #expect(PrintOutput.baseName(
            template: settings.singleThumbNameTemplate, movieFileName: "clip.mkv", sheetName: "Shots",
            frameNumber: 1234, fps: 25) == "clip.mkv-frame001234")
        #expect(PrintOutput.baseName(
            template: "[MN]-[TC]", movieFileName: "clip.mkv", sheetName: "Shots", frameNumber: 26, fps: 25)
            == "clip-00_00_01_01")
    }
}

/// A virtual monotonic clock: sleeping moves it on; a source can move it
/// too, as decoding takes time.
private final class VirtualClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 100

    func now() -> Double { lock.withLock { time } }

    func advance(_ seconds: Double) { lock.withLock { time += seconds } }

    func sleep(until target: Double) async throws {
        try Task.checkCancellation()
        lock.withLock { time = max(time, target) }
    }
}

private func blankImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

@Suite struct PlaybackPacingTests {
    @Test func paceAnchorsOnTheFirstFrame() {
        var pacer = PlaybackPacer(fps: 25)
        let decisions = [
            pacer.decide(time: 4.0, now: 10),
            // Early frames wait until due: never ahead.
            pacer.decide(time: 4.04, now: 10.001),
            pacer.decide(time: 4.08, now: 10.05),
            // A little late (within a frame): shown now.
            pacer.decide(time: 4.12, now: 10.14),
            // More than a frame late, shown recently: dropped.
            pacer.decide(time: 4.16, now: 10.22),
            // Nothing shown for minimumRefresh: shown although late.
            pacer.decide(time: 4.20, now: 10.30),
        ]
        func at(_ decision: PlaybackPacer.Decision) -> Double? {
            if case .show(let time) = decision { return time }
            return nil
        }
        let expected: [Double?] = [10, 10.04, 10.08, 10.14, nil, 10.30]
        for (decision, time) in zip(decisions, expected) {
            switch (at(decision), time) {
            case (nil, nil): break
            case (let a?, let b?): #expect(abs(a - b) < 1e-9)
            default: Issue.record("got \(decision), expected \(String(describing: time))")
            }
        }
    }

    /// A source four frames ahead of the clock each time (no decode cost):
    /// every frame is shown exactly at its time, none dropped.
    @Test func framesAreShownAtTheirTimes() async throws {
        let clock = VirtualClock()
        let image = blankImage()
        var next = 0
        var shown: [(frame: Int, at: Double)] = []
        let stats = try await PlaybackLoop.run(fps: 25, clock: clock, next: {
            defer { next += 1 }
            return next < 25 ? PlaybackFrame(frameNumber: 10 + next, time: 0.4 + Double(next) / 25, image: image) : nil
        }) { frame in
            shown.append((frame.frameNumber, clock.now()))
        }
        #expect(stats.shown == 25)
        #expect(stats.dropped == 0)
        #expect(shown.map(\.frame) == Array(10..<35))
        for (k, entry) in shown.enumerated() {
            #expect(abs(entry.at - (100 + Double(k) / 25)) < 1e-9)
        }
    }

    /// A decode slower than real time (60 ms a frame at 25 fps): late
    /// frames are dropped, frames stay in order, none is shown before it is
    /// due, and a frame is still shown at least every `minimumRefresh`.
    @Test func slowDecodeDropsButNeverRunsAhead() async throws {
        let clock = VirtualClock()
        let image = blankImage()
        var next = 0
        var shown: [(frame: Int, at: Double)] = []
        let stats = try await PlaybackLoop.run(fps: 25, clock: clock, next: {
            guard next < 50 else { return nil }
            clock.advance(0.06)
            defer { next += 1 }
            return PlaybackFrame(frameNumber: next, time: Double(next) / 25, image: image)
        }) { frame in
            shown.append((frame.frameNumber, clock.now()))
        }
        #expect(stats.shown + stats.dropped == 50)
        #expect(stats.dropped > 0)
        #expect(shown.map(\.frame) == shown.map(\.frame).sorted())
        let anchor = try #require(shown.first)
        for entry in shown {
            #expect(entry.at >= anchor.at + Double(entry.frame - anchor.frame) / 25 - 1e-9)
        }
        for (a, b) in zip(shown, shown.dropFirst()) {
            #expect(b.at - a.at <= 0.1 + 0.06 + 1e-9)
        }
    }
}
