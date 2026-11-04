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
/// `transformObject`); the math is in `MovieTransformMath.swift`.
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
    /// Next sheet number for `Sheet-N` names; never decreases, so a
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
    /// The faces of the frame, from the face scan (faces sheets, §5);
    /// cleared when the thumb's frame changes.
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
    /// 0–100 (MoviePrint's `score`).
    public var confidence: Double
    /// Box height as a percentage of the frame height.
    public var size: Double
    /// Normalized box (0–1), origin top left.
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
    /// Faces sheets: the Filter menu's ranges (nil until first set).
    public var faceFilter: FaceFilter?
    /// Faces sheets: the frames and thresholds the sheet was scanned with,
    /// for Apply (nil on sheets made before it was stored).
    public var faceSource: FaceSheetSource?
    /// Faces sheets: the last Sort, which Apply sorts the new thumbs by
    /// (nil: the initial sort by face size).
    public var faceSort: FaceSheetSort?

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
    /// Whether frames AVFoundation cannot decode exactly are fetched with
    /// ffmpeg (decision 25); flip here once the measurement decides.
    public static let exactFramesWithFFmpeg = true
    /// Shot detection (§6, `DEFAULT_SCENE_DETECTION_THRESHOLD`).
    public static let shotDetectionThreshold = 6.0
    public static let shotDetectionThresholdRange = 3.0...40.0
    /// Timeline view (§6): `DEFAULT_TIMELINEVIEW_WIDTH_SCALE` and
    /// `DEFAULT_TIMELINEVIEW_MIN_DISPLAY_SCENE_LENGTH_IN_FRAMES`.
    public static let timelineSceneWidthRatio = 50.0
    public static let timelineMinSceneLength = 10
    /// Thumb label maximum, in points per 1000 points of print width.
    public static let frameInfoMaxSize = 25.0
    public static let frameInfoMaxSizeRange = 4.0...100.0
    /// Automatic IN/OUT: frames with a mean V below this count as black
    /// (MoviePrint `IN_OUT_POINT_SEARCH_THRESHOLD`).
    public static let automaticInOutThreshold = 20.0
    public static let automaticInOutThresholdRange = 0.0...255.0
}

public enum FrameInfo: String, Codable, Sendable, CaseIterable {
    case frames, timecode, hidden
}

/// How the frame info shows a timecode (owner, 2026-11-03); the `[TC]`
/// file-name token stays `HH_MM_SS_FF`.
public enum TimecodeFormat: String, Codable, Sendable, CaseIterable {
    case hoursMinutesSecondsFrames, hoursMinutesSeconds, minutesSeconds, hoursMinutesSecondsMilliseconds

    public var label: String {
        switch self {
        case .hoursMinutesSecondsFrames: "HH:MM:SS:FF"
        case .hoursMinutesSeconds: "HH:MM:SS"
        case .minutesSeconds: "MM:SS"
        case .hoursMinutesSecondsMilliseconds: "HH:MM:SS.mmm"
        }
    }
}

/// How the frame info shows a frame number (owner, 2026-11-03): the
/// 4-digit frame alone, or with the movie's last frame number after a
/// slash ("9920 / 17604"), so the label tells how far into the movie the
/// thumb is.
public enum FrameNumberFormat: String, Codable, Sendable, CaseIterable {
    case frame, frameOfLast

    public var label: String {
        switch self {
        case .frame: "Frame"
        case .frameOfLast: "Frame / Total"
        }
    }
}

/// Where the frame info sits on a thumb (MoviePrint `FRAMEINFO_POSITION`).
public enum FrameInfoPosition: String, Codable, Sendable, CaseIterable {
    case topLeft, topCenter, topRight, centerCenter, bottomLeft, bottomCenter, bottomRight

    public var label: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .centerCenter: "Center Center"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// Where the header's file name, folder and details lines sit: at the
/// right as in MoviePrint's `ThumbGridHeader` (the default), or at the left
/// (owner, 2026-11-03).
public enum HeaderAlignment: String, Codable, Sendable, CaseIterable {
    case right, left

