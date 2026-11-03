import CoreGraphics
import Foundation

// Small pure helpers behind the grid interactions (§7, §8): which thumb to
// select next, which thumbs a hover button affects, the keyboard scrub
// range and the scrub overlay layout.

/// A hover-overlay button that affects other thumbs (they are dimmed while
/// the pointer is over it).
public enum HoverButton: Sendable, Equatable {
    case expand, hide, inPoint, outPoint, insertBefore, insertAfter
}

extension Sheet {
    /// The visible thumb `step` places from `thumb` (⇧⌥←/→, and the
    /// thumb selected after hiding one). Without a thumb, the first (or
    /// last) visible one; when `thumb` is hidden, the nearest visible one in
    /// that direction. Clamps at the ends; nil without visible thumbs.
    public func visibleThumb(from thumb: UUID?, step: Int) -> UUID? {
        let visible = visibleThumbs
        guard !visible.isEmpty else { return nil }
        guard let thumb, let full = thumbs.firstIndex(where: { $0.id == thumb }) else {
            return step < 0 ? visible.last?.id : visible.first?.id
        }
        if let i = visible.firstIndex(where: { $0.id == thumb }) {
            return visible[min(max(0, i + step), visible.count - 1)].id
        }
        // Hidden: the nearest visible thumb in that direction, else the
        // nearest on the other side.
        let after = thumbs[(full + 1)...].first { !$0.hidden }?.id
        let before = thumbs[..<full].last { !$0.hidden }?.id
        return step < 0 ? (before ?? after) : (after ?? before)
    }

    /// The thumb to select after hiding `thumb`: the next visible one, or the
    /// previous when it was the last.
    public func selectionAfterHiding(_ thumb: UUID) -> UUID? {
        guard let full = thumbs.firstIndex(where: { $0.id == thumb }) else { return nil }
        return thumbs[(full + 1)...].first { !$0.hidden }?.id
            ?? thumbs[..<full].last { !$0.hidden }?.id
    }

    /// Ids among `shown` (the thumbs on screen, in order) that a hover
    /// button over `thumb` affects: IN the thumbs before, OUT those after,
    /// Hide the thumb itself.
    public static func affectedThumbs(_ button: HoverButton, of thumb: UUID, in shown: [Thumb]) -> Set<UUID> {
        guard let i = shown.firstIndex(where: { $0.id == thumb }) else { return [] }
        switch button {
        case .inPoint: return Set(shown[..<i].map(\.id))
        case .outPoint: return Set(shown[(i + 1)...].map(\.id))
        case .hide: return [thumb]
        // MoviePrint dims every other thumb (`getInvertedThumbs`).
        case .expand: return Set(shown.map(\.id)).subtracting([thumb])
        case .insertBefore, .insertAfter: return []
        }
    }
}

extension ScrubMapping {
    /// Frames the keyboard scrub can step through: the same span the pointer
    /// covers (Shift: left neighbour → thumb, Option: thumb → right
    /// neighbour), extended to the movie start or end on the first or last
    /// thumb or with Control.
    public func keyboardRange(modifiers: ScrubModifiers) -> ClosedRange<Int> {
        var low = modifiers.contains(.option) ? thumbFrame : leftFrame
        var high = modifiers.contains(.shift) ? thumbFrame : rightFrame
        if modifiers.contains(.control) || thumbFrame == leftFrame { low = 0 }
        if modifiers.contains(.control) || thumbFrame == rightFrame { high = max(0, frameCount - 1) }
        return min(low, high)...max(low, high)
    }
}

/// Placement of the scrub overlay: a Cancel bar at the top, the live frame
/// centred below it with its label above and the hint below, and the two
/// neighbour images on either side. In a small container everything scales
/// down together, so the neighbours keep at least `minSideRatio` of the live
/// width, and the label and hint span the container's width rather than the
/// live frame's.
public struct ScrubLayout: Equatable, Sendable {
    public static let cancelBarHeight = 44.0
    /// Room above the live frame for the CHANGE TO / ADD … label.
    public static let labelHeight = 40.0
    /// Room below the live frame for the hint line.
    public static let hintHeight = 20.0
    public static let gap = 12.0
    /// Neighbours are 0.6 of the live width when there is room, never less
    /// than 0.4.
    public static let sideRatio = 0.6
    public static let minSideRatio = 0.4

    public let live: CGRect
    public let left: CGRect
    public let right: CGRect
    /// The action label and frame / timecode line above the live frame.
    public let label: CGRect
    /// The hint line below the live frame.
    public let hint: CGRect

    /// `aspectRatioInv` is the movie's height / width.
    public init(containerWidth: Double, containerHeight: Double, aspectRatioInv: Double) {
        let ratio = aspectRatioInv > 0 ? aspectRatioInv : 9.0 / 16.0
        let margin = ScrubMapping.sideMargin
        let top = Self.cancelBarHeight + Self.labelHeight
        let usableHeight = max(1, containerHeight - top - Self.hintHeight - Self.gap * 2)
        // Width left for the live frame once both neighbours get their
        // minimum share.
        let byWidth = (containerWidth - 2 * (margin + Self.gap)) / (1 + 2 * Self.minSideRatio)
        let liveWidth = max(1, min(containerWidth * 0.5, byWidth, usableHeight / ratio))
        let liveHeight = liveWidth * ratio
        let liveX = (containerWidth - liveWidth) / 2
        let liveY = top + max(0, (usableHeight - liveHeight) / 2)
        let sideWidth = max(0, min(liveWidth * Self.sideRatio, liveX - margin - Self.gap))
        let sideHeight = sideWidth * ratio
        let sideY = liveY + (liveHeight - sideHeight) / 2
        let textWidth = max(1, containerWidth - 2 * margin)
        live = CGRect(x: liveX, y: liveY, width: liveWidth, height: liveHeight)
        left = CGRect(x: liveX - Self.gap - sideWidth, y: sideY, width: sideWidth, height: sideHeight)
        right = CGRect(x: live.maxX + Self.gap, y: sideY, width: sideWidth, height: sideHeight)
        label = CGRect(x: margin, y: liveY - Self.labelHeight, width: textWidth, height: Self.labelHeight)
        hint = CGRect(x: margin, y: live.maxY, width: textWidth, height: Self.hintHeight)
    }
}
