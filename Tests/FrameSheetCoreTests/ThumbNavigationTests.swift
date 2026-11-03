import Foundation
import Testing
@testable import FrameSheetCore

private func sheet(_ frames: [Int], hidden: Set<Int> = []) -> Sheet {
    Sheet(
        name: "Sheet-1", type: .interval,
        thumbs: frames.enumerated().map { Thumb(frameNumber: $1, index: $0, hidden: hidden.contains($0)) })
}

@Suite struct ThumbNavigationTests {
    @Test func stepsThroughVisibleThumbs() {
        let s = sheet([0, 10, 20, 30, 40], hidden: [2])
        let ids = s.thumbs.map(\.id)
        #expect(s.visibleThumb(from: ids[1], step: 1) == ids[3])
        #expect(s.visibleThumb(from: ids[3], step: -1) == ids[1])
        #expect(s.visibleThumb(from: ids[4], step: 1) == ids[4])
        #expect(s.visibleThumb(from: ids[0], step: -1) == ids[0])
        #expect(s.visibleThumb(from: nil, step: 1) == ids[0])
        #expect(s.visibleThumb(from: nil, step: -1) == ids[4])
        // From a hidden thumb: nearest visible in that direction.
        #expect(s.visibleThumb(from: ids[2], step: 1) == ids[3])
        #expect(s.visibleThumb(from: ids[2], step: -1) == ids[1])
        #expect(sheet([0], hidden: [0]).visibleThumb(from: nil, step: 1) == nil)
    }

    @Test func selectionAfterHiding() {
        let s = sheet([0, 10, 20, 30], hidden: [1, 2])
        let ids = s.thumbs.map(\.id)
        #expect(s.selectionAfterHiding(ids[0]) == ids[3])
        #expect(s.selectionAfterHiding(ids[3]) == ids[0])
    }

    @Test func affectedThumbs() {
        let s = sheet([0, 10, 20, 30])
        let ids = s.thumbs.map(\.id)
        #expect(Sheet.affectedThumbs(.inPoint, of: ids[2], in: s.thumbs) == [ids[0], ids[1]])
        #expect(Sheet.affectedThumbs(.outPoint, of: ids[2], in: s.thumbs) == [ids[3]])
        #expect(Sheet.affectedThumbs(.hide, of: ids[2], in: s.thumbs) == [ids[2]])
        #expect(Sheet.affectedThumbs(.expand, of: ids[2], in: s.thumbs) == Set(ids).subtracting([ids[2]]))
    }

    @Test func keyboardRange() {
        let mapping = ScrubMapping(
            thumbFrame: 100, leftFrame: 50, rightFrame: 150, frameCount: 1000, liveMinX: 0,
            liveMaxX: 1, containerWidth: 1)
        #expect(mapping.keyboardRange(modifiers: []) == 50...150)
        #expect(mapping.keyboardRange(modifiers: .shift) == 50...100)
        #expect(mapping.keyboardRange(modifiers: .option) == 100...150)
        #expect(mapping.keyboardRange(modifiers: .control) == 0...999)
        var first = mapping
        first.leftFrame = 100
        #expect(first.keyboardRange(modifiers: []) == 0...150)
        var last = mapping
        last.rightFrame = 100
        #expect(last.keyboardRange(modifiers: []) == 50...999)
    }

    @Test func scrubLayoutCentersTheLiveFrame() {
        let layout = ScrubLayout(containerWidth: 1200, containerHeight: 800, aspectRatioInv: 9.0 / 16.0)
        #expect(layout.live.width == 600)
        #expect(abs(layout.live.midX - 600) < 0.001)
        #expect(layout.live.minY >= ScrubLayout.cancelBarHeight + ScrubLayout.labelHeight)
        #expect(layout.left.maxX < layout.live.minX)
        #expect(layout.right.minX > layout.live.maxX)
        #expect(layout.left.minX >= ScrubMapping.sideMargin)
        #expect(layout.right.maxX <= 1200 - ScrubMapping.sideMargin)
        // A short container limits the live frame by height.
        let short = ScrubLayout(containerWidth: 2000, containerHeight: 300, aspectRatioInv: 9.0 / 16.0)
        #expect(short.live.maxY <= 300)
        #expect(short.hint.maxY <= 300)
    }

    /// The smallest window (900 × 560) with both sidebars open leaves the
    /// main area about 340 × 500.
    @Test func scrubLayoutFitsASmallContainer() {
        let width = 340.0
        let height = 500.0
        let layout = ScrubLayout(containerWidth: width, containerHeight: height, aspectRatioInv: 9.0 / 16.0)
        let margin = ScrubMapping.sideMargin
        #expect(layout.left.minX >= margin - 0.001)
        #expect(layout.right.maxX <= width - margin + 0.001)
        #expect(layout.left.width >= layout.live.width * ScrubLayout.minSideRatio - 0.001)
        #expect(layout.right.width == layout.left.width)
        #expect(layout.live.minY >= ScrubLayout.cancelBarHeight + ScrubLayout.labelHeight)
        #expect(layout.hint.maxY <= height)
        // The label line spans the container, not just the narrow live frame.
        #expect(abs(layout.label.width - (width - 2 * margin)) < 1e-9)
        #expect(abs(layout.label.maxY - layout.live.minY) < 0.001)
        #expect(layout.label.width > layout.live.width)
    }
}
