import Foundation

public enum GridLayout {
    /// Optimize grid layout: columns = ceil(√n), at least 1, at most 20.
    public static func optimizedColumns(thumbCount: Int) -> Int {
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
    /// The label on a thumb: the 4-digit frame number (with
    /// `frameOfLast`, followed by " / " and the movie's last frame number,
    /// frame count − 1), the timecode in `timecodeFormat` (HH:MM:SS:FF by
    /// default), or nothing. The window and the saved print both draw it.
    public static func text(
        _ mode: FrameInfo, frame: Int, fps: Double, timecodeFormat: TimecodeFormat = .hoursMinutesSecondsFrames,
        frameFormat: FrameNumberFormat = .frame, frameCount: Int = 0
    ) -> String? {
        switch mode {
        case .frames:
            switch frameFormat {
            case .frame: String(format: "%04d", max(0, frame))
            case .frameOfLast: String(format: "%04d / %04d", max(0, frame), max(0, frameCount - 1))
            }
        case .timecode: Timecode.string(frames: frame, fps: fps, format: timecodeFormat)
        case .hidden: nil
        }
    }

    /// Font size in points for a thumb of this height: MoviePrint scales a
    /// 10 px label by size × 0.1 × (thumbInfoRatio 0.075 × thumb height) / 10.
    public static func fontSize(size: Double, thumbHeight: Double) -> Double {
        size / 10 * 0.075 * thumbHeight
    }

    /// The font size capped by the Max size setting, which is in points per
    /// 1000 points of print width: the window and the saved print (laid out
    /// at the output width) cap at the same fraction of the print.
    public static func fontSize(size: Double, thumbHeight: Double, maxSize: Double, printWidth: Double) -> Double {
        min(fontSize(size: size, thumbHeight: thumbHeight), maxSize * max(0, printWidth) / 1000)
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
