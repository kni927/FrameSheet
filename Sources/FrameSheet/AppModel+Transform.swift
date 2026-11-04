import CoreGraphics
import FrameSheetCore
import Foundation

/// Per-movie rotation, cropping and aspect ratio (§3, §4 movie menu "Edit
/// rotation/cropping/aspect ratio"; MoviePrint 0.2.18–0.2.19). The
/// transform is stored on the movie and changed through `edit`, so it is
/// undoable; `backend(for:)` applies it (`TransformedBackend`), so thumbs,
/// scrub, player stills and strip, face analysis and saved prints and frames
/// all get the same image. Shot and face scans read transformed frames too
/// (`ScanRequest.transform`); a stored scan does not record the transform,
/// so when the rotation or crop changes (also by undo or redo) the movie's
/// stored scans are cleared, as Clear Stored Scans does, and the next scan
/// reads the new frames. Sheets keep their thumbs and scenes; face boxes
/// already on a faces sheet keep the old frame's coordinates until it is
/// scanned again.
extension AppModel {
    /// Movie menu: opens the dialog (not while a scan runs: it reads the
    /// movie with the current transform).
    func editTransform(_ fileId: UUID) {
        guard !isScanning, library.file(fileId) != nil else { return }
        transformDialogFile = fileId
    }

    /// The dialog's Update transform: one undo step.
    func setTransform(_ transform: MovieTransform, of fileId: UUID) {
        guard let file = library.file(fileId) else { return }
        let clamped = transform.clamped(width: file.width, height: file.height)
        guard clamped != file.transform else { return }
        edit { library in
            if let i = library.files.firstIndex(where: { $0.id == fileId }) { library.files[i].transform = clamped }
        }
    }

    /// The movie has stored scans that a rotation or crop change clears.
    func transformClearsScans(_ fileId: UUID) -> Bool { hasStoredScans(fileId) }

    /// A frame of the movie as decoded, without the transform, for the
    /// dialog's preview (about `width` pixels wide).
    func untransformedFrame(of file: MovieFile, frame: Int, width: Int) async -> CGImage? {
        guard let backend = try? await backend(for: file) else { return nil }
        let base = (backend as? TransformedBackend)?.base ?? backend
        return try? await base.frame(frame, maxWidth: width).image
    }

    /// After every change to the library: movies whose rotation or crop
    /// differs from what their images were made with drop their cached
    /// images, player frames and stored scans. An aspect ratio change only
    /// changes the layout.
    func applyTransformChanges() {
        var changed: [UUID] = []
        for file in library.files {
            let old = appliedTransforms[file.id]
            guard old != file.transform else { continue }
            appliedTransforms[file.id] = file.transform
            guard let old else { continue }
            if !Self.sameImage(old, file.transform) { changed.append(file.id) }
        }
        guard !changed.isEmpty else { return }
        cancelScrub()
        forgetImages()
        for file in library.files { loadPoster(file) }
        for id in changed {
            player.transformChanged(id)
            dropStoredScans(id)
        }
    }

    private static func sameImage(_ a: MovieTransform, _ b: MovieTransform) -> Bool {
        a.rotation == b.rotation && a.cropTop == b.cropTop && a.cropBottom == b.cropBottom
            && a.cropLeft == b.cropLeft && a.cropRight == b.cropRight
    }

    /// Clears a movie's stored shot and face scans (as Clear Stored Scans).
    /// A scan of it still running (an undo during a scan) is cancelled, and
    /// what it stores on the way out is cleared once it has ended.
    private func dropStoredScans(_ fileId: UUID) {
        let running = scanJob?.fileId == fileId || faceScanJob?.fileId == fileId ? scanTask : nil
        running?.cancel()
        Task {
            await running?.value
            scanStore?.delete(fileId)
            faceStore?.delete(fileId)
            scanData[fileId] = nil
            stoppedScans.remove(fileId)
            if let state = library.file(fileId)?.scanState, state != ScanState.none {
                update { library in
                    if let i = library.files.firstIndex(where: { $0.id == fileId }) {
                        library.files[i].scanState = .none
                    }
                }
            }
        }
    }
}
