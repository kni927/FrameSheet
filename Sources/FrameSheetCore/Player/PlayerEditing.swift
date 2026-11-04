import Foundation

// Editing at the player's current frame (§8, §9). Ported from MoviePrint
// v0.2.23 (MIT, docs/licenses/MoviePrint-LICENSE): `handleKeyPress` (Return),
// `onChangeThumbClick` and `onChangeOrAddClick` (app/components/VideoPlayer.js),
// `onCutSceneClick` and `onMergeSceneClick` (app/containers/App.js), with
// `getSceneFromFrameNumber` and `getAdjacentSceneIndicesFromCut`
// (app/utils/utils.js). Undo and selection are the app's (one `edit` each).

/// What the player's Return and CUT / MERGE button do at a frame of a shot
/// sheet in cut mode: merge where a scene after the first starts there
/// (MoviePrint's `thisFrameIsACut`), cut everywhere else.
public enum PlayerCutAction: Sendable, Equatable {
    case cut, merge
}

/// What the player's Return, ⇧Return and ⌥Return do in thumb mode
/// (MoviePrint's `onChangeOrAddClick`; shot sheets only change).
public enum PlayerThumbAction: Sendable, Equatable {
    case change
    case add(InsertPosition)

    /// ⌥ adds after, ⇧ before, neither changes; shot sheets always change.
    public static func forKeys(shift: Bool, option: Bool, sheetType: SheetType) -> PlayerThumbAction {
        guard sheetType == .interval else { return .change }
        if option { return .add(.after) }
        return shift ? .add(.before) : .change
    }
}

extension Library {
    /// Cut or merge at `frame` of a shot sheet (all scenes, hidden ones too,
    /// as MoviePrint's `allScenes`).
    public func playerCutAction(_ ref: SheetRef, at frame: Int) -> PlayerCutAction {
        guard let scenes = sheet(ref.sheetId, of: ref.fileId)?.scenes else { return .cut }
        return scenes.dropFirst().contains { $0.start == frame } ? .merge : .cut
    }

    /// MoviePrint's `onCutSceneClick`: cuts the scene holding `frame` there;
    /// at a scene's first frame there is a cut already.
    public mutating func cutScene(_ ref: SheetRef, at frame: Int) -> SceneCutResult {
        guard let sheet = sheet(ref.sheetId, of: ref.fileId), sheet.type == .shot,
              let scene = sheet.scenes.first(where: { $0.start <= frame && frame < $0.start + $0.length })
        else { return .notFound }
        guard frame > scene.start else { return .alreadyCut }
        return cutScene(ref, scene: scene.id, at: frame).map(SceneCutResult.cut) ?? .notFound
    }

    /// MoviePrint's `onMergeSceneClick`: merges the scene starting at `frame`
    /// with the one before it. Returns the merged scene's id (the earlier
    /// one's, which MoviePrint selects), or nil when no cut lies there.
    @discardableResult
    public mutating func mergeScenes(_ ref: SheetRef, atCut frame: Int) -> UUID? {
        guard let pair = adjacentSceneIndices(ref, cut: frame),
              let id = sheet(ref.sheetId, of: ref.fileId)?.scenes[pair.0].id,
              mergeScenes(ref, cut: frame)
        else { return nil }
        return id
    }

    /// MoviePrint's `onChangeThumbClick` on a shot sheet: the thumb of the
    /// scene holding `frame` moves to it (so it stays inside its scene, as
    /// the scene-limited scrub). Returns the thumb's id.
    @discardableResult
    public mutating func changeSceneThumb(_ ref: SheetRef, at frame: Int) -> UUID? {
        guard let sheet = sheet(ref.sheetId, of: ref.fileId), sheet.type == .shot,
              let scene = sheet.scenes.first(where: { $0.start <= frame && frame < $0.start + $0.length }),
              sheet.thumbs.contains(where: { $0.id == scene.id })
        else { return nil }
        changeThumb(ref, thumb: scene.id, to: frame)
        return scene.id
    }

    /// Thumb mode at `frame`: on a shot sheet the scene's thumb changes; on
    /// an interval sheet `selected` changes to the frame, or a thumb at the
    /// frame goes before or after it (MoviePrint's `onChangeOrAddClick`, which
    /// needs a selected thumb). Returns the thumb changed or added.
    @discardableResult
    public mutating func applyPlayerThumbAction(
        _ ref: SheetRef, _ action: PlayerThumbAction, at frame: Int, selected: UUID?
    ) -> UUID? {
        guard let sheet = sheet(ref.sheetId, of: ref.fileId) else { return nil }
        switch sheet.type {
        case .shot:
            return changeSceneThumb(ref, at: frame)
        case .interval:
            guard let selected, sheet.thumbs.contains(where: { $0.id == selected }) else { return nil }
            switch action {
            case .change:
                changeThumb(ref, thumb: selected, to: frame)
                return selected
            case .add(let position):
                return insertThumb(ref, relativeTo: selected, position, frame: frame)
            }
        case .faces:
            return nil
        }
    }
}
