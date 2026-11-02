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
    /// MoviePrint's `getNewSheetName`: "MoviePrint-" + (count + 1).
    public static func newSheetName(sheetCount: Int, prefix: String = "MoviePrint-") -> String {
        "\(prefix)\(sheetCount + 1)"
    }
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

    /// `HH:MM:SS` for a duration in seconds.
    public static func string(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
