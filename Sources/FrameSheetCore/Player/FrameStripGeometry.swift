import Foundation

// The player's frame strip and timeline bars (§9). Ported from MoviePrint
// v0.2.23 (MIT, docs/licenses/MoviePrint-LICENSE): `getSliceWidthArrayForCut`,
// `getBucketValueOfPercentage` and `mapRange` (app/utils/utils.js), the slice
// loop of `updateOpencvVideoCanvas` (app/components/VideoPlayer.js), the
// playhead and range math of `Timeline` (app/components/Timeline.js), and the
// constants `VIDEOPLAYER_SLICE_ARRAY_SIZE`, `VIDEOPLAYER_SLICEGAP`,
// `VIDEOPLAYER_CUTGAP`, `VIDEOPLAYER_FIXED_PIXEL_PER_FRAME_RATIO`,
// `VIDEOPLAYER_SCENE_MARGIN`, `TIMELINE_SCENE_MINIMUM_WIDTH` and
// `TIMELINE_PLAYHEAD_MINIMUM_WIDTH` (app/utils/constants.js).

/// The frame strip: vertical slices of consecutive frames around the
/// current one, each the middle part of its frame scaled to the strip's
/// height. The middle slice is about a quarter of the strip (a third for an
/// odd count) and the slices halve outward; 1 pt between slices, 8 pt
/// before a slice whose frame starts a scene (a cut).
public struct FrameStripGeometry: Equatable, Sendable {
    /// Slices in cut mode; one fewer in thumb mode (MoviePrint's grid view).
    public static let sliceCount = 20
    public static let sliceGap = 1.0
    public static let cutGap = 8.0

    public static func sliceCount(for mode: PlayerMode) -> Int {
        mode == .cut ? sliceCount : sliceCount - 1
    }

    public struct Slice: Equatable, Sendable {
        public var frame: Int
        /// Left edge in the strip.
        public var x: Double
        public var width: Double
        /// Left edge of the part shown, in the frame scaled to the strip's
        /// height (the slice shows the frame's middle).
        public var cropX: Double
        /// The frame lies inside the movie (slices before frame 0 or past
        /// the last frame stay empty).
        public var inMovie: Bool
    }

    public let slices: [Slice]
    /// Index of the current frame's slice.
    public let currentIndex: Int

    /// MoviePrint's `getSliceWidthArrayForCut`: the middle width is a
    /// quarter (a third for an odd count) of the strip less its gaps, and
    /// each step outward halves it, whole points, at least 1 and at most the
    /// frame's width at the strip's height. An even count has two middle
    /// slices; an odd count one, with one more slice to the right.
    public static func sliceWidths(stripWidth: Double, frameWidth: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let odd = count % 2 == 1
        let half = count / 2
        let usable = stripWidth - cutGap - sliceGap * Double(count)
        let middle = (usable / (odd ? 3 : 4)).rounded(.down)
        let maxWidth = max(1, frameWidth)
        return (0..<count).map { i in
            let factor = odd
                ? (i < half ? half - (i + 1) : i + 1 - half)
                : (i < half ? half - (i + 1) : i - half)
            let width = (middle / pow(2, Double(factor))).rounded(.down)
            return min(max(width, 1), maxWidth)
        }
    }

    /// The first frame of the strip for `count` slices around `frame`: the
    /// current frame is the right one of the two middle slices for an even
    /// count, the middle slice for an odd count.
    public static func firstFrame(around frame: Int, count: Int) -> Int {
        frame - count / 2 + (count % 2 == 1 ? 1 : 0)
    }

    /// `cuts` are the scenes' first frames; a gap of `cutGap` goes before
    /// each slice whose frame is one.
    public init(
        stripWidth: Double, frameWidth: Double, count: Int, currentFrame: Int, frameCount: Int, cuts: Set<Int>
    ) {
        let widths = Self.sliceWidths(stripWidth: stripWidth, frameWidth: frameWidth, count: count)
        let first = Self.firstFrame(around: currentFrame, count: count)
        var x = 0.0
        var slices: [Slice] = []
        slices.reserveCapacity(widths.count)
        for (i, width) in widths.enumerated() {
            let frame = first + i
            let cropX = max((frameWidth / 2).rounded(.down) - (width / 2).rounded(.down), 0)
            slices.append(Slice(
                frame: frame, x: x, width: width, cropX: cropX, inMovie: frame >= 0 && frame < frameCount))
            x += width + (cuts.contains(frame + 1) ? Self.cutGap : Self.sliceGap)
        }
        self.slices = slices
        currentIndex = currentFrame - first
    }

