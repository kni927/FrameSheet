import Foundation

// Interval sheet operations (§5, §7). Behaviour follows MoviePrint v0.2.23
// (MIT, docs/licenses/MoviePrint-LICENSE): `onAddThumbClick`,
// `onExpandClick` and `onAddIntervalSheetClick` (app/containers/App.js),
// `onInPointClick`/`onOutPointClick` (app/containers/VisibleThumbGrid.js),
// `onHideBefore`/`onHideAfter` (app/components/ThumbGrid.js) and
// `createSceneArray` (app/utils/utils.js).

public enum InsertPosition: Sendable {
    case before, after
}

/// A location of a sheet in the library.
public struct SheetRef: Hashable, Sendable {
    public var fileId: UUID
    public var sheetId: UUID

    public init(fileId: UUID, sheetId: UUID) {
        self.fileId = fileId
        self.sheetId = sheetId
    }
}

extension Library {
    // MARK: - Lookup

    func sheetIndex(_ ref: SheetRef) -> Int? {
        sheets[ref.fileId]?.firstIndex { $0.id == ref.sheetId }
    }

    /// Mutates one sheet in place; returns nil when it does not exist.
    @discardableResult
    mutating func withSheet<T>(_ ref: SheetRef, _ change: (inout Sheet, MovieFile) -> T) -> T? {
        guard let file = file(ref.fileId), let i = sheetIndex(ref) else { return nil }
        return change(&sheets[ref.fileId]![i], file)
    }

    // MARK: - Thumbs

    /// Sets the frame of one thumb.
    public mutating func changeThumb(_ ref: SheetRef, thumb: UUID, to frame: Int) {
        withSheet(ref) { sheet, file in
            guard let t = sheet.thumbs.firstIndex(where: { $0.id == thumb }) else { return }
            sheet.thumbs[t].frameNumber = file.clampFrame(frame)
        }
    }

    /// Inserts a thumb before or after another one. Without a frame, takes
    /// the frame midway to the visible neighbour on that side. Returns the new
    /// thumb's id.
    @discardableResult
    public mutating func insertThumb(
        _ ref: SheetRef, relativeTo thumb: UUID, _ position: InsertPosition, frame: Int? = nil
    ) -> UUID? {
        withSheet(ref) { sheet, file -> UUID? in
            guard let index = sheet.thumbs.firstIndex(where: { $0.id == thumb }) else { return nil }
            let existing = sheet.thumbs[index].frameNumber
            let newFrame: Int
            if let frame {
                newFrame = frame
            } else {
                let (left, right) = sheet.visibleNeighbours(of: thumb)
                switch position {
                case .after:
                    newFrame = existing + Int(IntervalFrames.jsRound(Double(right - existing) / 2))
                case .before:
                    newFrame = left + Int(IntervalFrames.jsRound(Double(existing - left) / 2))
                }
            }
            let new = Thumb(frameNumber: file.clampFrame(newFrame), index: 0)
            sheet.thumbs.insert(new, at: position == .after ? index + 1 : index)
            sheet.reindex()
            return new.id
        } ?? nil
    }

    public mutating func setHidden(_ ref: SheetRef, thumbs ids: Set<UUID>, hidden: Bool) {
        withSheet(ref) { sheet, _ in
            for i in sheet.thumbs.indices where ids.contains(sheet.thumbs[i].id) {
                sheet.thumbs[i].hidden = hidden
            }
        }
    }

    public mutating func toggleHidden(_ ref: SheetRef, thumb: UUID) {
        withSheet(ref) { sheet, _ in
            guard let t = sheet.thumbs.firstIndex(where: { $0.id == thumb }) else { return }
            sheet.thumbs[t].hidden.toggle()
        }
    }

    /// Hides the visible thumbs before (or after) a thumb (IN/OUT with
    /// Option, and on non-interval sheets).
    public mutating func hideAll(_ ref: SheetRef, _ position: InsertPosition, of thumb: UUID) {
        guard let sheet = self.sheet(ref.sheetId, of: ref.fileId) else { return }
        let visible = sheet.visibleThumbs
        guard let i = visible.firstIndex(where: { $0.id == thumb }) else { return }
        let ids = position == .before ? visible[..<i].map(\.id) : visible[(i + 1)...].map(\.id)
        setHidden(ref, thumbs: Set(ids), hidden: true)
    }

    /// Moves a thumb to `destination`, an index in the full thumb list
    /// counted before the move (as `Array.move(fromOffsets:toOffset:)`).
    public mutating func moveThumb(_ ref: SheetRef, thumb: UUID, to destination: Int) {
        withSheet(ref) { sheet, _ in
            guard let from = sheet.thumbs.firstIndex(where: { $0.id == thumb }) else { return }
            let target = min(max(0, destination), sheet.thumbs.count)
            let moved = sheet.thumbs.remove(at: from)
            sheet.thumbs.insert(moved, at: target > from ? target - 1 : target)
            sheet.reindex()
        }
    }

