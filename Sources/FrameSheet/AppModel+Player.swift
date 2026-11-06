import FrameSheetCore
import Foundation

/// The player view's entry points (§7, §8, §9): key 2, Space, the toolbar
/// button and a double-click on a thumb or scene.
extension AppModel {
    /// Standard view ↔ player view.
    func togglePlayerView() {
        if player.isShown {
            player.hide()
        } else if currentSheet != nil {
            player.show()
        }
    }

    /// A double-click on a thumb or scene: selects it and toggles the
    /// player view (MoviePrint's `onThumbDoubleClick`).
    func doubleClicked(_ thumb: UUID) {
        selectedThumbId = thumb
        togglePlayerView()
    }

    /// Space (§8): in the player on a shot sheet it switches between the
    /// cut/merge and the change-thumb mode; otherwise it toggles the player
    /// view.
    func spacePressed() {
        if player.isShown, currentSheet?.type == .shot {
            player.toggleMode()
        } else {
            togglePlayerView()
        }
    }
}

/// Editing at the player's current frame (§8, §9; MoviePrint's
/// `VideoPlayer.handleKeyPress`, `onChangeOrAddClick` and App.js's
/// `onCutSceneClick` / `onMergeSceneClick`): one undo step each. A frame
/// that does not decode exactly is not stored (decision 25), as the scrub
/// refuses it.
extension AppModel {
    /// Return in the player: cut or merge in cut mode; in thumb mode change
    /// the thumb, with ⇧ / ⌥ (interval sheets) add one before / after.
    func playerReturn(shift: Bool, option: Bool) {
        guard player.isShown, let sheet = currentSheet else { return }
        if sheet.type == .shot, player.mode == .cut {
            cutOrMergeAtPlayerFrame()
        } else {
            playerThumbAction(.forKeys(shift: shift, option: option, sheetType: sheet.type))
        }
    }

    /// CUT or MERGE at the player's frame of a shot sheet.
    var playerCutAction: PlayerCutAction? {
        guard player.isShown, let ref = currentRef, currentSheet?.type == .shot else { return nil }
        return library.playerCutAction(ref, at: player.frame)
    }

    /// MERGE at a cut (the frame is a scene's first frame), else CUT here.
    func cutOrMergeAtPlayerFrame() {
        guard player.isShown, let ref = currentRef, currentSheet?.type == .shot, !isStreamingSheetShown else { return }
        cancelScrub()
        if player.isPlaying { player.pause() }
        let frame = player.frame
        guard library.playerCutAction(ref, at: frame) == .merge else {
            cutAtPlayerFrame()
            return
        }
        if let merged = edit({ $0.mergeScenes(ref, atCut: frame) }) {
            selectedThumbId = merged
            showNotice("Merged at frame \(frame)")
        }
    }

    /// Cuts the scene at the player's frame; the new scene (where the frame
    /// now is) is selected. At an existing cut, MoviePrint's message.
    func cutAtPlayerFrame() {
        guard player.isShown, let ref = currentRef, currentSheet?.type == .shot, !isStreamingSheetShown else { return }
        cancelScrub()
        Task {
            guard let current = await player.exactCurrentFrame(), currentRef == ref else { return }
            let frame = current.frame
            guard current.exact else {
                refuseInexactPlayerFrame(frame, error: current.error)
                return
            }
            switch edit({ $0.cutScene(ref, at: frame) }) {
            case .cut(let id):
                selectedThumbId = id
                showNotice("Cut at frame \(frame)")
            case .alreadyCut:
                toast = "There is already a cut at frame \(frame)."
            case .notFound:
                break
            }
        }
    }

    /// CHANGE / ADD BEFORE / ADD AFTER at the player's frame: shot sheets
    /// change the thumb of the scene at the frame; interval sheets change
    /// the selected thumb or add one next to it (and select it).
    func playerThumbAction(_ action: PlayerThumbAction) {
        guard player.isShown, let ref = currentRef, let sheet = currentSheet, sheet.type != .faces,
              !isStreamingSheetShown
        else { return }
        cancelScrub()
        let selected = selectedThumbId
        if sheet.type == .interval, !sheet.thumbs.contains(where: { $0.id == selected }) {
            showNotice("Select a thumb first.")
            return
        }
        Task {
            guard let current = await player.exactCurrentFrame(), currentRef == ref else { return }
            let frame = current.frame
            guard current.exact else {
                refuseInexactPlayerFrame(frame, error: current.error)
                return
            }
            if let id = edit({ $0.applyPlayerThumbAction(ref, action, at: frame, selected: selected) }) {
                selectedThumbId = id
            }
        }
    }

    private func refuseInexactPlayerFrame(_ frame: Int, error: String?) {
        toast = error.map { "Frame \(frame) could not be decoded, so nothing changed: \($0)." }
            ?? "Frame \(frame) could not be decoded exactly, so nothing changed (\(exactFrameHint))."
    }

    /// S and Save frame: the player's frame at the movie's own size, named
    /// by the single-thumb scheme with the frame decoded, as Save thumb.
    func saveCurrentFrame() {
        guard player.isShown else { return }
        if player.isPlaying { player.pause() }
        let frame = player.frame
        // The movie and sheet S was pressed on, at its source then.
        guard let ref = currentRef else { return }
        let generation = sourceGeneration(ref.fileId)
        Task {
            await player.waitForDecodes()
            guard currentRef == ref, sourceGeneration(ref.fileId) == generation else {
                toast = "The movie or sheet changed before frame \(frame) was saved."
                return
            }
            saveFrame(frame, generation: generation)
        }
    }
}
