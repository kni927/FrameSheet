import CoreGraphics
import Foundation

// Timeline view layout (§6, §10). Ported from MoviePrint v0.2.23 (MIT,
// docs/licenses/MoviePrint-LICENSE): `getScenesInRows` and
// `getPixelPerFrameRatio` (app/utils/utils.js), the timeline part of
// `getScaleValueObject` (app/utils/getScaleValueObject.js: the scene width
// ratio multiplier, print height = MoviePrint width, the timeline margin and
// row height) and the scene widths and line breaks of `SceneGrid`
// (app/components/SceneGrid.js). Differences: rows hold `secondsPerRow ×
// fps` frames at the movie's own fps (MoviePrint hard-codes 25; owner,
// 2026-11-01), and sizes are not floored to whole pixels, so the window and
// the saved print are the same layout at different scales.

/// One row of the timeline (MoviePrint's `rowArray` entry).
public struct TimelineRow: Equatable, Sendable {
    /// Index of the row's last scene.
    public var lastIndex: Int
    /// Frame after the row's last scene, counted from the first scene's start.
    public var sceneOutPoint: Int
    /// Scene lengths in the row, in order.
    public var sceneLengths: [Int]

    public var itemCount: Int { sceneLengths.count }
    /// Summed length of the row's scenes.
    public var length: Int { sceneLengths.reduce(0, +) }

    public init(lastIndex: Int, sceneOutPoint: Int, sceneLengths: [Int]) {
        self.lastIndex = lastIndex
        self.sceneOutPoint = sceneOutPoint
        self.sceneLengths = sceneLengths
    }
}

public enum TimelineLayout {
    /// Height of the unscaled print; the margin is MoviePrint's printing
    /// margin at this height (`originalTimelineMoviePrintHeight / 1024`).
    public static let basisHeight = 1024.0
    /// MoviePrint multiplies the grid's margin ratio by 50 for the timeline,
    /// "to compensate for the low value range".
    public static let marginFactor = 50.0
    public static let secondsPerRowRange = 10.0...1800.0
    /// Min scene width slider, in seconds.
    public static let minSceneSecondsRange = 0.0...10.0

    /// MoviePrint's `getScenesInRows`: scenes go into a row until the summed
    /// length exceeds `framesPerRow`; the scene that crosses it starts the
    /// next row, unless it is alone, then it closes its own row.
    public static func scenesInRows(lengths: [Int], firstStart: Int = 0, framesPerRow: Double) -> [TimelineRow] {
        guard !lengths.isEmpty else { return [] }
        var inRow: [Int] = []
        var rows: [TimelineRow] = []
        var previousOutPoint = firstStart
        for (index, length) in lengths.enumerated() {
            let outPoint = previousOutPoint + length
            inRow.append(length)
            if Double(inRow.reduce(0, +)) > framesPerRow {
                if inRow.count == 1 {
                    rows.append(TimelineRow(lastIndex: index, sceneOutPoint: outPoint, sceneLengths: inRow))
                    inRow.removeAll()
                } else {
                    rows.append(TimelineRow(
                        lastIndex: index - 1, sceneOutPoint: previousOutPoint, sceneLengths: Array(inRow.dropLast())))
                    inRow = [length]
                }
            }
            if index == lengths.count - 1 {
                rows.append(TimelineRow(lastIndex: index, sceneOutPoint: outPoint, sceneLengths: inRow))
            }
            previousOutPoint = outPoint
        }
        return rows
    }

    /// MoviePrint's `getPixelPerFrameRatio`: per row, the pixels per frame at
    /// which its scenes (those not longer than the minimum counted at the
    /// minimum) and their margins fill `width`; the smallest over the rows.
    public static func pixelPerFrameRatio(
        rows: [TimelineRow], margin: Double, width: Double, minSceneLength: Int
    ) -> Double? {
        guard !rows.isEmpty else { return nil }
        let minimum = max(0, minSceneLength)
        let ratios = rows.map { row -> Double in
            let short = row.sceneLengths.filter { $0 <= minimum }
            let others = row.length - short.reduce(0, +)
            let frames = Double(short.count * minimum + others)
            return (width - Double(row.itemCount) * margin * 2) / frames
        }
        return ratios.min()
    }

    /// The scene width ratio slider (0–100) as MoviePrint's multiplier
    /// (`v / 55.5555 + 0.1` up to 50, else `(v − 50) / 5.55555 + 1`): print
    /// width = print height × multiplier.
    public static func widthMultiplier(sceneWidthRatio v: Double) -> Double {
        v <= 50 ? v / 55.5555 + 0.1 : (v - 50) / 5.55555 + 1
    }

    /// The timeline stats (MoviePrint `SettingsList`): the movie's length
    /// in whole minutes, and cuts per minute = round((shots − 1) / exact
    /// minutes).
    public static func stats(shots: Int, frameCount: Int, fps: Double) -> (minutes: Int, cutsPerMinute: Int) {
        let minutes = Double(max(0, frameCount)) / ((fps > 0 ? fps : 25) * 60)
        let cuts = minutes > 0 ? Int((Double(shots - 1) / minutes).rounded()) : 0
        return (Int(minutes.rounded()), max(0, cuts))
    }