    public var label: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        }
    }
}

/// Font family of the frame info on thumbs: one of the three system
/// designs (stored as sentinels) or the name of an installed family.
public enum FrameInfoFamily {
    public static let system = ".System"
    public static let systemCondensed = ".SystemCondensed"
    public static let systemMono = ".SystemMono"
    /// The system designs with their menu labels, listed before the
    /// installed families.
    public static let systemFamilies: [(family: String, label: String)] = [
        (system, "System"), (systemCondensed, "System Condensed"), (systemMono, "System Mono"),
    ]

    public static func isSystem(_ family: String) -> Bool {
        systemFamilies.contains { $0.family == family }
    }

    /// The family for a value of the former `frameInfoFont` setting
    /// (sans, condensed or mono).
    public static func migrated(fromFont font: String) -> String? {
        switch font {
        case "sans": system
        case "condensed": systemCondensed
        case "mono": systemMono
        default: nil
        }
    }
}

/// sRGB color with alpha, components 0–1.
public struct RGBA: Codable, Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    public static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Saved image format (MoviePrint `OUTPUT_FORMAT`).
public enum ImageFormat: String, Codable, Sendable, CaseIterable {
    case png, jpg

    public var fileExtension: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

/// Saved print sizes (MoviePrint `MOVIEPRINT_WIDTH_HEIGHT`): 1024–16384 px
/// in steps of 1024; 16384 is also the limit for "max".
public enum OutputSize {
    public static let defaultSize = 4096
    public static let limit = 16384
    public static let steps = Array(stride(from: 1024, through: limit, by: 1024))

    /// The nearest step, for values from older or edited files.
    public static func snapped(_ size: Int) -> Int {
        let clamped = min(max(size, steps[0]), limit)
        return Int((Double(clamped) / 1024).rounded()) * 1024
    }
}

/// Global settings (§6). Only part of the panel exists yet; the values are
/// kept with MoviePrint's defaults so later TASKs read them from here.
/// Decoding tolerates missing keys so older library files keep loading.
public struct Settings: Codable, Sendable, Equatable {
    /// Grid margin sliders 0–20, horizontal (between columns, left and
    /// right) and vertical (between rows, top and bottom); margin ratio =
    /// value / 200 (MoviePrint `DEFAULT_MARGIN_SLIDER_FACTOR`). Older files
    /// have one `marginSlider`, which seeds both.
    public var marginHorizontal: Double = 4
    public var marginVertical: Double = 4
    /// The margin sliders move together.
    public var marginsLinked = true
    public var showHeader = false
    public var showPathInHeader = true
    public var showDetailsInHeader = true
    public var showTimelineInHeader = true
    public var headerAlignment: HeaderAlignment = .right
    /// Corner radius 0–20 as a percentage of the thumb width; 4 is
    /// MoviePrint's borderRadiusRatio 0.04, 0 is square. Older files have
    /// `roundedCorners` (false → 0).
    public var cornerRadius: Double = 4
    public var showHiddenThumbs = false
    public var frameInfo: FrameInfo = .hidden
    /// Catppuccin Mocha crust on text, in place of MoviePrint's black on
    /// #eee.
    public var frameInfoColor = RGBA(hex: 0x11111B)
    public var frameInfoBackground = RGBA(hex: 0xCDD6F4)
    public var frameInfoPosition: FrameInfoPosition = .topLeft
    /// A `FrameInfoFamily` sentinel or an installed family name. Older
    /// files have `frameInfoFont` (sans, condensed, mono).
    public var frameInfoFontFamily = FrameInfoFamily.systemMono
    /// 1–100, relative to the thumb height.
    public var frameInfoSize: Double = 10
    /// The largest label, in points per 1000 points of print width, so the
    /// saved print (laid out at the output width) matches the window; caps
    /// the size on very large thumbs and scenes. The default leaves
    /// landscape sheets of two or more columns at Size 10 unchanged.
    public var frameInfoMaxSize: Double = Defaults.frameInfoMaxSize
    /// Distance from the thumb edge, 0–50, left/right and top/bottom.
    /// Older files have one `frameInfoMargin`, which seeds both.
    public var frameInfoMarginHorizontal: Double = 0
    public var frameInfoMarginVertical: Double = 0
    /// The frame info margin sliders move together.
    public var frameInfoMarginsLinked = true
    /// The timecode shown with frame info Timecode.
    public var frameInfoTimecodeFormat: TimecodeFormat = .hoursMinutesSecondsFrames
    /// The frame number shown with frame info Frames.
    public var frameInfoFrameFormat: FrameNumberFormat = .frame
    public var thumbnailCacheMB = Defaults.thumbnailCacheMB
    /// User-chosen ffmpeg path (§10); nil means discover it.
    public var ffmpegPath: String?
    /// Fetch a frame AVFoundation cannot decode exactly (open-GOP files)
    /// with ffmpeg, frame by frame, when ffmpeg is available (decision 25).
    public var exactFramesWithFFmpeg = Defaults.exactFramesWithFFmpeg

