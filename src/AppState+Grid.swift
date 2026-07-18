import SwiftUI
import Foundation
import AppKit

// Per-thumbnail grid interactions (Phase 3a). Hidden state is transient:
// regenerating rebuilds the Thumbnail array, so hides reset with it (per
// Decisions — hidden-by-timestamp persistence was explicitly not adopted).
extension AppState {

    var hiddenCount: Int { thumbnails.filter { $0.hidden }.count }

    var visibleThumbnails: [Thumbnail] { thumbnails.filter { !$0.hidden } }

    func toggleHidden(_ id: UUID) {
        guard let idx = thumbnails.firstIndex(where: { $0.id == id }) else { return }
        thumbnails[idx].hidden.toggle()
        recomposeSheet()
    }

    func resetHidden() {
        guard hiddenCount > 0 else { return }
        for i in thumbnails.indices { thumbnails[i].hidden = false }
        recomposeSheet()
    }

    // Rebuild the export composite (previewImage / previewImagePath) from
    // the current thumbnails array — visible cells only, compacted in
    // raster order with the row count re-flowed (see reflowParams). Pure
    // compositing, no ffmpeg; used after hide/unhide (and later reorder).
    func recomposeSheet() {
        guard let baseParams = displayParams else { return }
        let visible = visibleThumbnails
        let params = ContactSheetRenderer.reflowParams(baseParams, visibleCount: visible.count)
        let runID = generationID

        DispatchQueue.global(qos: .userInitiated).async {
            let image = ContactSheetRenderer.render(thumbnails: visible, params: params)
            DispatchQueue.main.async {
                guard runID == self.generationID else { return }
                guard let img = image else {
                    self.consoleOutput += ">>> Sheet recomposition failed.\n"
                    return
                }
                let outPath = (NSTemporaryDirectory() as NSString)
                    .appendingPathComponent("framesheet_\(Int(Date().timeIntervalSince1970)).png")
                if let tiff = img.tiffRepresentation,
                   let rep  = NSBitmapImageRep(data: tiff),
                   let png  = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: outPath))
                    self.previewImagePath = outPath
                }
                self.previewImage = img
            }
        }
    }
}
