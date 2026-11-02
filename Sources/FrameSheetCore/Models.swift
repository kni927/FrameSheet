import Foundation

// The v3 document model (docs/V3_SPEC.md §3). Everything here is a value
// type and Codable; the library is persisted as one JSON file
// (LibraryStore).

public enum SheetType: String, Codable, Sendable, CaseIterable {
    case interval, shot, faces

    public var label: String {
        switch self {
        case .interval: "Interval"
        case .shot: "Shot detection"
        case .faces: "Faces"
        }
    }
}

public enum SheetView: String, Codable, Sendable {
    case grid, timeline
}

/// Rotation, crop and aspect ratio applied to a movie (MoviePrint's
/// `transformObject`). Not editable yet; carried so the model is complete.
public struct MovieTransform: Codable, Sendable, Equatable {
    /// Clockwise rotation in degrees: 0, 90, 180 or 270.
    public var rotation: Int = 0
    public var cropTop: Int = 0
    public var cropBottom: Int = 0
    public var cropLeft: Int = 0
    public var cropRight: Int = 0
    /// Height / width override; nil keeps the movie's own ratio.
    public var aspectRatioInv: Double?

    public init() {}
}

public enum ScanState: String, Codable, Sendable {
    case none, scanning, scanned
}

public struct MovieFile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var url: URL
    public var bookmark: Data?
    public var name: String
    public var folder: String
    /// Seconds.
    public var duration: Double
    public var frameCount: Int
    public var fps: Double
    public var width: Int
    public var height: Int
    /// Bytes.
    public var size: Int64
    public var fourCC: String
    /// Frame shown in the movie list.
    public var posterFrame: Int
    public var transform: MovieTransform
    public var inFrame: Int
    public var outFrame: Int
    public var scanState: ScanState
    /// Next sheet number for `MoviePrint-N` names; never decreases, so a
    /// deleted sheet's name is not reused (MoviePrint counts sheets the
    /// same way).
    public var sheetCounter: Int

    public init(
        id: UUID = UUID(), url: URL, bookmark: Data? = nil, duration: Double, frameCount: Int,
        fps: Double, width: Int, height: Int, size: Int64, fourCC: String
    ) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.name = url.lastPathComponent
        self.folder = url.deletingLastPathComponent().path
        self.duration = duration
        self.frameCount = frameCount
        self.fps = fps
        self.width = width
        self.height = height
        self.size = size
        self.fourCC = fourCC
        self.posterFrame = frameCount / 2
        self.transform = MovieTransform()
        self.inFrame = 0
        self.outFrame = max(0, frameCount - 1)
        self.scanState = .none
        self.sheetCounter = 0
    }
}

public struct Thumb: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var frameNumber: Int
    /// Position in the sheet (MoviePrint's `index`); kept in step with the
    /// array order.
    public var index: Int
    public var hidden: Bool
    /// Per-frame face data; filled by the face scan (not built yet).
    public var faces: [Face]

    public init(id: UUID = UUID(), frameNumber: Int, index: Int, hidden: Bool = false, faces: [Face] = []) {
        self.id = id
        self.frameNumber = frameNumber
        self.index = index
        self.hidden = hidden
        self.faces = faces
    }
}

public struct Face: Codable, Sendable, Equatable {
    public var confidence: Double
    /// Box height as a percentage of the frame height.
    public var size: Double
    /// Normalised box (0–1), origin top left.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(confidence: Double, size: Double, x: Double, y: Double, width: Double, height: Double) {
        self.confidence = confidence
        self.size = size
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct Scene: Codable, Sendable, Identifiable, Equatable {
    /// Same as the id of the scene's thumb.
    public var id: UUID
    public var start: Int
    public var length: Int
    /// sRGB, 0–255.
    public var colorRGB: [Int]
    public var hidden: Bool

    public init(id: UUID, start: Int, length: Int, colorRGB: [Int], hidden: Bool = false) {
        self.id = id
        self.start = start
        self.length = length
        self.colorRGB = colorRGB
        self.hidden = hidden
    }
}

public struct Sheet: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var type: SheetType
    public var view: SheetView
    public var columnCount: Int
    public var secondsPerRow: Double
    public var parentSheetId: UUID?
    public var thumbs: [Thumb]
    public var scenes: [Scene]

    public init(
        id: UUID = UUID(), name: String, type: SheetType, view: SheetView = .grid,
        columnCount: Int = Defaults.columnCount, secondsPerRow: Double = Defaults.secondsPerRow,
        parentSheetId: UUID? = nil, thumbs: [Thumb] = [], scenes: [Scene] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.view = view
        self.columnCount = columnCount
        self.secondsPerRow = secondsPerRow
        self.parentSheetId = parentSheetId
        self.thumbs = thumbs
        self.scenes = scenes
    }

    public var visibleThumbs: [Thumb] { thumbs.filter { !$0.hidden } }
}

