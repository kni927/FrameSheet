import Foundation
import Testing
@testable import FrameSheetCore

/// A library with one 1000-frame movie and its default interval sheet
/// (frames 0, 67, 133, …, 999).
private func fixture() -> (Library, SheetRef) {
    var library = Library()
    let file = MovieFile(
        url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
        width: 1920, height: 1080, size: 1, fourCC: "avc1")
    library.files.append(file)
    let sheet = library.addDefaultIntervalSheet(to: file.id)!
    library.currentFileId = file.id
    library.currentSheetId = sheet.id
    return (library, SheetRef(fileId: file.id, sheetId: sheet.id))
}

private extension Library {
    func frames(_ ref: SheetRef) -> [Int] { sheet(ref.sheetId, of: ref.fileId)!.thumbs.map(\.frameNumber) }
    func thumbs(_ ref: SheetRef) -> [Thumb] { sheet(ref.sheetId, of: ref.fileId)!.thumbs }
}

@Suite struct IntervalEditingTests {
    @Test func changeThumbClamps() {
        var (library, ref) = fixture()
        let id = library.thumbs(ref)[2].id
        library.changeThumb(ref, thumb: id, to: 150)
        #expect(library.frames(ref)[2] == 150)
        library.changeThumb(ref, thumb: id, to: 5000)
        #expect(library.frames(ref)[2] == 999)
    }

    @Test func insertMidwayToNeighbor() throws {
        var (library, ref) = fixture()
        let thumbs = library.thumbs(ref)
        // 67 → 133: after = 67 + round(66 / 2) = 100
        let inserted = library.insertThumb(ref, relativeTo: thumbs[1].id, .after)
        let after = try #require(inserted)
        #expect(library.frames(ref)[2] == 100)
        #expect(library.thumbs(ref)[2].id == after)
        // 0 → 67: before = 0 + round(67 / 2) = 34 (half rounds up)
        library.insertThumb(ref, relativeTo: thumbs[1].id, .before)
        #expect(library.frames(ref)[1] == 34)
        #expect(library.thumbs(ref).map(\.index) == Array(0..<18))
    }

    @Test func insertAtTheEndsUsesTheThumbItself() {
        var (library, ref) = fixture()
        let first = library.thumbs(ref)[0].id
        library.insertThumb(ref, relativeTo: first, .before)
        #expect(library.frames(ref)[0] == 0)
    }

    @Test func insertSkipsHiddenNeighbors() {
        var (library, ref) = fixture()
        let thumbs = library.thumbs(ref)
        library.setHidden(ref, thumbs: [thumbs[2].id], hidden: true)
        // visible right neighbor of 67 is now 200: 67 + round(133 / 2) = 134
        library.insertThumb(ref, relativeTo: thumbs[1].id, .after)
        #expect(library.frames(ref)[2] == 134)
    }

    @Test func hideToggleAndHideBeforeAfter() {
        var (library, ref) = fixture()
        let thumbs = library.thumbs(ref)
        library.toggleHidden(ref, thumb: thumbs[0].id)
        #expect(library.thumbs(ref)[0].hidden)
        library.toggleHidden(ref, thumb: thumbs[0].id)
        #expect(!library.thumbs(ref)[0].hidden)
        library.hideAll(ref, .before, of: thumbs[3].id)
        #expect(library.thumbs(ref).prefix(4).map(\.hidden) == [true, true, true, false])
        library.hideAll(ref, .after, of: thumbs[13].id)
        #expect(library.thumbs(ref).suffix(3).map(\.hidden) == [false, true, true])
        #expect(library.sheet(ref.sheetId, of: ref.fileId)!.visibleThumbs.count == 11)
    }

    @Test func reorder() {
        var (library, ref) = fixture()
        let ids = library.thumbs(ref).map(\.id)
        library.moveThumb(ref, thumb: ids[0], to: 3)
        #expect(library.thumbs(ref).map(\.id).prefix(3) == [ids[1], ids[2], ids[0]])
        library.moveThumb(ref, thumb: ids[15], to: 0)
        #expect(library.thumbs(ref).first?.id == ids[15])
        #expect(library.thumbs(ref).map(\.index) == Array(0..<16))
    }

