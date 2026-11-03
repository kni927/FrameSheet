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
