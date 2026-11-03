import Foundation

public enum GridLayout {
    /// Optimise grid layout: columns = ceil(√n), at least 1, at most 20.
    public static func optimisedColumns(thumbCount: Int) -> Int {
        min(20, max(1, Int(Double(max(1, thumbCount)).squareRoot().rounded(.up))))
    }

    /// Rows needed for `thumbCount` thumbs in `columns` columns.
    public static func rows(columns: Int, thumbCount: Int) -> Int {
        let c = max(1, columns)
        return (max(0, thumbCount) + c - 1) / c
    }

    /// Columns that lay `thumbCount` thumbs out in `rows` rows (the Rows
    /// slider rearranges): ceil(n / rows), at least 1, at most 20.
    public static func columns(rows: Int, thumbCount: Int) -> Int {
        let r = max(1, rows)
        return min(20, max(1, (max(0, thumbCount) + r - 1) / r))
    }

    /// Settings stats line for the grid view: "C Columns × R Rows = count".
    public static func statsLine(columns: Int, thumbCount: Int) -> String {
        "\(max(1, columns)) Columns × \(rows(columns: columns, thumbCount: thumbCount)) Rows = \(thumbCount)"
    }

    /// Zoom step after `zoom` in `GridGeometry.zoomSteps`, in or out.
    public static func zoom(from zoom: Double, in zoomIn: Bool) -> Double {
        let steps = GridGeometry.zoomSteps
        if zoomIn {
            return steps.first { $0 > zoom + 1e-9 } ?? steps.last!
        }
        return steps.last { $0 < zoom - 1e-9 } ?? steps.first!
    }
}

public enum FrameInfoText {
    /// The label on a thumb: 4-digit frame number, timecode in
    /// `timecodeFormat` (HH:MM:SS:FF by default), or nothing.
    public static func text(
        _ mode: FrameInfo, frame: Int, fps: Double, timecodeFormat: TimecodeFormat = .hoursMinutesSecondsFrames
    ) -> String? {
        switch mode {
        case .frames: String(format: "%04d", max(0, frame))
        case .timecode: Timecode.string(frames: frame, fps: fps, format: timecodeFormat)
        case .hidden: nil
        }
    }

    /// Font size in points for a thumb of this height: MoviePrint scales a
    /// 10 px label by size × 0.1 × (thumbInfoRatio 0.075 × thumb height) / 10.
    public static func fontSize(size: Double, thumbHeight: Double) -> Double {
        size / 10 * 0.075 * thumbHeight
    }

    /// Frame info cycles frames → timecode → none (toolbar).
    public static func next(after mode: FrameInfo) -> FrameInfo {
        switch mode {
        case .frames: .timecode
        case .timecode: .hidden
        case .hidden: .frames
        }
    }
}
