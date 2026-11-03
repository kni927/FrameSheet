import Foundation

// Stepping and jumps in the player view (§8, §9). Ported from MoviePrint
// v0.2.23 (MIT, docs/licenses/MoviePrint-LICENSE): `updatePositionWithStep`,
// `onNextSceneClickWithStop`, `onNextThumbClickWithStop` and
// `updatePositionFromFrame` (app/components/VideoPlayer.js),
// `getSceneFromFrameNumber`, `limitRange` and `CHANGE_THUMB_STEP`
// (app/utils/utils.js, app/utils/constants.js). Difference: the previous and
// next thumb of an interval or faces sheet stop at the first and last thumb,
// as ⇧⌥←/→ does in the standard view (MoviePrint wraps around).

/// What the player edits on a shot sheet: cuts and merges with the scenes
/// as bars below the video (MoviePrint's timeline view in the player), or
/// the thumbs (its grid view, "thumb mode"). Space switches them on shot
/// sheets; other sheets are always in thumb mode.
public enum PlayerMode: Sendable, Equatable {
    case cut
    case thumb

    /// The other mode (Space on a shot sheet).
    public var toggled: PlayerMode { self == .cut ? .thumb : .cut }
}

public enum PlayerNavigation {
    /// ⇧, plain and ⌥ arrow steps (`CHANGE_THUMB_STEP`).
    public static let smallStep = 1
    public static let mediumStep = 10
    public static let largeStep = 100

    /// The arrow step for the modifiers: ⇧ ±1, none ±10, ⌥ ±100 (⇧⌥ jumps
    /// instead, see `cutJump` and `thumbJump`).
    public static func arrowStep(shift: Bool, option: Bool) -> Int {
        if option { return largeStep }
        return shift ? smallStep : mediumStep
    }

    /// `frame + delta`, kept inside the movie (`updatePositionWithStep`).
    public static func step(_ frame: Int, by delta: Int, frameCount: Int) -> Int {
        clamp(frame + delta, frameCount: frameCount)
    }

    /// A frame kept inside the movie; 0 for an empty movie.
    public static func clamp(_ frame: Int, frameCount: Int) -> Int {
        min(max(0, frame), max(0, frameCount - 1))
    }

    /// MoviePrint's `getSceneFromFrameNumber`: the scene that holds `frame`,
    /// or, for a frame outside every scene, the scene at the nearest end of
    /// the scenes' span. Nil without scenes.
    public static func scene(containing frame: Int, in scenes: [Scene]) -> Scene? {
        if let scene = scenes.first(where: { $0.start <= frame && frame < $0.start + $0.length }) {
            return scene
        }
        guard let first = scenes.min(by: { $0.start < $1.start }),
              let last = scenes.max(by: { $0.start + $0.length < $1.start + $1.length })
        else { return nil }
        let clamped = min(last.start + last.length - 1, max(first.start, frame))
        return scenes.first { $0.start <= clamped && clamped < $0.start + $0.length }
    }

    /// Where ⇧⌥← / ⇧⌥→ (previous / next cut) go in cut mode
    /// (`onNextSceneClickWithStop`): back from inside a scene to its first
    /// frame, back from a scene's first frame to the previous scene's first
    /// frame, forward to the next scene's first frame; kept inside the
    /// movie. `scene` is the scene to select when the jump lands in another
    /// scene, nil when it stays in the current one. Nil without scenes.
    public static func cutJump(
        _ direction: SceneNeighbor, from frame: Int, scenes: [Scene], frameCount: Int
    ) -> (frame: Int, scene: UUID?)? {
        guard let current = scene(containing: frame, in: scenes) else { return nil }
        switch direction {
        case .previous:
            if frame != current.start { return (clamp(current.start, frameCount: frameCount), nil) }
            guard let previous = scene(containing: current.start - 1, in: scenes) else { return nil }
            return (clamp(previous.start, frameCount: frameCount), previous.id)
        case .next:
            let target = current.start + current.length
            let next = scene(containing: target, in: scenes)
            return (clamp(target, frameCount: frameCount), next?.id)
        }
    }

    /// Where ⇧⌥← / ⇧⌥→ (previous / next thumb) go in thumb mode
    /// (`onNextThumbClickWithStop`). On a shot sheet the scene before or
    /// after the one at `frame` (from `scenes`) and its thumb's frame; on
    /// other sheets the thumb before or after `selected` among `thumbs` (the
    /// thumbs shown, in order), stopping at the ends; without a selection
    /// the first (next) or last (previous) thumb. Returns the thumb to
    /// select and its frame, kept inside the movie.
    public static func thumbJump(
        _ direction: SceneNeighbor, from frame: Int, selected: UUID?, sheetType: SheetType,
        thumbs: [Thumb], scenes: [Scene], frameCount: Int
    ) -> (frame: Int, thumb: UUID)? {
        if sheetType == .shot {
            guard let current = scene(containing: frame, in: scenes) else { return nil }
            let target = direction == .previous ? current.start - 1 : current.start + current.length
            guard let scene = scene(containing: target, in: scenes),
                  let thumb = thumbs.first(where: { $0.id == scene.id })
            else { return nil }
            return (clamp(thumb.frameNumber, frameCount: frameCount), thumb.id)
        }
        guard !thumbs.isEmpty else { return nil }
        let index: Int
        if let selected, let i = thumbs.firstIndex(where: { $0.id == selected }) {
            index = direction == .previous ? max(0, i - 1) : min(thumbs.count - 1, i + 1)
        } else {
            index = direction == .previous ? thumbs.count - 1 : 0
        }
        let thumb = thumbs[index]
        return (clamp(thumb.frameNumber, frameCount: frameCount), thumb.id)
    }

    /// The scene or thumb the selection follows while the frame moves
    /// (`updatePositionFromFrame` selects the scene at the frame): the id of
    /// the scene holding `frame`, which on a shot sheet is the scene and its
    /// thumb, and on an interval sheet the thumb whose artificial scene it is.
    public static func selection(at frame: Int, scenes: [Scene]) -> UUID? {
        scene(containing: frame, in: scenes)?.id
    }

    /// The scenes the player works with: a shot sheet's scenes, hidden ones
    /// included (cuts are cuts, as MoviePrint's `allScenes`); an interval
    /// sheet's artificial scenes between the thumbs shown; none for faces.
    public static func scenes(of sheet: Sheet, includeHidden: Bool) -> [Scene] {
        switch sheet.type {
        case .shot: SceneList.timelineScenes(of: sheet, includeHidden: true)
        case .interval: SceneList.timelineScenes(of: sheet, includeHidden: includeHidden)
        case .faces: []
        }
    }

    /// The frame AVPlayer shows at `seconds` (its item time): the frame
    /// whose display interval holds it, from the video's first presentation
    /// time `startTime`, kept inside the movie. A thousandth of a frame of
    /// slack keeps a time on a frame's start from landing on the frame
    /// before through rounding.
    public static func frame(atSeconds seconds: Double, startTime: Double, fps: Double, frameCount: Int) -> Int {
        let rate = fps > 0 ? fps : 25
        let position = (seconds - startTime) * rate
        guard position.isFinite else { return 0 }
        return clamp(Int((position + 1e-3).rounded(.down)), frameCount: frameCount)
    }
}
