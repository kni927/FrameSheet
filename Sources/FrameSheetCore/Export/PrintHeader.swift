import Foundation

// Text and mini-timeline values of the print header (§5.2), from MoviePrint
// v0.2.23 `ThumbGrid` and `ThumbGridHeader` (app/components/) with
// `formatBytes`, `roundNumber` and `getFrameInPercentage`
// (app/utils/utils.js) (MIT, docs/licenses/MoviePrint-LICENSE).

public enum PrintHeader {
    /// MoviePrint `TIMELINE_SCENE_MINIMUM_WIDTH`: the IN/OUT range is at
    /// least 2 % of the timeline wide.
    public static let minimumRangeWidth = 0.02

    /// `TC | fps FPS | W × H | size | fourCC`, e.g.
    /// "00:06:48:12 | 23.98 FPS | 1280 × 720 | 39.2 MB | avc1".
    public static func detailsLine(file: MovieFile) -> String {
        let fps = file.fps > 0 ? file.fps : 25
        return [
            Timecode.string(frames: file.frameCount, fps: fps),
            "\(formatNumber(fps, decimals: 2)) FPS",
            "\(file.width) × \(file.height)",
            formatBytes(file.size),
            file.fourCC,
        ].joined(separator: " | ")
    }

    /// The folder line: the movie's folder with a trailing slash.
    public static func folderLine(file: MovieFile) -> String {
        let folder = file.url.deletingLastPathComponent().path
        return folder.hasSuffix("/") ? folder : folder + "/"
    }

    /// MoviePrint `formatBytes(bytes, 1)`: powers of 1024, one decimal,
    /// trailing ".0" dropped ("39.2 MB", "4 GB", "0 Bytes").
    public static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 Bytes" }
        let units = ["Bytes", "KB", "MB", "GB", "TB", "PB", "EB"]
        let i = min(units.count - 1, Int((log(Double(bytes)) / log(1024)).rounded(.down)))
        let value = Double(bytes) / pow(1024, Double(i))
        return "\(formatNumber(value, decimals: 1)) \(units[i])"
    }

    /// Rounded to `decimals` like JavaScript (`Math.round`, then
    /// `toString`): no trailing zeros ("25", "23.98", "29.97").
    static func formatNumber(_ value: Double, decimals: Int) -> String {
        let factor = pow(10, Double(decimals))
        let rounded = IntervalFrames.jsRound(value * factor + Double.ulpOfOne) / factor
        var text = String(format: "%.\(decimals)f", rounded)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// Mini timeline positions as fractions (0–1) of the movie length.
    public struct Timeline: Equatable, Sendable {
        /// Start of the range from the lowest to the highest thumb frame
        /// (MoviePrint marks the thumbs' span, not the movie's IN/OUT).
        public var rangeStart: Double
        /// At least `minimumRangeWidth`.
        public var rangeWidth: Double
        /// Each thumb, in sheet order.
        public var thumbPositions: [Double]
    }

    /// Positions for the thumbs shown in the print; a frame's position is
    /// frame / (frameCount − 1), 0 for a movie of one frame or less.
    public static func timeline(frameNumbers: [Int], frameCount: Int) -> Timeline {
        func position(_ frame: Int) -> Double {
            frameCount > 1 ? Double(frame) / Double(frameCount - 1) : 0
        }
        let start = frameNumbers.min().map(position) ?? 0
        let end = frameNumbers.max().map(position) ?? 0
        return Timeline(
            rangeStart: start, rangeWidth: max(end - start, minimumRangeWidth),
            thumbPositions: frameNumbers.map(position))
    }
}
