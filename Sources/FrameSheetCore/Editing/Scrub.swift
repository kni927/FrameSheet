import Foundation

// Scrub mapping (§7), ported from MoviePrint v0.2.23 `getScrubFrameNumber`
// (app/utils/utils.js, MIT, docs/licenses/MoviePrint-LICENSE).

public struct ScrubModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// From the left neighbor to the current thumb; insert before.
    public static let shift = ScrubModifiers(rawValue: 1 << 0)
    /// From the current thumb to the right neighbor; insert after.
    public static let option = ScrubModifiers(rawValue: 1 << 1)
    /// Left or right of the live frame: extend to movie start or end.
    public static let control = ScrubModifiers(rawValue: 1 << 2)
}

public enum ScrubAction: Sendable, Equatable {
    case change, addBefore, addAfter

    public init(_ modifiers: ScrubModifiers) {
        if modifiers.contains(.shift) {
            self = .addBefore
        } else if modifiers.contains(.option) {
            self = .addAfter
        } else {
            self = .change
        }
    }

    /// Label over the live frame.
    public var label: String {
        switch self {
        case .change: "CHANGE TO"
        case .addBefore: "ADD BEFORE"
        case .addAfter: "ADD AFTER"
        }
    }
}

public struct ScrubMapping: Sendable {
    /// Frames of the scrubbed thumb and its visible neighbors (a thumb at
    /// either end is its own neighbor there).
    public var thumbFrame: Int
    public var leftFrame: Int
    public var rightFrame: Int
    public var frameCount: Int
    /// Horizontal extent of the live frame and the overlay, in points.
    public var liveMinX: Double
    public var liveMaxX: Double
    public var containerWidth: Double
    /// Where the pointer pressed the scrub handle. With it, the scrub starts
    /// at the thumb's own frame wherever the handle lies (see
    /// `frame(atX:modifiers:)`); without it, the pointer maps absolutely
    /// over the live frame as in MoviePrint.
    public var pressX: Double?

    /// Pointer room at the window edges for reaching the first and last frame.
    public static let sideMargin = 10.0

    public init(
        thumbFrame: Int, leftFrame: Int, rightFrame: Int, frameCount: Int, liveMinX: Double,
        liveMaxX: Double, containerWidth: Double, pressX: Double? = nil
    ) {
        self.thumbFrame = thumbFrame
        self.leftFrame = leftFrame
        self.rightFrame = rightFrame
        self.frameCount = frameCount
        self.liveMinX = liveMinX
        self.liveMaxX = liveMaxX
        self.containerWidth = containerWidth
        self.pressX = pressX
    }

    /// The frame for a pointer position. Over the live frame the pointer maps
    /// linearly between the neighbors (Shift: left neighbor → thumb;
    /// Option: thumb → right neighbor). Left or right of it, the frame
    /// holds at that end, except with Control or on the first/last thumb,
    /// where it maps on to the start or end of the movie.
    ///
    /// With `pressX`, the map is relative to the press instead: piecewise
    /// linear through the thumb's frame at `pressX`, reaching the bound on
    /// each side (the neighbor, or with Control or on the first/last thumb
    /// the movie start or end) at the same pointer distance the absolute
    /// map takes from the thumb's position on the live frame to that bound.
    /// When the window edge (less `sideMargin`) is nearer than that, the
    /// side is compressed to reach its bound there. Pressed at the thumb's
    /// position on the live frame, it is the absolute map.
    public func frame(atX x: Double, modifiers: ScrubModifiers) -> Int {
        guard let pressX else { return absoluteFrame(atX: x, modifiers: modifiers) }
        let low = Double(modifiers.contains(.option) ? thumbFrame : leftFrame)
        let high = Double(modifiers.contains(.shift) ? thumbFrame : rightFrame)
        let thumb = Double(thumbFrame)
        let span = high - low
        let liveWidth = max(0, liveMaxX - liveMinX)
        // The absolute map's distances: thumb → bound over the live frame,
        // bound → movie start or end beside it.
        let toLow = span > 0 ? (thumb - low) / span * liveWidth : 0
        let toHigh = span > 0 ? (high - thumb) / span * liveWidth : 0
        let extendLow = modifiers.contains(.control) || thumbFrame == leftFrame
        let extendHigh = modifiers.contains(.control) || thumbFrame == rightFrame
        let value: Double
        if x == pressX {
            value = thumb
        } else if x < pressX {
            let outer = extendLow ? max(0, liveMinX - Self.sideMargin) : 0
            let scale = Self.fit(toLow + outer, room: pressX - Self.sideMargin)
            let lowX = pressX - toLow * scale
            let startX = lowX - outer * scale
            if x >= lowX {
                value = IntervalFrames.mapRange(x, lowX, pressX, low, thumb)
            } else if extendLow, x > startX {
                value = IntervalFrames.mapRange(x, startX, lowX, 0, low)
            } else {
                value = extendLow ? 0 : low
            }
        } else {
            let last = Double(max(0, frameCount - 1))
            let outer = extendHigh ? max(0, containerWidth - Self.sideMargin - liveMaxX) : 0
            let scale = Self.fit(toHigh + outer, room: containerWidth - Self.sideMargin - pressX)
            let highX = pressX + toHigh * scale
            let endX = highX + outer * scale
            if x <= highX {
                value = IntervalFrames.mapRange(x, pressX, highX, thumb, high)
            } else if extendHigh, x < endX {
                value = IntervalFrames.mapRange(x, highX, endX, high, last)
            } else {
                value = extendHigh ? last : high
            }
        }
        return Int(value)
    }

    /// Scale that fits `distance` into `room` (1 when it fits already).
    private static func fit(_ distance: Double, room: Double) -> Double {
        guard distance > 0 else { return 1 }
        return min(1, max(0, room) / distance)
    }

    /// MoviePrint's map, absolute over the live frame.
    private func absoluteFrame(atX x: Double, modifiers: ScrubModifiers) -> Int {
        let low = Double(modifiers.contains(.option) ? thumbFrame : leftFrame)
        let high = Double(modifiers.contains(.shift) ? thumbFrame : rightFrame)
        let isFirst = thumbFrame == leftFrame
        let isLast = thumbFrame == rightFrame
        let value: Double
        if x < liveMinX {
            value = modifiers.contains(.control) || isFirst
                ? IntervalFrames.mapRange(x, Self.sideMargin, liveMinX, 0, low) : low
        } else if x > liveMaxX {
            value = modifiers.contains(.control) || isLast
                ? IntervalFrames.mapRange(
                    x, liveMaxX, containerWidth - Self.sideMargin, high, Double(max(0, frameCount - 1)))
                : high
        } else {
            value = IntervalFrames.mapRange(x, liveMinX, liveMaxX, low, high)
        }
        return Int(value)
    }
}

extension Library {
    /// Confirms a scrub: change the thumb, or insert a new one before or
    /// after it. Returns the id of the thumb that holds the frame.
    @discardableResult
    public mutating func applyScrub(_ ref: SheetRef, thumb: UUID, frame: Int, action: ScrubAction) -> UUID? {
        switch action {
        case .change:
            changeThumb(ref, thumb: thumb, to: frame)
            return thumb
        case .addBefore:
            return insertThumb(ref, relativeTo: thumb, .before, frame: frame)
        case .addAfter:
            return insertThumb(ref, relativeTo: thumb, .after, frame: frame)
        }
    }
}