/// Default values from MoviePrint 0.2.23 (`app/utils/constants.js`).
public enum Defaults {
    public static let thumbCount = 16
    public static let columnCount = 4
    public static let secondsPerRow = 120.0
    public static let thumbnailCacheMB = 256
}

public enum FrameInfo: String, Codable, Sendable {
    case frames, timecode, hidden
}

/// Global settings (§6). Only part of the panel exists yet; the values are
/// kept with MoviePrint's defaults so later TASKs read them from here.
/// Decoding tolerates missing keys so older library files keep loading.
public struct Settings: Codable, Sendable, Equatable {
    /// Grid margin slider 0–20; margin ratio = value / 200 (MoviePrint
    /// `DEFAULT_MARGIN_SLIDER_FACTOR`).
    public var marginSlider: Double = 4
    public var showHeader = false
    public var showPathInHeader = true
    public var showDetailsInHeader = true
    public var showTimelineInHeader = true
    public var roundedCorners = true
    public var showHiddenThumbs = false
    public var frameInfo: FrameInfo = .hidden
    public var thumbnailCacheMB = Defaults.thumbnailCacheMB
    /// User-chosen ffmpeg path (§10); nil means discover it.
    public var ffmpegPath: String?

    public init() {}

    public var marginRatio: Double { marginSlider / 200 }

    private enum CodingKeys: String, CodingKey {
        case marginSlider, showHeader, showPathInHeader, showDetailsInHeader, showTimelineInHeader
        case roundedCorners, showHiddenThumbs, frameInfo, thumbnailCacheMB, ffmpegPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        marginSlider = try c.decodeIfPresent(Double.self, forKey: .marginSlider) ?? d.marginSlider
        showHeader = try c.decodeIfPresent(Bool.self, forKey: .showHeader) ?? d.showHeader
        showPathInHeader = try c.decodeIfPresent(Bool.self, forKey: .showPathInHeader) ?? d.showPathInHeader
        showDetailsInHeader = try c.decodeIfPresent(Bool.self, forKey: .showDetailsInHeader) ?? d.showDetailsInHeader
        showTimelineInHeader = try c.decodeIfPresent(Bool.self, forKey: .showTimelineInHeader) ?? d.showTimelineInHeader
        roundedCorners = try c.decodeIfPresent(Bool.self, forKey: .roundedCorners) ?? d.roundedCorners
        showHiddenThumbs = try c.decodeIfPresent(Bool.self, forKey: .showHiddenThumbs) ?? d.showHiddenThumbs
        frameInfo = try c.decodeIfPresent(FrameInfo.self, forKey: .frameInfo) ?? d.frameInfo
        thumbnailCacheMB = try c.decodeIfPresent(Int.self, forKey: .thumbnailCacheMB) ?? d.thumbnailCacheMB
        ffmpegPath = try c.decodeIfPresent(String.self, forKey: .ffmpegPath)
    }
}

/// The whole document: movies in list order, their sheets, settings and
/// the current selection.
public struct Library: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = Library.currentVersion
    public var files: [MovieFile] = []
    /// Sheets per file id, in list order.
    public var sheets: [UUID: [Sheet]] = [:]
    public var settings = Settings()
    public var currentFileId: UUID?
    public var currentSheetId: UUID?

    public init() {}

    public func file(_ id: UUID) -> MovieFile? { files.first { $0.id == id } }

    public func sheet(_ sheetId: UUID, of fileId: UUID) -> Sheet? {
        sheets[fileId]?.first { $0.id == sheetId }
    }

    /// Adds a sheet to a file with the next `MoviePrint-N` name.
    @discardableResult
    public mutating func addSheet(
        to fileId: UUID, type: SheetType, view: SheetView = .grid, thumbs: [Thumb]
    ) -> Sheet? {
        guard let i = files.firstIndex(where: { $0.id == fileId }) else { return nil }
        let name = SheetNaming.newSheetName(sheetCount: files[i].sheetCounter)
        files[i].sheetCounter += 1
        let sheet = Sheet(name: name, type: type, view: view, thumbs: thumbs)
        sheets[fileId, default: []].append(sheet)
        return sheet
    }

    /// Adds the default interval sheet (16 thumbs between IN and OUT).
    @discardableResult
    public mutating func addDefaultIntervalSheet(to fileId: UUID) -> Sheet? {
        guard let file = file(fileId) else { return nil }
        let frames = IntervalFrames.frameNumbers(
            amount: Defaults.thumbCount, start: file.inFrame, stop: file.outFrame,
            maxValue: file.frameCount, limitToMaxValue: true)
        let thumbs = frames.enumerated().map { Thumb(frameNumber: $1, index: $0) }
        return addSheet(to: fileId, type: .interval, thumbs: thumbs)
    }

    public mutating func removeAll() {
        files = []
        sheets = [:]
        currentFileId = nil
        currentSheetId = nil
    }
}