    // Shot detection and timeline view (§6, §10).
    /// Experimental: Mean (default) or Histogram.
    public var shotDetectionMethod: ShotDetectionMethod = .mean
    /// 3–40.
    public var shotDetectionThreshold = Defaults.shotDetectionThreshold
    /// Experimental: detect IN/OUT from the first and last frames.
    public var automaticInOut = false
    /// Automatic IN/OUT: the mean V (0–255) below which a frame counts as
    /// black.
    public var automaticInOutThreshold = Defaults.automaticInOutThreshold
    /// Shot sheets in timeline view wrap by width.
    public var timelineNaturalFlow = false
    /// Scene width ratio 0–100.
    public var timelineSceneWidthRatio = Defaults.timelineSceneWidthRatio
    /// Minimum scene width in frames (the slider shows 0–10 s).
    public var timelineMinSceneLength = Defaults.timelineMinSceneLength
    /// Timeline scenes show their frame over the mean color; off shows the
    /// mean colors only (toolbar Toggle images, MoviePrint `defaultShowImages`).
    public var timelineShowImages = true

    // Face detection (§6, §10).
    /// Faces below this confidence (0–100) are not stored; next scan.
    public var faceConfidenceThreshold = FaceThresholds.defaultConfidence
    /// Faces smaller than this % of the frame height are not stored.
    public var faceSizeThreshold = FaceThresholds.defaultSize
    /// Toolbar Toggle face rectangles: on thumbs of faces sheets and the
    /// player's still (MoviePrint `DEFAULT_SHOW_FACERECT`, on).
    public var showFaceRectangles = true
    /// Output: draw the face rectangles in saved prints too (off).
    public var includeFaceRectanglesInPrint = false

    public var faceThresholds: FaceThresholds {
        FaceThresholds(confidence: faceConfidenceThreshold, size: faceSizeThreshold)
    }

    // Output (§6), MoviePrint's defaults (`app/utils/constants.js`).
    /// Folder path for saved prints; nil means the Desktop.
    public var outputFolder: String?
    /// Save next to the movie instead of `outputFolder`.
    public var outputSameFolderAsMovie = false
    /// Width of a saved grid print (height in timeline view), one of
    /// `OutputSize.steps`.
    public var outputSize = OutputSize.defaultSize
    /// Save at the largest size the frames allow instead of `outputSize`.
    public var outputSizeMax = false
    public var outputFormat: ImageFormat = .png
    /// JPG quality 0–100.
    public var outputQuality = 80
    /// Print background; alpha applies to PNG only.
    public var outputBackground = RGBA.clear
    public var overwrite = false
    public var includeIndividualThumbs = false
    /// PNG only: embed the frame list (and transform and columns).
    public var embedFrameNumbers = true
    /// PNG only: embed the movie's path.
    public var embedFilePath = true
    public var openFinderAfterSaving = false
    public var thumbFormat: ImageFormat = .jpg
    /// JPG quality 0–100 for saved thumbs.
    public var thumbQuality = 95
    /// Naming scheme templates (`FileNaming`).
    public var sheetNameTemplate = FileNaming.defaultSheetTemplate
    public var singleThumbNameTemplate = FileNaming.defaultSingleThumbTemplate
    public var individualThumbNameTemplate = FileNaming.defaultIndividualThumbTemplate