    /// Settings stats line for the timeline view: "N Shots / ~M Minutes ≈
    /// X cut/min".
    public static func statsLine(shots: Int, frameCount: Int, fps: Double) -> String {
        let (minutes, cuts) = stats(shots: shots, frameCount: frameCount, fps: fps)
        return "\(shots) \(shots == 1 ? "Shot" : "Shots") / ~\(minutes) \(minutes == 1 ? "Minute" : "Minutes") ≈ \(cuts) cut/min"
    }

    /// Min scene width in frames for the slider's seconds, and back
    /// (MoviePrint stores frames and shows `round(frames / fps)`).
    public static func minSceneFrames(seconds: Double, fps: Double) -> Int {
        Int((seconds * (fps > 0 ? fps : 25)).rounded())
    }

    public static func minSceneSeconds(frames: Int, fps: Double) -> Double {
        (Double(frames) / (fps > 0 ? fps : 25)).rounded()
    }
}

/// Layout of a sheet in timeline view: rows of scene boxes, each as wide as
/// its length (at least the minimum length) at the pixels per frame that
/// fit the longest row, all rows equally high. Positions are in the print,
/// origin top left; each scene has the margin on every side (MoviePrint's
/// floated boxes with `margin`).
public struct TimelineGeometry: Equatable, Sendable {
    public struct Input: Sendable {
        public var movieWidth: Double
        public var movieHeight: Double
        public var aspectRatioInv: Double?
        /// Scene lengths in order.
        public var sceneLengths: [Int]
        public var firstStart: Int
        public var fps: Double
        public var secondsPerRow: Double
        /// 0–100 (§6).
        public var sceneWidthRatio: Double
        /// Frames.
        public var minSceneLength: Int
        public var marginRatioHorizontal: Double
        public var marginRatioVertical: Double
        /// Wrap by width instead of by `secondsPerRow` (shot sheets).
        public var naturalFlow: Bool
        public var borderRadiusRatio: Double
        public var containerWidth: Double
        public var containerHeight: Double
        public var zoom: Double
        /// The scene drawn at full aspect width (window selection).
        public var expandedIndex: Int?

        public init(
            movieWidth: Double, movieHeight: Double, aspectRatioInv: Double? = nil, sceneLengths: [Int],
            firstStart: Int = 0, fps: Double, secondsPerRow: Double = Defaults.secondsPerRow,
            sceneWidthRatio: Double = Defaults.timelineSceneWidthRatio,
            minSceneLength: Int = Defaults.timelineMinSceneLength, marginRatioHorizontal: Double = 0.02,
            marginRatioVertical: Double = 0.02, naturalFlow: Bool = false,
            borderRadiusRatio: Double = GridGeometry.borderRadiusRatio, containerWidth: Double,
            containerHeight: Double, zoom: Double = 1, expandedIndex: Int? = nil
        ) {
            self.movieWidth = movieWidth
            self.movieHeight = movieHeight
            self.aspectRatioInv = aspectRatioInv
            self.sceneLengths = sceneLengths
            self.firstStart = firstStart
            self.fps = fps
            self.secondsPerRow = secondsPerRow
            self.sceneWidthRatio = sceneWidthRatio
            self.minSceneLength = minSceneLength
            self.marginRatioHorizontal = marginRatioHorizontal
            self.marginRatioVertical = marginRatioVertical
            self.naturalFlow = naturalFlow
            self.borderRadiusRatio = borderRadiusRatio
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.zoom = zoom
            self.expandedIndex = expandedIndex
        }
    }

    public let rows: [TimelineRow]
    public let widthMultiplier: Double
    public let aspectRatioInv: Double
    /// Fit scale × zoom applied to the unscaled print (height 1024).
    public let scale: Double
    public let fitWidthScale: Double
    public let fitHeightScale: Double
    /// The print at this scale: height × multiplier wide.
    public let printWidth: Double
    public let printHeight: Double
    public let rowHeight: Double
    public let pixelPerFrame: Double
    /// Margin around each scene, left and right / top and bottom.
    public let marginHorizontal: Double
    public let marginVertical: Double
    public let borderRadius: Double
    /// Width of a scene at full aspect (the expanded scene).
    public let fullWidth: Double
    /// One box per scene, in order.
    public let sceneFrames: [CGRect]

