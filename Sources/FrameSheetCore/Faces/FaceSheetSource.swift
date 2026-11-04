import Foundation

// Apply (Settings, Face detection): a faces sheet rescanned with other
// thresholds over the frames it was made from, its thumbs replaced in place.
// The sheet stores its scan scope and frames (`FaceSheetSource`) and its
// last sort (`FaceSheetSort`); both decode tolerantly, so a malformed or
// unknown value falls back instead of failing the library.

/// The frames a faces sheet was scanned from and the thresholds its faces
/// were found with. Sampled scopes store the lowest and highest thumb frame
/// they spread over (the scope's frames follow from those alone), the
/// "these thumbs" scope its frames.
public struct FaceSheetSource: Sendable, Equatable {
    public var scope: FaceScanScope
    public var lowFrame: Int
    public var highFrame: Int
    /// The `thumbs` scope's frames, sorted and unique; nil otherwise.
    public var thumbFrames: [Int]?
    /// Nil when not known (sheets made before Apply).
    public var thresholds: FaceThresholds?
    /// The movie's transform when the faces were found (§3); nil on sheets
    /// made before transforms existed, which had none.
    public var transform: MovieTransform?

    /// The source of a scan of `scope` over `thumbFrames` (the shown thumbs
    /// of the sheet Add faces sheet was used on).
    public init(scope: FaceScanScope, thumbFrames: [Int], frameCount: Int, thresholds: FaceThresholds?) {
        let frames = Array(Set(thumbFrames.filter { $0 >= 0 && $0 < max(1, frameCount) })).sorted()
        self.scope = scope
        lowFrame = frames.first ?? 0
        highFrame = frames.last ?? 0
        self.thumbFrames = scope == .thumbs ? frames : nil
        self.thresholds = thresholds
    }

    /// The frames the scan analyzed (`FaceScanScope.frames`).
    public func frames(frameCount: Int) -> [Int] {
        scope.frames(thumbFrames: thumbFrames ?? [lowFrame, highFrame], frameCount: frameCount)
    }

    /// The same frames with other thresholds.
    public func with(_ thresholds: FaceThresholds) -> FaceSheetSource {
        var source = self
        source.thresholds = thresholds
        return source
    }
}

extension FaceSheetSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case scope, lowFrame, highFrame, thumbFrames, thresholds, transform
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = (try? c.decodeIfPresent(FaceScanScope.self, forKey: .scope)) ?? .everyTenth
        let frames = (try? c.decodeIfPresent([Int].self, forKey: .thumbFrames)) ?? nil
        thumbFrames = scope == .thumbs ? (frames ?? []) : nil
        lowFrame = (try? c.decodeIfPresent(Int.self, forKey: .lowFrame)) ?? frames?.min() ?? 0
        highFrame = (try? c.decodeIfPresent(Int.self, forKey: .highFrame)) ?? frames?.max() ?? lowFrame
        thresholds = (try? c.decodeIfPresent(FaceThresholds.self, forKey: .thresholds)) ?? nil
        transform = (try? c.decodeIfPresent(MovieTransform.self, forKey: .transform)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(lowFrame, forKey: .lowFrame)
        try c.encode(highFrame, forKey: .highFrame)
        try c.encodeIfPresent(thumbFrames, forKey: .thumbFrames)
        try c.encodeIfPresent(thresholds, forKey: .thresholds)
        try c.encodeIfPresent(transform, forKey: .transform)
    }
}

/// A faces sheet's last Sort: the sort (never `reverse`) and whether
/// Reverse has turned it around since.
public struct FaceSheetSort: Sendable, Equatable {
    public var sort: ThumbSort
    public var reversed: Bool

    public init(sort: ThumbSort, reversed: Bool = false) {
        self.sort = sort == .reverse ? .faceSize : sort
        self.reversed = reversed
    }
}