    public init() {}

    public var marginRatioHorizontal: Double { marginHorizontal / 200 }
    public var marginRatioVertical: Double { marginVertical / 200 }
    public var borderRadiusRatio: Double { cornerRadius / 100 }

    private enum CodingKeys: String, CodingKey {
        case marginHorizontal, marginVertical, marginsLinked
        case showHeader, showPathInHeader, showDetailsInHeader, showTimelineInHeader, headerAlignment
        case cornerRadius, showHiddenThumbs, frameInfo, thumbnailCacheMB, ffmpegPath
        case exactFramesWithFFmpeg
        case shotDetectionMethod, shotDetectionThreshold, automaticInOut, automaticInOutThreshold
        case timelineNaturalFlow, timelineSceneWidthRatio, timelineMinSceneLength, timelineShowImages
        case faceConfidenceThreshold, faceSizeThreshold, showFaceRectangles, includeFaceRectanglesInPrint
        case frameInfoColor, frameInfoBackground, frameInfoPosition, frameInfoSize, frameInfoMaxSize
        case frameInfoFontFamily, frameInfoMarginHorizontal, frameInfoMarginVertical, frameInfoMarginsLinked
        case frameInfoTimecodeFormat, frameInfoFrameFormat
        case outputFolder, outputSameFolderAsMovie, outputSize, outputSizeMax, outputFormat, outputQuality
        case outputBackground, overwrite, includeIndividualThumbs, embedFrameNumbers, embedFilePath
        case openFinderAfterSaving, thumbFormat, thumbQuality
        case sheetNameTemplate, singleThumbNameTemplate, individualThumbNameTemplate
    }

