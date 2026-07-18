import SwiftUI
import Foundation
import AppKit

// Per-thumbnail grid interactions (Phase 3a). Hidden state is transient:
// regenerating rebuilds the Thumbnail array, so hides reset with it (per
// Decisions — hidden-by-timestamp persistence was explicitly not adopted).
extension AppState {

    // MARK: Keyboard selection + shortcuts (Phase 3a wrap-up)
    //
    // Selection navigates ALL displayed cells in raster order, including
    // dimmed hidden ones (per Decisions — the grid shows hidden cells in
    // place, and skipping them would make keyboard-only unhide impossible).
    // Key capture uses an NSEvent local monitor because the deployment
    // target is macOS 11 (SwiftUI .onKeyPress is macOS 14+). Events are
    // passed through untouched while a text field is being edited or any
    // command/control/option modifier is down.

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleGridKeyEvent(event) ? nil : event
        }
    }

    private func handleGridKeyEvent(_ event: NSEvent) -> Bool {
        guard displayParams != nil, !thumbnails.isEmpty else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }
        // Don't steal keys from the sidebar's text inputs (TextField /
        // TextEditor edit via an NSTextView field editor).
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false
        }

        switch event.keyCode {
        case 123: return moveSelection(by: -1)                       // ←
        case 124: return moveSelection(by: 1)                        // →
        case 126: return moveSelection(by: -(displayParams?.cols ?? columns)) // ↑
        case 125: return moveSelection(by: (displayParams?.cols ?? columns))  // ↓
        case 53:                                                     // Esc
            guard selectedThumbnailID != nil else { return false }
            selectedThumbnailID = nil
            return true
        case 49, 51, 117:                                            // Space, Delete, Fwd-Delete
            guard let id = selectedThumbnailID else { return false }
            toggleHidden(id)
            return true
        default:
            break
        }

        // Nudge keys matched by character rather than key code so they work
        // across keyboard layouts (and synthesized input).
        switch event.charactersIgnoringModifiers {
        case ",":
            guard let id = selectedThumbnailID else { return false }
            nudgeThumbnail(id, forward: false)
            return true
        case ".":
            guard let id = selectedThumbnailID else { return false }
            nudgeThumbnail(id, forward: true)
            return true
        default:
            return false
        }
    }

    // Move selection by a raster-order offset (±1 = left/right, ±cols =
    // up/down), clamped to the grid. An arrow with no selection selects
    // the first cell.
    private func moveSelection(by offset: Int) -> Bool {
        guard let current = selectedThumbnailID,
              let idx = thumbnails.firstIndex(where: { $0.id == current })
        else {
            selectedThumbnailID = thumbnails.first?.id
            return true
        }
        let target = idx + offset
        guard target >= 0 && target < thumbnails.count else { return true }
        selectedThumbnailID = thumbnails[target].id
        return true
    }

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

    // Nudge one thumbnail's source timestamp by ±nudgeStepSeconds and
    // re-extract ONLY that frame with a single ffmpeg invocation — no full
    // regeneration (Phase 3a Stage D). The cell image and the export
    // composite are refreshed from the updated Thumbnail.
    func nudgeThumbnail(_ id: UUID, forward: Bool) {
        guard let idx = thumbnails.firstIndex(where: { $0.id == id }),
              let video = selectedVideo,
              let params = displayParams,
              let framesDir = currentFramesDir,
              !nudgingIDs.contains(id)
        else { return }

        let delta = (forward ? 1.0 : -1.0) * nudgeStepSeconds
        let maxTS = max(0, video.duration - 0.05)
        let newTS = min(maxTS, max(0, thumbnails[idx].timestamp + delta))
        guard abs(newTS - thumbnails[idx].timestamp) > 0.0005 else { return }

        // Same scale width as the batch extraction (even number required)
        let m = ContactSheetRenderer.metrics(for: params)
        let scaleWidth = m.cellW % 2 == 0 ? m.cellW : m.cellW - 1

        let outPath = (framesDir as NSString).appendingPathComponent(
            "nudge_\(id.uuidString.prefix(8))_\(Int(newTS * 1000)).jpg")
        let nfcVideo = video.path.precomposedStringWithCanonicalMapping
        let ff = ffmpegPath
        let runID = generationID

        nudgingIDs.insert(id)
        consoleOutput += ">>> Nudging frame to \(String(format: "%.3f", newTS))s (single re-extract)...\n"

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ff)
            task.arguments = [
                "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.3f", newTS),
                "-i", nfcVideo,
                "-frames:v", "1",
                "-vf", "scale=\(scaleWidth):-2",
                "-q:v", "3",
                "-y", outPath
            ]
            task.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            task.standardError = errPipe
            var launched = false
            do {
                try task.run()
                launched = true
                task.waitUntilExit()
            } catch {}
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let ok = launched && task.terminationStatus == 0
                && FileManager.default.fileExists(atPath: outPath)

            DispatchQueue.main.async {
                self.nudgingIDs.remove(id)
                // A full regeneration superseded this nudge; drop the result.
                guard runID == self.generationID,
                      let curIdx = self.thumbnails.firstIndex(where: { $0.id == id })
                else { return }
                guard ok else {
                    if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
                        self.consoleOutput += "Nudge failed: \(err)"
                    } else {
                        self.consoleOutput += ">>> Nudge failed (no frame extracted).\n"
                    }
                    return
                }
                self.thumbnails[curIdx].timestamp = newTS
                self.thumbnails[curIdx].imagePath = outPath
                if let cell = ContactSheetRenderer.renderCellImage(self.thumbnails[curIdx], params: params) {
                    self.cellImages[id] = cell
                }
                self.recomposeSheet()
            }
        }
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