extension FaceSheetSort: Codable {
    private enum CodingKeys: String, CodingKey {
        case sort, reversed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sort: (try? c.decodeIfPresent(ThumbSort.self, forKey: .sort)) ?? .faceSize,
            reversed: (try? c.decodeIfPresent(Bool.self, forKey: .reversed)) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sort, forKey: .sort)
        try c.encode(reversed, forKey: .reversed)
    }
}

extension Library {
    /// The frames Apply rescans a faces sheet over: those stored with it;
    /// for a sheet made before they were stored, every 10th frame over its
    /// parent sheet's shown thumbs if it has a parent, else over its own
    /// lowest–highest frame, with the thresholds unknown. Nil for other
    /// sheets.
    public func faceSheetSource(_ ref: SheetRef) -> FaceSheetSource? {
        guard let file = file(ref.fileId), let sheet = sheet(ref.sheetId, of: ref.fileId), sheet.type == .faces else {
            return nil
        }
        if let source = sheet.faceSource { return source }
        var frames = sheet.thumbs.map(\.frameNumber)
        if let parentId = sheet.parentSheetId, let parent = self.sheet(parentId, of: ref.fileId) {
            let shown = settings.showHiddenThumbs ? parent.thumbs : parent.visibleThumbs
            if !shown.isEmpty { frames = shown.map(\.frameNumber) }
        }
        return FaceSheetSource(scope: .everyTenth, thumbFrames: frames, frameCount: file.frameCount, thresholds: nil)
    }

    /// Whether Apply would rescan the faces sheet: its thresholds differ
    /// from `thresholds` (or are not known).
    public func faceSheetNeedsRescan(_ ref: SheetRef, thresholds: FaceThresholds) -> Bool {
        guard let source = faceSheetSource(ref) else { return false }
        return source.thresholds != thresholds || faceSheetTransformChanged(ref)
    }

    /// A faces sheet whose face boxes were found with another rotation or
    /// crop than the movie has now (decision 26): its boxes are off until
    /// Apply rescans it.
    public func faceSheetTransformChanged(_ ref: SheetRef) -> Bool {
        guard let file = file(ref.fileId), let sheet = sheet(ref.sheetId, of: ref.fileId), sheet.type == .faces
        else { return false }
        return !(sheet.faceSource?.transform ?? MovieTransform()).sameImage(as: file.transform)
    }

    /// Apply: replaces a faces sheet's thumbs with the scanned frames of
    /// `frames` that contain faces, keeping its name, filter and sort (the
    /// filter applied to the new thumbs, then the last sort, then Reverse
    /// if it was on), and stores `source`. Returns false, changing nothing,
    /// when no frame has a face or the sheet is not a faces sheet.
    @discardableResult
    public mutating func replaceFacesSheetThumbs(
        _ ref: SheetRef, frames: [Int], faces: FaceData, source: FaceSheetSource
    ) -> Bool {
        let thumbs = Self.facesThumbs(frames: frames, faces: faces)
        guard !thumbs.isEmpty, let sheet = sheet(ref.sheetId, of: ref.fileId), sheet.type == .faces else {
            return false
        }
        let sort = sheet.faceSort ?? FaceSheetSort(sort: .faceSize)
        withSheet(ref) { sheet, _ in
            sheet.thumbs = thumbs
            sheet.reindex()
            sheet.faceSource = source
        }
        if let filter = sheet.faceFilter { setFaceFilter(ref, filter) }
        sortThumbs(ref, by: sort.sort, includeHidden: false)
        if sort.reversed { sortThumbs(ref, by: .reverse, includeHidden: false) }
        return true
    }

    /// Thumbs of the analyzed frames of `frames` that have faces.
    static func facesThumbs(frames: [Int], faces: FaceData) -> [Thumb] {
        frames.compactMap { number -> Thumb? in
            guard let frame = faces.frame(number), frame.faceCount > 0 else { return nil }
            return Thumb(frameNumber: number, index: 0, faces: frame.faces)
        }
    }
}