    public init(_ input: Input) {
        let movieWidth = input.movieWidth > 0 ? input.movieWidth : 1920
        let movieHeight = input.movieHeight > 0 ? input.movieHeight : 1080
        let ratioInv = input.aspectRatioInv ?? movieHeight / movieWidth
        let fps = input.fps > 0 ? input.fps : 25
        let multiplier = TimelineLayout.widthMultiplier(sceneWidthRatio: min(max(input.sceneWidthRatio, 0), 100))
        let height = TimelineLayout.basisHeight
        let width = height * multiplier
        let unit = height / TimelineLayout.basisHeight
        let mH = unit * input.marginRatioHorizontal * TimelineLayout.marginFactor
        let mV = unit * input.marginRatioVertical * TimelineLayout.marginFactor
        let rows = TimelineLayout.scenesInRows(
            lengths: input.sceneLengths, firstStart: input.firstStart, framesPerRow: input.secondsPerRow * fps)
        let rowCount = Double(max(1, rows.count))
        let rowHeight = max(1, (height - mV * rowCount * 2) / rowCount)
        let minLength = max(0, input.minSceneLength)
        var ppf = TimelineLayout.pixelPerFrameRatio(rows: rows, margin: mH, width: width, minSceneLength: minLength) ?? 0
        if !ppf.isFinite || ppf <= 0 { ppf = 1e-6 }
        let fullWidth = rowHeight / ratioInv

        let fitWidth = max(0, input.containerWidth / width)
        let fitHeight = max(0, input.containerHeight / height)
        let scale = min(fitWidth, fitHeight) * input.zoom

        // Positions: a line break after each row's last scene, or (natural
        // flow) when the next box would pass the print's right edge.
        var frames: [CGRect] = []
        frames.reserveCapacity(input.sceneLengths.count)
        let breaks = Set(rows.map(\.lastIndex))
        var x = 0.0
        var row = 0
        for (index, length) in input.sceneLengths.enumerated() {
            let w = index == input.expandedIndex
                ? fullWidth : max(ppf * Double(length), ppf * Double(minLength))
            if input.naturalFlow, x > 0, x + w + mH * 2 > width * (1 + 1e-9) {
                x = 0
                row += 1
            }
            let y = Double(row) * (rowHeight + mV * 2) + mV
            frames.append(CGRect(x: (x + mH) * scale, y: y * scale, width: max(0, w) * scale, height: rowHeight * scale))
            x += w + mH * 2
            if !input.naturalFlow, breaks.contains(index) {
                x = 0
                row += 1
            }
        }

        self.rows = rows
        widthMultiplier = multiplier
        aspectRatioInv = ratioInv
        self.scale = scale
        fitWidthScale = fitWidth
        fitHeightScale = fitHeight
        printWidth = width * scale
        printHeight = height * scale
        self.rowHeight = rowHeight * scale
        pixelPerFrame = ppf * scale
        marginHorizontal = mH * scale
        marginVertical = mV * scale
        self.fullWidth = fullWidth * scale
        borderRadius = fullWidth * max(0, input.borderRadiusRatio) * scale
        sceneFrames = frames
    }

    /// The print's size, grown to hold scenes past its edges (an expanded
    /// scene, or more rows in natural flow).
    public var contentSize: CGSize {
        let maxX = sceneFrames.map { $0.maxX + marginHorizontal }.max() ?? 0
        let maxY = sceneFrames.map { $0.maxY + marginVertical }.max() ?? 0
        return CGSize(width: max(printWidth, maxX), height: max(printHeight, maxY))
    }

    /// Print height / width.
    public var printAspectRatioInv: Double { printWidth > 0 ? printHeight / printWidth : 0 }
}

/// How much a print fills its area, for Fit height and Fit width.
public protocol PrintFit {
    var scale: Double { get }
    var fitWidthScale: Double { get }
    var fitHeightScale: Double { get }
}

extension PrintFit {
    public var fitScale: Double { min(fitWidthScale, fitHeightScale) }
    public var zoomFillingHeight: Double { GridGeometry.zoom(filling: fitHeightScale, fit: fitScale) }
    public var zoomFillingWidth: Double { GridGeometry.zoom(filling: fitWidthScale, fit: fitScale) }
    public var hasSpaceAboveAndBelow: Bool { scale < fitHeightScale * (1 - GridGeometry.fillTolerance) }
    public var hasSpaceAtSides: Bool { scale < fitWidthScale * (1 - GridGeometry.fillTolerance) }
}

extension TimelineGeometry: PrintFit {}

extension TimelineGeometry.Input {
    /// The timeline input for a movie, a sheet and its timeline scenes
    /// (`SceneList.timelineScenes`), and the settings; Natural flow applies
    /// to shot sheets only (MoviePrint offers it there).
    public init(
        file: MovieFile, sheet: Sheet, scenes: [Scene], settings: Settings, containerWidth: Double,
        containerHeight: Double, zoom: Double = 1, expandedIndex: Int? = nil
    ) {
        self.init(
            movieWidth: Double(file.frameSize.width), movieHeight: Double(file.frameSize.height),
            aspectRatioInv: file.transform.aspectRatioInv, sceneLengths: scenes.map(\.length),
            firstStart: scenes.first?.start ?? 0, fps: file.fps, secondsPerRow: sheet.secondsPerRow,
            sceneWidthRatio: settings.timelineSceneWidthRatio, minSceneLength: settings.timelineMinSceneLength,
            marginRatioHorizontal: settings.marginRatioHorizontal, marginRatioVertical: settings.marginRatioVertical,
            naturalFlow: settings.timelineNaturalFlow && sheet.type == .shot, borderRadiusRatio: settings.borderRadiusRatio,
            containerWidth: containerWidth, containerHeight: containerHeight, zoom: zoom,
            expandedIndex: expandedIndex)
    }
}
