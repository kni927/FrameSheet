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

    /// Pointer room at the window edges for reaching the first and last frame.
    public static let sideMargin = 10.0

    public init(
        thumbFrame: Int, leftFrame: Int, rightFrame: Int, frameCount: Int, liveMinX: Double,
        liveMaxX: Double, containerWidth: Double
    ) {
        self.thumbFrame = thumbFrame
        self.leftFrame = leftFrame
        self.rightFrame = rightFrame
        self.frameCount = frameCount
        self.liveMinX = liveMinX
        self.liveMaxX = liveMaxX
        self.containerWidth = containerWidth
    }

    /// The frame for a pointer position. Over the live frame the pointer maps
    /// linearly between the neighbors (Shift: left neighbor → thumb;
    /// Option: thumb → right neighbor). Left or right of it, the frame
    /// holds at that end, except with Control or on the first/last thumb,
    /// where it maps on to the start or end of the movie.
    public func frame(atX x: Double, modifiers: ScrubModifiers) -> Int {
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