    // MARK: - IN / OUT

    /// IN on an interval sheet: the same number of thumbs as are visible,
    /// recaptured between this thumb's frame and the highest visible frame.
    public mutating func setIn(_ ref: SheetRef, thumb: UUID) {
        guard let sheet = self.sheet(ref.sheetId, of: ref.fileId),
              let frame = sheet.thumbs.first(where: { $0.id == thumb })?.frameNumber,
              let highest = sheet.visibleThumbs.map(\.frameNumber).max()
        else { return }
        recapture(ref, count: sheet.visibleThumbs.count, start: frame, stop: highest, limitToRange: true)
    }

    /// OUT: as IN, between the lowest visible frame and this thumb's frame.
    public mutating func setOut(_ ref: SheetRef, thumb: UUID) {
        guard let sheet = self.sheet(ref.sheetId, of: ref.fileId),
              let frame = sheet.thumbs.first(where: { $0.id == thumb })?.frameNumber,
              let lowest = sheet.visibleThumbs.map(\.frameNumber).min()
        else { return }
        recapture(ref, count: sheet.visibleThumbs.count, start: lowest, stop: frame, limitToRange: true)
    }

    /// Replaces the sheet's thumbs with `count` frames between start and stop
    /// (MoviePrint `addIntervalSheet` on an existing sheet).
    public mutating func recapture(_ ref: SheetRef, count: Int, start: Int, stop: Int, limitToRange: Bool) {
        withSheet(ref) { sheet, file in
            sheet.thumbs = IntervalFrames.frameNumbers(
                amount: count, start: start, stop: stop, maxValue: file.frameCount,
                limitToMaxValue: limitToRange
            ).enumerated().map { Thumb(frameNumber: $1, index: $0) }
        }
    }

    // MARK: - Grid

    public mutating func setColumns(_ ref: SheetRef, _ columns: Int) {
        withSheet(ref) { sheet, _ in sheet.columnCount = min(max(1, columns), 20) }
    }

    /// Change thumb count → Apply: columns × rows thumbs between the lowest
    /// and highest visible frames.
    public mutating func applyThumbCount(_ ref: SheetRef, columns: Int, rows: Int) {
        guard let sheet = self.sheet(ref.sheetId, of: ref.fileId) else { return }
        let frames = sheet.visibleThumbs.map(\.frameNumber)
        let file = self.file(ref.fileId)
        let start = frames.min() ?? file?.inFrame ?? 0
        let stop = frames.max() ?? file?.outFrame ?? 0
        let c = min(max(1, columns), 20)
        let r = min(max(1, rows), 20)
        setColumns(ref, c)
        recapture(ref, count: c * r, start: start, stop: stop, limitToRange: false)
    }

    /// Optimise grid layout: columns = ceil(√n) of the visible thumbs.
    public mutating func optimiseGrid(_ ref: SheetRef) {
        withSheet(ref) { sheet, _ in
            sheet.columnCount = GridLayout.optimisedColumns(thumbCount: sheet.visibleThumbs.count)
        }
    }

    // MARK: - Sheets

    /// Adds an interval sheet of columns × rows thumbs between the movie's
    /// IN and OUT (toolbar presets 2×2 … 6×6).
    @discardableResult
    public mutating func addIntervalSheet(to fileId: UUID, columns: Int, rows: Int) -> Sheet? {
        guard let file = file(fileId) else { return nil }
        let frames = IntervalFrames.frameNumbers(
            amount: columns * rows, start: file.inFrame, stop: file.outFrame, maxValue: file.frameCount)
        let thumbs = frames.enumerated().map { Thumb(frameNumber: $1, index: $0) }
        guard let added = addSheet(to: fileId, type: .interval, thumbs: thumbs) else { return nil }
        setColumns(SheetRef(fileId: fileId, sheetId: added.id), columns)
        return sheet(added.id, of: fileId)
    }

    /// Expand: a child interval sheet of 16 thumbs inside the thumb's scene,
    /// named "Sequence a - b". The child's id is the thumb's id, so expanding
    /// the same thumb again returns the existing child.
    @discardableResult
    public mutating func expand(_ ref: SheetRef, thumb: UUID) -> SheetRef? {
        guard let file = file(ref.fileId), let parent = sheet(ref.sheetId, of: ref.fileId) else { return nil }
        let child = SheetRef(fileId: ref.fileId, sheetId: thumb)
        if sheet(thumb, of: ref.fileId) != nil { return child }
        guard let scene = SceneList.intervalScenes(of: parent).first(where: { $0.id == thumb }) else { return nil }
        let start = scene.start
        let end = scene.start + scene.length - 1
        let frames = IntervalFrames.frameNumbers(
            amount: Defaults.thumbCount, start: start, stop: end, maxValue: file.frameCount,
            limitToMaxValue: true)
        let new = Sheet(
            id: thumb, name: "Sequence \(start) - \(end)", type: .interval,
            columnCount: GridLayout.optimisedColumns(thumbCount: frames.count), parentSheetId: ref.sheetId,
            thumbs: frames.enumerated().map { Thumb(frameNumber: $1, index: $0) })
        sheets[ref.fileId, default: []].append(new)
        if let i = files.firstIndex(where: { $0.id == ref.fileId }) { files[i].sheetCounter += 1 }
        return child
    }