    @Test func inAndOutRecaptureTheVisibleCount() {
        var (library, ref) = fixture()
        let thumbs = library.thumbs(ref)
        library.setHidden(ref, thumbs: [thumbs[15].id], hidden: true)  // 15 visible, highest 932
        library.setIn(ref, thumb: thumbs[3].id)  // frame 200
        #expect(library.frames(ref).count == 15)
        #expect(library.frames(ref).first == 200)
        #expect(library.frames(ref).last == 932)
        #expect(library.thumbs(ref).allSatisfy { !$0.hidden })
        let last = library.thumbs(ref)[14].id  // 932
        library.changeThumb(ref, thumb: last, to: 500)
        library.setOut(ref, thumb: last)
        #expect(library.frames(ref).first == 200)
        #expect(library.frames(ref).last == 500)
        #expect(library.frames(ref).count == 15)
    }

    @Test func inLimitedToRange() {
        var (library, ref) = fixture()
        let thumbs = library.thumbs(ref)
        library.changeThumb(ref, thumb: thumbs[15].id, to: 5)
        library.setIn(ref, thumb: thumbs[0].id)  // 0 … highest (932): 16 frames
        let narrow = library.thumbs(ref)
        library.changeThumb(ref, thumb: narrow[15].id, to: 5)
        library.changeThumb(ref, thumb: narrow[14].id, to: 4)
        for t in narrow.dropLast(2) { library.changeThumb(ref, thumb: t.id, to: 2) }
        library.setIn(ref, thumb: narrow[0].id)  // 2 … 5: only 4 frames fit
        #expect(library.frames(ref) == [2, 3, 4, 5])
    }

    @Test func columnsRowsAndOptimize() {
        var (library, ref) = fixture()
        library.setColumns(ref, 30)
        #expect(library.sheet(ref.sheetId, of: ref.fileId)!.columnCount == 20)
        library.applyThumbCount(ref, columns: 5, rows: 3)
        #expect(library.frames(ref).count == 15)
        #expect(library.frames(ref).first == 0)
        #expect(library.frames(ref).last == 999)
        #expect(library.sheet(ref.sheetId, of: ref.fileId)!.columnCount == 5)
        library.optimizeGrid(ref)
        #expect(library.sheet(ref.sheetId, of: ref.fileId)!.columnCount == 4)  // ceil(√15)
        #expect(GridLayout.optimizedColumns(thumbCount: 16) == 4)
        #expect(GridLayout.optimizedColumns(thumbCount: 17) == 5)
        #expect(GridLayout.optimizedColumns(thumbCount: 0) == 1)
        // Rows slider: columns follow from rows.
        #expect(GridLayout.columns(rows: 3, thumbCount: 15) == 5)
        #expect(GridLayout.columns(rows: 4, thumbCount: 15) == 4)
        #expect(GridLayout.columns(rows: 20, thumbCount: 15) == 1)
        #expect(GridLayout.columns(rows: 1, thumbCount: 50) == 20)
        #expect(GridLayout.columns(rows: 0, thumbCount: 0) == 1)
    }

    @Test func addIntervalSheetPreset() {
        var (library, ref) = fixture()
        let sheet = library.addIntervalSheet(to: ref.fileId, columns: 3, rows: 3)!
        #expect(sheet.name == "Sheet-2")
        #expect(sheet.columnCount == 3)
        #expect(sheet.thumbs.count == 9)
        #expect(sheet.thumbs.first?.frameNumber == 0)
        #expect(sheet.thumbs.last?.frameNumber == 999)
    }

    @Test func expandMakesAChildSequence() throws {
        var (library, ref) = fixture()
        let thumb = library.thumbs(ref)[1]  // 67, between 0 and 133
        let expanded = library.expand(ref, thumb: thumb.id)
        let child = try #require(expanded)
        let sheet = try #require(library.sheet(child.sheetId, of: child.fileId))
        // scene of thumb 1: starts after scene 0 (0…33), ends at 67 + 33
        #expect(sheet.name == "Sequence 34 - 100")
        #expect(sheet.parentSheetId == ref.sheetId)
        #expect(sheet.thumbs.count == 16)
        #expect(sheet.thumbs.first?.frameNumber == 34)
        #expect(sheet.thumbs.last?.frameNumber == 100)
        #expect(sheet.columnCount == 4)
        // Expanding again returns the same child.
        #expect(library.expand(ref, thumb: thumb.id) == child)
        #expect(library.sheets[ref.fileId]?.count == 2)
    }