    /// The frames inside the movie the strip shows, in order.
    public var frames: [Int] { slices.filter(\.inMovie).map(\.frame) }
}

/// The player's two timeline bars (MoviePrint's `Timeline`): the movie bar
/// over all frames, with the sheet's range (lowest to highest frame, the
/// IN–OUT of its thumbs or scenes), the current scene's range and the
/// playhead; and the scene bar over the current scene's frames, one bucket
/// per frame. Clicking or dragging either bar moves the playhead.
public struct PlayerTimelineGeometry: Equatable, Sendable {
    /// Narrowest drawn range and playhead.
    public static let minimumRangeWidth = 2.0
    public static let minimumPlayheadWidth = 2.0

    public var width: Double
    public var frameCount: Int
    /// The current scene's first and last frame.
    public var sceneIn: Int
    public var sceneOut: Int

    public init(width: Double, frameCount: Int, sceneIn: Int, sceneOut: Int) {
        self.width = max(0, width)
        self.frameCount = max(1, frameCount)
        self.sceneIn = sceneIn
        self.sceneOut = max(sceneIn, sceneOut)
    }

    /// Width of one frame on the movie bar (the playhead).
    public var frameWidth: Double { max(width / Double(frameCount), Self.minimumPlayheadWidth) }

    /// MoviePrint's `mapRange` without its rounding to three decimals.
    static func fraction(_ value: Double, from low: Double, to high: Double) -> Double {
        guard high - low != 0 else { return 0 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    /// Left edge of the playhead on the movie bar.
    public func playheadX(frame: Int) -> Double {
        Self.fraction(Double(frame), from: 0, to: Double(frameCount - 1)) * (width - frameWidth)
    }

    /// The frame under `x` on the movie bar (rounded, inside the movie).
    public func frame(atX x: Double) -> Int {
        let fraction = Self.fraction(x, from: 0, to: width - frameWidth)
        return Int((fraction * Double(frameCount - 1)).rounded())
    }

    /// Left edge and width of a frame range on the movie bar (the sheet's
    /// range and the current scene's), at least `minimumRangeWidth` wide.
    public func range(from low: Int, to high: Int) -> (x: Double, width: Double) {
        let perFrame = width / Double(frameCount)
        let x = perFrame * Double(low)
        return (x, max(perFrame * Double(high) - x, Self.minimumRangeWidth))
    }

    /// Frames of the current scene.
    public var sceneLength: Int { sceneOut - sceneIn + 1 }

    /// Width of one frame on the scene bar.
    public var sceneFrameWidth: Double {
        max((width / Double(sceneLength)).rounded(.down), Self.minimumPlayheadWidth)
    }

    /// Left edge of the playhead on the scene bar.
    public func scenePlayheadX(frame: Int) -> Double {
        let fraction = Self.fraction(Double(frame), from: Double(sceneIn), to: Double(sceneOut))
        return (fraction * (width - sceneFrameWidth)).rounded(.down)
    }

    /// The frame under `x` on the scene bar: the position snapped down to
    /// a frame's bucket (`getBucketValueOfPercentage`), inside the scene.
    public func sceneFrame(atX x: Double) -> Int {
        guard sceneLength > 1 else { return sceneIn }
        let fraction = Self.fraction(x, from: 0, to: width - sceneFrameWidth)
        let bucket = 1 / Double(sceneLength - 1)
        // A small slack so the right end lands on the last bucket.
        let snapped = ((fraction + 1e-9) / bucket).rounded(.down) * bucket
        return min(sceneOut, sceneIn + Int((snapped * Double(sceneLength - 1)).rounded()))
    }
}

/// The scene bars under the video in cut mode: a fixed 0.3 pt per frame,
/// at least the minimum scene length, 4 pt margins, the selected scene at
/// full aspect width (MoviePrint's `SceneGrid` in the player).
public enum PlayerSceneBars {
    public static let pointsPerFrame = 0.3
    public static let margin = 4.0

    /// Width of each scene's bar; `selected` is drawn `fullWidth` wide.
    public static func widths(
        scenes: [Scene], minSceneLength: Int, selected: UUID?, fullWidth: Double
    ) -> [Double] {
        scenes.map { scene in
            if scene.id == selected { return max(1, fullWidth.rounded(.down)) }
            let width = max(pointsPerFrame * Double(scene.length), pointsPerFrame * Double(max(0, minSceneLength)))
            return max(1, width.rounded(.down))
        }
    }
}