    /// A copy with new ids and the next `Sheet-N` name, placed after
    /// the original.
    @discardableResult
    public mutating func duplicateSheet(_ ref: SheetRef) -> SheetRef? {
        guard let i = sheetIndex(ref), let f = files.firstIndex(where: { $0.id == ref.fileId }) else { return nil }
        var copy = sheets[ref.fileId]![i]
        copy.id = UUID()
        copy.name = SheetNaming.newSheetName(sheetCount: files[f].sheetCounter)
        files[f].sheetCounter += 1
        copy.thumbs = copy.thumbs.map { Thumb(frameNumber: $0.frameNumber, index: $0.index, hidden: $0.hidden, faces: $0.faces) }
        copy.scenes = []
        sheets[ref.fileId]!.insert(copy, at: i + 1)
        return SheetRef(fileId: ref.fileId, sheetId: copy.id)
    }

    public mutating func renameSheet(_ ref: SheetRef, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withSheet(ref) { sheet, _ in sheet.name = trimmed }
    }

    /// Deletes a sheet; if it was current, selects the next one of the file.
    public mutating func deleteSheet(_ ref: SheetRef) {
        guard let i = sheetIndex(ref) else { return }
        sheets[ref.fileId]!.remove(at: i)
        if currentSheetId == ref.sheetId {
            let rest = sheets[ref.fileId] ?? []
            currentSheetId = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        }
    }

    /// Removes a movie and its sheets from the list.
    public mutating func removeFile(_ fileId: UUID) {
        guard let i = files.firstIndex(where: { $0.id == fileId }) else { return }
        files.remove(at: i)
        sheets[fileId] = nil
        if currentFileId == fileId {
            currentFileId = files.isEmpty ? nil : files[min(i, files.count - 1)].id
            currentSheetId = currentFileId.flatMap { sheets[$0]?.first?.id }
        }
    }

    /// Locate: points a missing movie at another file.
    public mutating func relink(_ fileId: UUID, to url: URL, bookmark: Data?) {
        guard let i = files.firstIndex(where: { $0.id == fileId }) else { return }
        files[i].url = url
        files[i].bookmark = bookmark
        files[i].name = url.lastPathComponent
        files[i].folder = url.deletingLastPathComponent().path
    }
}

extension Sheet {
    mutating func reindex() {
        for i in thumbs.indices { thumbs[i].index = i }
    }

    /// Frames of the visible neighbours of a thumb; a thumb at either end is
    /// its own neighbour on that side (MoviePrint's first/last-thumb rule).
    public func visibleNeighbours(of thumb: UUID) -> (left: Int, right: Int) {
        let visible = visibleThumbs
        guard let i = visible.firstIndex(where: { $0.id == thumb }) else {
            let own = thumbs.first { $0.id == thumb }?.frameNumber ?? 0
            return (own, own)
        }
        return (visible[max(0, i - 1)].frameNumber, visible[min(visible.count - 1, i + 1)].frameNumber)
    }
}

extension MovieFile {
    func clampFrame(_ frame: Int) -> Int { min(max(0, frame), max(0, frameCount - 1)) }
}

public enum SceneList {
    /// Artificial scenes of an interval sheet, split at the midpoints between
    /// visible thumbs sorted by frame; each scene's id is its thumb's id
    /// (MoviePrint `createSceneArray`).
    public static func intervalScenes(of sheet: Sheet) -> [Scene] {
        let visible = sheet.visibleThumbs.sorted { $0.frameNumber < $1.frameNumber }
        guard let first = visible.first else { return [] }
        guard visible.count > 1 else {
            return [Scene(id: first.id, start: first.frameNumber, length: 1, colorRGB: [128, 128, 128])]
        }
        var scenes: [Scene] = []
        var start = first.frameNumber
        var length = (visible[1].frameNumber - first.frameNumber) / 2 + 1
        for (index, thumb) in visible.enumerated() {
            if index != 0 {
                start += length
                if index < visible.count - 1 {
                    let next = visible[index + 1]
                    length = (next.frameNumber - thumb.frameNumber) / 2 + thumb.frameNumber - start + 1
                } else {
                    length = thumb.frameNumber - start
                }
            }
            scenes.append(Scene(id: thumb.id, start: start, length: max(1, length), colorRGB: [128, 128, 128]))
        }
        return scenes
    }
}