    @Test func intervalScenes() {
        let (library, ref) = fixture()
        let scenes = SceneList.intervalScenes(of: library.sheet(ref.sheetId, of: ref.fileId)!)
        #expect(scenes.count == 16)
        #expect(scenes[0].start == 0)
        #expect(scenes[0].length == 34)
        #expect(scenes[1].start == 34)
        #expect(scenes.last!.start + scenes.last!.length == 999)
        for (a, b) in zip(scenes, scenes.dropFirst()) { #expect(a.start + a.length == b.start) }
    }

    @Test func duplicateRenameDelete() throws {
        var (library, ref) = fixture()
        let duplicated = library.duplicateSheet(ref)
        let copy = try #require(duplicated)
        let copied = try #require(library.sheet(copy.sheetId, of: copy.fileId))
        #expect(copied.name == "Sheet-2")
        #expect(copied.thumbs.map(\.frameNumber) == library.frames(ref))
        #expect(Set(copied.thumbs.map(\.id)).isDisjoint(with: library.thumbs(ref).map(\.id)))
        library.renameSheet(copy, to: "  Opening  ")
        #expect(library.sheet(copy.sheetId, of: copy.fileId)?.name == "Opening")
        library.renameSheet(copy, to: "   ")
        #expect(library.sheet(copy.sheetId, of: copy.fileId)?.name == "Opening")
        library.deleteSheet(ref)
        #expect(library.sheets[ref.fileId]?.map(\.id) == [copy.sheetId])
        #expect(library.currentSheetId == copy.sheetId)
    }

    @Test func removeFileAndRelink() {
        var (library, ref) = fixture()
        library.relink(ref.fileId, to: URL(fileURLWithPath: "/new/b.mov"), bookmark: nil)
        #expect(library.file(ref.fileId)?.name == "b.mov")
        #expect(library.file(ref.fileId)?.folder == "/new")
        library.removeFile(ref.fileId)
        #expect(library.files.isEmpty)
        #expect(library.sheets.isEmpty)
        #expect(library.currentFileId == nil)
        #expect(library.currentSheetId == nil)
    }
}

@Suite struct ScrubTests {
    /// Thumb 500 between 400 and 600; live frame from x 100 to 300 in a
    /// 410-wide overlay.
    private func mapping(thumb: Int = 500, left: Int = 400, right: Int = 600) -> ScrubMapping {
        ScrubMapping(
            thumbFrame: thumb, leftFrame: left, rightFrame: right, frameCount: 1000, liveMinX: 100,
            liveMaxX: 300, containerWidth: 410)
    }

    @Test func betweenNeighbors() {
        let m = mapping()
        #expect(m.frame(atX: 100, modifiers: []) == 400)
        #expect(m.frame(atX: 200, modifiers: []) == 500)
        #expect(m.frame(atX: 300, modifiers: []) == 600)
        #expect(m.frame(atX: 50, modifiers: []) == 400)  // holds left of the live frame
        #expect(m.frame(atX: 350, modifiers: []) == 600)
    }

    @Test func shiftAndOption() {
        let m = mapping()
        #expect(m.frame(atX: 200, modifiers: .shift) == 450)  // 400 → 500
        #expect(m.frame(atX: 300, modifiers: .shift) == 500)
        #expect(m.frame(atX: 200, modifiers: .option) == 550)  // 500 → 600
        #expect(m.frame(atX: 100, modifiers: .option) == 500)
        #expect(ScrubAction(.shift) == .addBefore)
        #expect(ScrubAction(.option) == .addAfter)
        #expect(ScrubAction([]) == .change)
        #expect(ScrubAction([]).label == "CHANGE TO")
    }

    @Test func controlExtendsToTheMovie() {
        let m = mapping()
        #expect(m.frame(atX: 10, modifiers: .control) == 0)
        #expect(m.frame(atX: 55, modifiers: .control) == 200)  // 10…100 → 0…400
        #expect(m.frame(atX: 400, modifiers: .control) == 999)
        #expect(m.frame(atX: 350, modifiers: .control) == 800)  // 300…400 → 600…999
    }