    /// Keys of earlier versions, read only to migrate them.
    private enum LegacyKeys: String, CodingKey {
        case marginSlider, roundedCorners, frameInfoFont, frameInfoMargin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let d = Settings()
        let oldMargin = try? legacy.decodeIfPresent(Double.self, forKey: .marginSlider)
        marginHorizontal = try c.decodeIfPresent(Double.self, forKey: .marginHorizontal) ?? oldMargin ?? d.marginHorizontal
        marginVertical = try c.decodeIfPresent(Double.self, forKey: .marginVertical) ?? oldMargin ?? d.marginVertical
        marginsLinked = try c.decodeIfPresent(Bool.self, forKey: .marginsLinked) ?? d.marginsLinked
        showHeader = try c.decodeIfPresent(Bool.self, forKey: .showHeader) ?? d.showHeader
        showPathInHeader = try c.decodeIfPresent(Bool.self, forKey: .showPathInHeader) ?? d.showPathInHeader
        showDetailsInHeader = try c.decodeIfPresent(Bool.self, forKey: .showDetailsInHeader) ?? d.showDetailsInHeader
        showTimelineInHeader = try c.decodeIfPresent(Bool.self, forKey: .showTimelineInHeader) ?? d.showTimelineInHeader
        headerAlignment = (try? c.decodeIfPresent(HeaderAlignment.self, forKey: .headerAlignment)) ?? d.headerAlignment
        let oldRounded = try? legacy.decodeIfPresent(Bool.self, forKey: .roundedCorners)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
            ?? (oldRounded == false ? 0 : d.cornerRadius)
        showHiddenThumbs = try c.decodeIfPresent(Bool.self, forKey: .showHiddenThumbs) ?? d.showHiddenThumbs
        frameInfo = try c.decodeIfPresent(FrameInfo.self, forKey: .frameInfo) ?? d.frameInfo
        thumbnailCacheMB = try c.decodeIfPresent(Int.self, forKey: .thumbnailCacheMB) ?? d.thumbnailCacheMB
        ffmpegPath = try c.decodeIfPresent(String.self, forKey: .ffmpegPath)
        exactFramesWithFFmpeg = try c.decodeIfPresent(Bool.self, forKey: .exactFramesWithFFmpeg)
            ?? d.exactFramesWithFFmpeg
        shotDetectionMethod = (try? c.decodeIfPresent(ShotDetectionMethod.self, forKey: .shotDetectionMethod))
            ?? d.shotDetectionMethod
        let range = Defaults.shotDetectionThresholdRange
        shotDetectionThreshold = min(max(
            (try? c.decodeIfPresent(Double.self, forKey: .shotDetectionThreshold)) ?? d.shotDetectionThreshold,
            range.lowerBound), range.upperBound)
        automaticInOut = (try? c.decodeIfPresent(Bool.self, forKey: .automaticInOut)) ?? d.automaticInOut
        let inOutRange = Defaults.automaticInOutThresholdRange
        automaticInOutThreshold = min(max(
            (try? c.decodeIfPresent(Double.self, forKey: .automaticInOutThreshold)) ?? d.automaticInOutThreshold,
            inOutRange.lowerBound), inOutRange.upperBound)
        timelineNaturalFlow = (try? c.decodeIfPresent(Bool.self, forKey: .timelineNaturalFlow))
            ?? d.timelineNaturalFlow
        timelineSceneWidthRatio = (try? c.decodeIfPresent(Double.self, forKey: .timelineSceneWidthRatio))
            ?? d.timelineSceneWidthRatio
        timelineMinSceneLength = (try? c.decodeIfPresent(Int.self, forKey: .timelineMinSceneLength))
            ?? d.timelineMinSceneLength
        timelineShowImages = (try? c.decodeIfPresent(Bool.self, forKey: .timelineShowImages))
            ?? d.timelineShowImages
        faceConfidenceThreshold = min(max(
            (try? c.decodeIfPresent(Double.self, forKey: .faceConfidenceThreshold)) ?? d.faceConfidenceThreshold,
            0), 100)
        faceSizeThreshold = min(max(
            (try? c.decodeIfPresent(Double.self, forKey: .faceSizeThreshold)) ?? d.faceSizeThreshold, 0), 100)
        showFaceRectangles = (try? c.decodeIfPresent(Bool.self, forKey: .showFaceRectangles)) ?? d.showFaceRectangles
        includeFaceRectanglesInPrint = (try? c.decodeIfPresent(Bool.self, forKey: .includeFaceRectanglesInPrint))
            ?? d.includeFaceRectanglesInPrint
        frameInfoColor = try c.decodeIfPresent(RGBA.self, forKey: .frameInfoColor) ?? d.frameInfoColor
        frameInfoBackground = try c.decodeIfPresent(RGBA.self, forKey: .frameInfoBackground) ?? d.frameInfoBackground
        frameInfoPosition = try c.decodeIfPresent(FrameInfoPosition.self, forKey: .frameInfoPosition) ?? d.frameInfoPosition
        let oldFont = (try? legacy.decodeIfPresent(String.self, forKey: .frameInfoFont))
            .flatMap(FrameInfoFamily.migrated(fromFont:))
        frameInfoFontFamily = (try? c.decodeIfPresent(String.self, forKey: .frameInfoFontFamily))
            ?? oldFont ?? d.frameInfoFontFamily
        frameInfoSize = try c.decodeIfPresent(Double.self, forKey: .frameInfoSize) ?? d.frameInfoSize
        frameInfoMaxSize = (try? c.decodeIfPresent(Double.self, forKey: .frameInfoMaxSize))
            .map { min(max($0, Defaults.frameInfoMaxSizeRange.lowerBound), Defaults.frameInfoMaxSizeRange.upperBound) }
            ?? d.frameInfoMaxSize
        let oldInfoMargin = try? legacy.decodeIfPresent(Double.self, forKey: .frameInfoMargin)
        frameInfoMarginHorizontal = try c.decodeIfPresent(Double.self, forKey: .frameInfoMarginHorizontal)
            ?? oldInfoMargin ?? d.frameInfoMarginHorizontal
        frameInfoMarginVertical = try c.decodeIfPresent(Double.self, forKey: .frameInfoMarginVertical)
            ?? oldInfoMargin ?? d.frameInfoMarginVertical
        frameInfoMarginsLinked = try c.decodeIfPresent(Bool.self, forKey: .frameInfoMarginsLinked)
            ?? d.frameInfoMarginsLinked
        frameInfoTimecodeFormat = (try? c.decodeIfPresent(TimecodeFormat.self, forKey: .frameInfoTimecodeFormat))
            ?? d.frameInfoTimecodeFormat
        frameInfoFrameFormat = (try? c.decodeIfPresent(FrameNumberFormat.self, forKey: .frameInfoFrameFormat))
            ?? d.frameInfoFrameFormat
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder)
        outputSameFolderAsMovie = try c.decodeIfPresent(Bool.self, forKey: .outputSameFolderAsMovie)
            ?? d.outputSameFolderAsMovie
        outputSize = OutputSize.snapped(try c.decodeIfPresent(Int.self, forKey: .outputSize) ?? d.outputSize)
        outputSizeMax = try c.decodeIfPresent(Bool.self, forKey: .outputSizeMax) ?? d.outputSizeMax
        outputFormat = (try? c.decodeIfPresent(ImageFormat.self, forKey: .outputFormat)) ?? d.outputFormat
        outputQuality = try c.decodeIfPresent(Int.self, forKey: .outputQuality) ?? d.outputQuality
        outputBackground = try c.decodeIfPresent(RGBA.self, forKey: .outputBackground) ?? d.outputBackground
        overwrite = try c.decodeIfPresent(Bool.self, forKey: .overwrite) ?? d.overwrite
        includeIndividualThumbs = try c.decodeIfPresent(Bool.self, forKey: .includeIndividualThumbs)
            ?? d.includeIndividualThumbs
        embedFrameNumbers = try c.decodeIfPresent(Bool.self, forKey: .embedFrameNumbers) ?? d.embedFrameNumbers
        embedFilePath = try c.decodeIfPresent(Bool.self, forKey: .embedFilePath) ?? d.embedFilePath
        openFinderAfterSaving = try c.decodeIfPresent(Bool.self, forKey: .openFinderAfterSaving)
            ?? d.openFinderAfterSaving
        thumbFormat = (try? c.decodeIfPresent(ImageFormat.self, forKey: .thumbFormat)) ?? d.thumbFormat
        thumbQuality = try c.decodeIfPresent(Int.self, forKey: .thumbQuality) ?? d.thumbQuality
        sheetNameTemplate = try c.decodeIfPresent(String.self, forKey: .sheetNameTemplate) ?? d.sheetNameTemplate
        singleThumbNameTemplate = try c.decodeIfPresent(String.self, forKey: .singleThumbNameTemplate)
            ?? d.singleThumbNameTemplate
        individualThumbNameTemplate = try c.decodeIfPresent(String.self, forKey: .individualThumbNameTemplate)
            ?? d.individualThumbNameTemplate
    }
}

/// The whole document: movies in list order, their sheets, settings and
/// the current selection.
public struct Library: Codable, Sendable, Equatable {
    /// 2: sheets are named `Sheet-N` (1 used `MoviePrint-N`).
    public static let currentVersion = 2

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

    /// Adds a sheet to a file with the next `Sheet-N` name.
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

    /// Brings a library decoded from an older file up to the current
    /// version: version 1 named sheets `MoviePrint-N`.
    public mutating func migrate() {
        guard version < Library.currentVersion else { return }
        if version < 2 {
            for (fileId, list) in sheets {
                sheets[fileId] = list.map { sheet in
                    var sheet = sheet
                    if let name = SheetNaming.migratedName(sheet.name) { sheet.name = name }
                    return sheet
                }
            }
        }
        version = Library.currentVersion
    }

    public mutating func removeAll() {
        files = []
        sheets = [:]
        currentFileId = nil
        currentSheetId = nil
    }
}
