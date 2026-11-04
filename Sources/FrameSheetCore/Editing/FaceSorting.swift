import Foundation

// Faces sheets, sort and filter (§4, §5, §10). Ported from MoviePrint
// v0.2.23 (MIT, docs/licenses/MoviePrint-LICENSE): `sortArray`,
// `filterArray` and `sortThumbsArray` (app/utils/utilsSortAndFilter.js),
// `onSortSheet`, `onFilterSheet` and `onAddFaceSheetClick`
// (app/containers/App.js), and the filter defaults of `FloatingMenu`
// (app/components/FloatingMenu.js) with `FILTER_METHOD_FACECOUNT` and
// `FILTER_METHOD_FACESIZE` (app/utils/constants.js).

/// The toolbar's Sort menu.
public enum ThumbSort: String, Codable, CaseIterable, Sendable {
    case reverse, frameNumber, faceCount, faceSize, faceConfidence

    public var label: String {
        switch self {
        case .reverse: "Reverse"
        case .frameNumber: "Frame number"
        case .faceCount: "Face count"
        case .faceSize: "Face size"
        case .faceConfidence: "Confidence"
        }
    }

    /// Needs face data: faces sheets only (MoviePrint disables these
    /// otherwise).
    public var needsFaces: Bool {
        switch self {
        case .reverse, .frameNumber: false
        case .faceCount, .faceSize, .faceConfidence: true
        }
    }
}

/// One range filter of a faces sheet.
public struct FaceRangeFilter: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var lower: Double
    public var upper: Double

    public init(enabled: Bool, lower: Double, upper: Double) {
        self.enabled = enabled
        self.lower = lower
        self.upper = upper
    }
}

/// A faces sheet's filter (MoviePrint `currentSheetFilter`, face count and
/// size only): a face passes when every enabled range holds it. A slider
/// at its maximum also lets larger values pass.
public struct FaceFilter: Codable, Sendable, Equatable {
    /// Faces in the frame, slider 1–10 (default 1–3).
    public var faceCount = FaceRangeFilter(enabled: false, lower: 1, upper: 3)
    /// Face height in % of the frame height, slider from the size
    /// threshold to 100 (default 50–100).
    public var size = FaceRangeFilter(enabled: false, lower: 50, upper: 100)

    public static let faceCountRange = 1.0...10.0
    public static let sizeMaximum = 100.0
    /// `MAXMAX`: the upper bound used when a slider is at its maximum.
    static let faceCountBeyondMaximum = 100.0
    static let sizeBeyondMaximum = 1000.0

    public init() {}

    public var isActive: Bool { faceCount.enabled || size.enabled }

    /// Whether a face of a frame with `faceCount` faces passes.
    public func passes(_ face: Face, faceCount count: Int) -> Bool {
        if faceCount.enabled {
            let upper = faceCount.upper >= Self.faceCountRange.upperBound ? Self.faceCountBeyondMaximum : faceCount.upper
            guard faceCount.lower <= Double(count), Double(count) <= upper else { return false }
        }
        if size.enabled {
            let upper = size.upper >= Self.sizeMaximum ? Self.sizeBeyondMaximum : size.upper
            guard size.lower <= face.size, face.size <= upper else { return false }
        }
        return true
    }

    /// The faces of a thumb that pass (all of them when no range is on).
    public func passing(_ faces: [Face]) -> [Face] {
        guard isActive else { return faces }
        return faces.filter { passes($0, faceCount: faces.count) }
    }
}

extension Sheet {
    /// The faces of a thumb the sheet shows: those passing its filter.
    public func shownFaces(of thumb: Thumb) -> [Face] {
        (faceFilter ?? FaceFilter()).passing(thumb.faces)
    }

    /// MoviePrint `sortArray`: the ids of `thumbs` in sorted order. Face
    /// sorts leave out thumbs without faces (or without faces passing the
    /// filter) and order by the frame's face count, or by its largest or
    /// most confident passing face, largest first; frame number sorts
    /// ascending. Ties keep the frame order.
    static func sortOrder(_ thumbs: [Thumb], by sort: ThumbSort, filter: FaceFilter) -> [UUID] {
        func key(_ thumb: Thumb) -> Double? {
            let faces = filter.passing(thumb.faces)
            guard !faces.isEmpty else { return nil }
            switch sort {
            case .faceCount: return Double(thumb.faces.count)
            case .faceSize: return faces.map(\.size).max()
            case .faceConfidence: return faces.map(\.confidence).max()
            case .reverse, .frameNumber: return 0
            }
        }
        if sort == .frameNumber || sort == .reverse {
            return thumbs.sorted { $0.frameNumber < $1.frameNumber }.map(\.id)
        }
        return thumbs.compactMap { thumb in key(thumb).map { (thumb, $0) } }
            .sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.frameNumber < b.0.frameNumber }
            .map(\.0.id)
    }
}