    @Test func firstAndLastThumbExtendWithoutControl() {
        let first = mapping(thumb: 0, left: 0, right: 67)
        #expect(first.frame(atX: 50, modifiers: []) == 0)
        let firstLater = mapping(thumb: 100, left: 100, right: 200)
        #expect(firstLater.frame(atX: 55, modifiers: []) == 50)
        let last = mapping(thumb: 900, left: 800, right: 900)
        #expect(last.frame(atX: 400, modifiers: []) == 999)
    }

    /// Pressed on a handle away from the thumb's position on the live frame,
    /// the scrub starts at the thumb's own frame (T04b): x 50 would be the
    /// left neighbor in the absolute map.
    @Test func pressStartsAtTheThumbsFrame() {
        var m = mapping()
        m.pressX = 50
        #expect(m.frame(atX: 50, modifiers: []) == 500)
        // Left: 100 points to the neighbor, but only 40 to the margin, so
        // the side is compressed to reach 400 at x 10.
        #expect(m.frame(atX: 30, modifiers: []) == 450)
        #expect(m.frame(atX: 10, modifiers: []) == 400)
        #expect(m.frame(atX: 0, modifiers: []) == 400)
        // Right: the absolute map's 100 points to the neighbor, then holds.
        #expect(m.frame(atX: 100, modifiers: []) == 550)
        #expect(m.frame(atX: 150, modifiers: []) == 600)
        #expect(m.frame(atX: 380, modifiers: []) == 600)
        // Shift and Option keep the thumb's frame at the press.
        #expect(m.frame(atX: 50, modifiers: .shift) == 500)
        #expect(m.frame(atX: 50, modifiers: .option) == 500)
        #expect(m.frame(atX: 250, modifiers: .option) == 600)  // 200 points to 600
        #expect(m.frame(atX: 10, modifiers: .shift) == 400)  // compressed 200 → 40
        #expect(m.frame(atX: 380, modifiers: .shift) == 500)
        // Control: on past the neighbor to the movie's ends.
        #expect(m.frame(atX: 200, modifiers: .control) == 800)  // 600 at 150, 999 at 250
        #expect(m.frame(atX: 250, modifiers: .control) == 999)
        #expect(m.frame(atX: 10, modifiers: .control) == 0)
        #expect(m.frame(atX: 50, modifiers: .control) == 500)
    }

    /// Pressed at the thumb's position on the live frame, the relative map
    /// is the absolute one.
    @Test func pressAtTheThumbsPositionMatchesTheAbsoluteMap() {
        let absolute = mapping()
        var relative = absolute
        relative.pressX = 200
        let all: [ScrubModifiers] = [[], .control]
        for modifiers in all {
            for x in stride(from: 0.0, through: 410, by: 5) {
                #expect(relative.frame(atX: x, modifiers: modifiers) == absolute.frame(atX: x, modifiers: modifiers),
                        "x \(x)")
            }
        }
        // First and last thumbs extend without Control.
        var first = mapping(thumb: 100, left: 100, right: 200)
        first.pressX = 300
        #expect(first.frame(atX: 300, modifiers: []) == 100)
        #expect(first.frame(atX: 10, modifiers: []) == 0)
        #expect(first.frame(atX: 400, modifiers: []) == 200)
        var last = mapping(thumb: 900, left: 800, right: 900)
        last.pressX = 20
        #expect(last.frame(atX: 20, modifiers: []) == 900)
        #expect(last.frame(atX: 10, modifiers: []) == 800)
        #expect(last.frame(atX: 400, modifiers: []) == 999)
    }

    @Test func applyScrub() {
        var (library, ref) = fixture()
        let thumb = library.thumbs(ref)[1].id
        library.applyScrub(ref, thumb: thumb, frame: 80, action: .change)
        #expect(library.frames(ref)[1] == 80)
        let before = library.applyScrub(ref, thumb: thumb, frame: 50, action: .addBefore)
        #expect(library.frames(ref)[1] == 50)
        #expect(library.thumbs(ref)[1].id == before)
        library.applyScrub(ref, thumb: thumb, frame: 90, action: .addAfter)
        #expect(library.frames(ref)[3] == 90)
        #expect(library.frames(ref).count == 18)
    }
}

