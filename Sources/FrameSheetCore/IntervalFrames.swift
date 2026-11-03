import Foundation

// Ported from MoviePrint v0.2.23 (MIT, docs/licenses/MoviePrint-LICENSE):
// `mapRange` (app/utils/utils.js) and `getIntervalArray`
// (app/utils/utilsSortAndFilter.js).

public enum IntervalFrames {
    /// JavaScript `Math.round`: halves round towards +infinity.
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    /// Maps `value` from `low1...high1` to `low2...high2`, rounded to three
    /// decimals and clamped to the target range; `returnInt` rounds the
    /// result. Returns 0 when the source range is empty.
    public static func mapRange(
        _ value: Double, _ low1: Double, _ high1: Double, _ low2: Double, _ high2: Double,
        returnInt: Bool = true
    ) -> Double {
        guard high1 - low1 != 0 else { return 0 }
        var v = low2 + (high2 - low2) * ((value - low1) / (high1 - low1))
        v = jsRound(v * 1000 + Double.ulpOfOne) / 1000
        var limited = min(max(v, low2), high2)
        if returnInt { limited = jsRound(limited) }
        return limited
    }

    /// `amount` frame numbers spread evenly from `start` to `stop`, both
    /// included. When the range holds fewer frames than `amount`, the list
    /// is cut to the range with `limitToMaxValue`, or otherwise the range
    /// is widened (and moved back inside the movie) to fit.
    public static func frameNumbers(
        amount: Int, start: Int, stop: Int, maxValue: Int, limitToMaxValue: Bool = false
    ) -> [Int] {
        var newStart = start
        var newStop = stop
        let range = stop - start

        var newAmount = min(amount, maxValue - 1)
        if range < newAmount {
            if limitToMaxValue {
                newAmount = range + 1
            } else {
                newStop = start + newAmount
                if newStop > maxValue - 1 {
                    newStart = max(0, maxValue - 1 - newAmount)
                    newStop = newStart + newAmount
                }
            }
        }
        guard newAmount > 0 else { return [] }

        let startBound = Double(min(max(newStart, 0), maxValue - 1))
        let stopBound = Double(min(max(newStop, 0), maxValue - 1))
        return (0..<newAmount).map {
            Int(mapRange(Double($0), 0, Double(newAmount - 1), startBound, stopBound))
        }
    }
}

public enum SheetNaming {
    public static let prefix = "Sheet-"
    /// MoviePrint's default prefix, renamed to `Sheet-` (owner,
    /// 2026-11-03); libraries saved before are migrated on load.
    public static let moviePrintPrefix = "MoviePrint-"

    /// MoviePrint's `getNewSheetName` with the `Sheet-` prefix:
    /// "Sheet-" + (count + 1).
    public static func newSheetName(sheetCount: Int, prefix: String = SheetNaming.prefix) -> String {
        "\(prefix)\(sheetCount + 1)"
    }

    /// `Sheet-N` for a name that is exactly `MoviePrint-N`; nil otherwise.
    public static func migratedName(_ name: String) -> String? {
        guard name.hasPrefix(moviePrintPrefix) else { return nil }
        let number = name.dropFirst(moviePrintPrefix.count)
        guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit) else { return nil }
        return prefix + number
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

public enum Timecode {
    /// `HH:MM:SS:FF` (MoviePrint `frameCountToTimeCode`), with the movie's
    /// own fps rounded to whole frames per second.
    public static func string(frames: Int, fps: Double, separator: String = ":") -> String {
        let f = max(1, Int(fps.rounded()))
        let total = max(0, frames)
        let ff = total % f
        let seconds = total / f
        let parts = [seconds / 3600, (seconds / 60) % 60, seconds % 60, ff]
        return parts.map { String(format: "%02d", $0) }.joined(separator: separator)
    }

    /// The frame info timecode of a frame in `format`. `HH:MM:SS:FF` is
    /// `string(frames:fps:)`; `HH:MM:SS` and `MM:SS` are it without the
    /// frames (MM counts all minutes, so "75:03" past an hour);
    /// `HH:MM:SS.mmm` is the frame's time at the movie's exact fps, so it
    /// can differ from the frame-count formats at fractional rates (23.976).
    public static func string(frames: Int, fps: Double, format: TimecodeFormat) -> String {
        let f = max(1, Int(fps.rounded()))
        let total = max(0, frames)
        let seconds = total / f
        switch format {
        case .hoursMinutesSecondsFrames:
            return string(frames: frames, fps: fps)
        case .hoursMinutesSeconds:
            return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        case .minutesSeconds:
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        case .hoursMinutesSecondsMilliseconds:
            let rate = fps > 0 ? fps : 25
            let ms = Int((Double(total) / rate * 1000).rounded(.down))
            let s = ms / 1000
            return String(format: "%02d:%02d:%02d.%03d", s / 3600, (s / 60) % 60, s % 60, ms % 1000)
        }
    }

    /// `HH:MM:SS` for a duration in seconds.
    public static func string(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