extension Library {
    /// Sort (toolbar; one undo step), MoviePrint `onSortSheet`. Reverse
    /// turns the whole thumb order around. The other sorts order the
    /// visible thumbs (all of them with `includeHidden`, Show hidden
    /// thumbs) and show exactly those that the sort keeps; the rest are
    /// hidden and go to the end (MoviePrint puts them first), and the grid
    /// is optimized for the shown count. Face sorts need a faces sheet;
    /// shot sheets are not sorted (§4).
    public mutating func sortThumbs(_ ref: SheetRef, by sort: ThumbSort, includeHidden: Bool) {
        withSheet(ref) { sheet, _ in
            guard sheet.type != .shot, !sort.needsFaces || sheet.type == .faces else { return }
            if sheet.type == .faces {
                let last = sheet.faceSort ?? FaceSheetSort(sort: .faceSize)
                sheet.faceSort = sort == .reverse
                    ? FaceSheetSort(sort: last.sort, reversed: !last.reversed) : FaceSheetSort(sort: sort)
            }
            if sort == .reverse {
                sheet.thumbs.reverse()
                sheet.reindex()
                return
            }
            let base = includeHidden ? sheet.thumbs : sheet.visibleThumbs
            let order = Sheet.sortOrder(base, by: sort, filter: sheet.faceFilter ?? FaceFilter())
            let byId = Dictionary(sheet.thumbs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let kept = Set(order)
            var sorted = order.compactMap { id -> Thumb? in
                var thumb = byId[id]
                thumb?.hidden = false
                return thumb
            }
            sorted += sheet.thumbs.filter { !kept.contains($0.id) }.map { thumb in
                var thumb = thumb
                thumb.hidden = true
                return thumb
            }
            sheet.thumbs = sorted
            sheet.reindex()
            sheet.columnCount = GridLayout.optimizedColumns(thumbCount: order.count)
        }
    }

    /// Filter (toolbar; one undo step), MoviePrint `onFilterSheet` and
    /// `filterArray`: stores the filter and hides the thumbs none of whose
    /// faces pass; with no range on, shows all thumbs. Thumbs keep their
    /// order (MoviePrint also put them back in frame order). The grid is
    /// optimized for the shown count. Faces sheets only.
    public mutating func setFaceFilter(_ ref: SheetRef, _ filter: FaceFilter) {
        withSheet(ref) { sheet, _ in
            guard sheet.type == .faces else { return }
            sheet.faceFilter = filter
            for i in sheet.thumbs.indices {
                sheet.thumbs[i].hidden = filter.isActive && filter.passing(sheet.thumbs[i].faces).isEmpty
            }
            sheet.columnCount = GridLayout.optimizedColumns(thumbCount: sheet.visibleThumbs.count)
        }
    }

    /// Add faces sheet (§5): the scanned frames of `frames` that contain
    /// faces, with their faces, sorted by face size and in an optimized
    /// grid, in grid view, with the scan's `source` stored for Apply. Nil
    /// when no frame has a face (MoviePrint made an empty sheet).
    @discardableResult
    public mutating func addFacesSheet(
        to fileId: UUID, frames: [Int], faces: FaceData, source: FaceSheetSource? = nil
    ) -> Sheet? {
        let thumbs = Self.facesThumbs(frames: frames, faces: faces)
        guard !thumbs.isEmpty, let sheet = addSheet(to: fileId, type: .faces, view: .grid, thumbs: thumbs) else {
            return nil
        }
        let ref = SheetRef(fileId: fileId, sheetId: sheet.id)
        withSheet(ref) { sheet, _ in sheet.faceSource = source }
        sortThumbs(ref, by: .faceSize, includeHidden: false)
        return self.sheet(sheet.id, of: fileId)
    }
}