@Suite struct UndoTests {
    @Test func undoRedoAcrossOperations() {
        let (start, ref) = fixture()
        var doc = EditableLibrary(start)
        let thumbs = start.sheet(ref.sheetId, of: ref.fileId)!.thumbs
        doc.edit { $0.changeThumb(ref, thumb: thumbs[1].id, to: 80) }
        doc.edit { $0.insertThumb(ref, relativeTo: thumbs[1].id, .after) }
        doc.edit { $0.toggleHidden(ref, thumb: thumbs[0].id) }
        doc.edit { $0.moveThumb(ref, thumb: thumbs[5].id, to: 0) }
        let expanded = doc.edit { $0.expand(ref, thumb: thumbs[3].id) }
        doc.edit { $0.setColumns(ref, 6) }
        let end = doc.library
        #expect(doc.history.undoStack.count == 6)

        while doc.undo() {}
        #expect(doc.library == start)
        #expect(!doc.history.canUndo)
        while doc.redo() {}
        #expect(doc.library == end)
        #expect(expanded.flatMap { doc.library.sheet($0.sheetId, of: $0.fileId) } != nil)
    }

    @Test func noStepForNoChangeAndRedoClearedByEdit() {
        let (start, ref) = fixture()
        var doc = EditableLibrary(start)
        doc.edit { $0.changeThumb(ref, thumb: UUID(), to: 5) }  // no such thumb
        #expect(!doc.history.canUndo)
        let thumb = start.sheet(ref.sheetId, of: ref.fileId)!.thumbs[2].id
        doc.edit { $0.changeThumb(ref, thumb: thumb, to: 5) }
        doc.undo()
        #expect(doc.history.canRedo)
        doc.edit { $0.changeThumb(ref, thumb: thumb, to: 6) }
        #expect(!doc.history.canRedo)
    }

    @Test func fiftyStepsAndSettingsKept() {
        let (start, ref) = fixture()
        var doc = EditableLibrary(start)
        let thumb = start.sheet(ref.sheetId, of: ref.fileId)!.thumbs[2].id
        for frame in 200..<260 { doc.edit { $0.changeThumb(ref, thumb: thumb, to: frame) } }
        #expect(doc.history.undoStack.count == EditHistory.limit)
        doc.update { $0.settings.marginHorizontal = 12 }
        var undone = 0
        while doc.undo() { undone += 1 }
        #expect(undone == 50)
        #expect(doc.library.sheet(ref.sheetId, of: ref.fileId)!.thumbs[2].frameNumber == 209)
        #expect(doc.library.settings.marginHorizontal == 12)
    }
}

@Suite struct TextTests {
    @Test func statsAndFrameInfo() {
        #expect(GridLayout.statsLine(columns: 4, thumbCount: 16) == "4 Columns × 4 Rows = 16")
        #expect(GridLayout.statsLine(columns: 5, thumbCount: 16) == "5 Columns × 4 Rows = 16")
        #expect(GridLayout.rows(columns: 4, thumbCount: 19) == 5)
        #expect(GridLayout.rows(columns: 4, thumbCount: 0) == 0)
        #expect(GridLayout.rows(columns: 0, thumbCount: 3) == 3)
        #expect(FrameInfoText.text(.frames, frame: 42, fps: 25) == "0042")
        #expect(FrameInfoText.text(.frames, frame: 123_456, fps: 25) == "123456")
        #expect(FrameInfoText.text(.timecode, frame: 25 * 61 + 3, fps: 25) == "00:01:01:03")
        #expect(FrameInfoText.text(.hidden, frame: 1, fps: 25) == nil)
        #expect(FrameInfoText.text(.timecode, frame: 25 * 61 + 3, fps: 25, timecodeFormat: .minutesSeconds) == "01:01")
        #expect(FrameInfoText.text(.frames, frame: 42, fps: 25, timecodeFormat: .minutesSeconds) == "0042")
        #expect(FrameInfoText.next(after: .hidden) == .frames)
        #expect(abs(FrameInfoText.fontSize(size: 10, thumbHeight: 200) - 15) < 1e-9)
    }

    @Test func zoomSteps() {
        #expect(GridLayout.zoom(from: 1, in: true) == 2)
        #expect(GridLayout.zoom(from: 1, in: false) == 0.75)
        #expect(GridLayout.zoom(from: 8, in: true) == 8)
        #expect(GridLayout.zoom(from: 0.25, in: false) == 0.25)
    }
}
