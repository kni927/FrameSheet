import FrameSheetCore
import Foundation

/// A face scan in progress (§10): the movie, the scope and the progress for
/// the toast.
struct FaceScanJob: Equatable {
    var fileId: UUID
    var fileName: String
    var scope: FaceScanScope
    var fraction: Double?
    /// The shot scan reads part of the frames (the combined pass).
    var combined = false

    var message: String {
        let percent = fraction.map { " \(Int(($0 * 100).rounded(.down))) %" } ?? "…"
        return "Detecting faces in \(fileName)\(percent)"
    }
}

/// Faces in the app (§4, §5, §10; T07): Add faces sheet scans the current
/// movie's frames of a scope for faces (frames already in the face cache are
/// not read again) and adds a faces sheet of the frames with faces; Cancel
/// keeps what was found, so the same scope resumes. When the shot scan has
/// not read the frames, the face scan reads them in the shot scan's pass
/// (combined), which leaves the shot scan stopped part way (or complete).
/// Sort and Filter are one undo step each.
extension AppModel {
    var isFaceScanning: Bool { faceScanJob != nil }

    /// Loads the face model once per launch, when a movie opens.
    func warmUpFaceDetection() {
        guard !facesWarmedUp else { return }
        facesWarmedUp = true
        Task.detached(priority: .utility) { await VisionFaceAnalyzer.shared.warmUp() }
    }

    /// Every 10th frame, or every 100th for a movie on the ffmpeg path.
    var defaultFaceScanScope: FaceScanScope {
        let decoder = library.currentFileId.flatMap(openBackend)?.kind ?? .avFoundation
        return FaceScanScope.defaultScope(for: decoder)
    }

    /// Toolbar: Add faces sheet with a scope, for the current sheet's
    /// shown thumbs (MoviePrint's visible thumbs).
    func addFacesSheet(_ scope: FaceScanScope) {
        guard scanJob == nil, faceScanJob == nil, let file = currentFile, let sheet = currentSheet,
              sheet.type != .faces
        else { return }
        checkMovieFile(file.id)
        guard !missing.contains(file.id) else {
            toast = "\(file.name): the movie is missing."
            return
        }
        let frames = scope.frames(thumbFrames: shownThumbs(of: sheet).map(\.frameNumber), frameCount: file.frameCount)
        guard !frames.isEmpty else { return }
        cancelScrub()
        // The scan holds the DecodeGate; playback would hold it as well.
        player.pause()
        let settings = library.settings
        let store = faceStore
        let scans = scanStore
        faceScanJob = FaceScanJob(fileId: file.id, fileName: file.name, scope: scope)
        scanTask = Task {
            var single: (any DecodeBackend)?
            if scope == .thumbs {
                do {
                    single = try await backend(for: file)
                } catch {
                    faceScanJob = nil
                    scanTask = nil
                    toast = "\(file.name): \(error.localizedDescription)"
                    return
                }
            }
            let request = FaceScanRequest(
                fileId: file.id, url: library.file(file.id)?.url ?? file.url, frames: frames,
                thresholds: settings.faceThresholds, analyzer: VisionFaceAnalyzer.shared,
                ffmpeg: await ffmpegTools(), singleFrames: single, faceStore: store, scanStore: scans,
                method: settings.shotDetectionMethod, shotThreshold: settings.shotDetectionThreshold)
            var ended = false
            for await event in FaceScanner.scan(request) {
                switch event {
                case .started(_, let combined):
                    faceScanJob?.combined = combined
                    faceScanJob?.fraction = 0
                case .progress(let fraction):
                    faceScanJob?.fraction = fraction
                case .finished(let data, let shotScan):
                    ended = true
                    noteShotScan(file.id, shotScan)
                    finishFaceScan(file.id, frames: frames, data: data)
                case .cancelled(_, let shotScan):
                    ended = true
                    noteShotScan(file.id, shotScan)
                    endFaceScan(cancelled: true)
                case .failed(let message, _):
                    ended = true
                    endFaceScan(cancelled: false)
                    toast = "\(file.name): face detection failed: \(message)"
                }
            }
            // Cancel ends the stream before the scanner's last event.
            if !ended {
                if faceScanJob?.combined == true { stoppedScans.insert(file.id) }
                endFaceScan(cancelled: true)
            }
            scanTask = nil
        }
    }

    /// The shot scan a combined pass left: complete marks the movie
    /// scanned; part way, the shot-detection button resumes it.
    private func noteShotScan(_ fileId: UUID, _ data: ScanData?) {
        guard let data else { return }
        if data.complete {
            scanData[fileId] = data
            stoppedScans.remove(fileId)
            update { library in
                if let i = library.files.firstIndex(where: { $0.id == fileId }) { library.files[i].scanState = .scanned }
            }
        } else {
            stoppedScans.insert(fileId)
        }
    }

    /// The scan is done: a faces sheet of the scope's frames with faces, as
    /// one undo step.
    private func finishFaceScan(_ fileId: UUID, frames: [Int], data: FaceData) {
        let job = faceScanJob
        faceScanJob = nil
        let added = edit { library -> Bool in
            guard let sheet = library.addFacesSheet(to: fileId, frames: frames, faces: data) else { return false }
            library.currentFileId = fileId
            library.currentSheetId = sheet.id
            return true
        }
        if added {
            selectedThumbId = nil
        } else {
            showNotice("No faces found in \(job?.fileName ?? "the movie") (\(job?.scope.label.lowercased() ?? "")).")
        }
    }

    private func endFaceScan(cancelled: Bool) {
        let job = faceScanJob
        faceScanJob = nil
        if cancelled, let job {
            let at = job.fraction.map { " at \(Int(($0 * 100).rounded(.down))) %" } ?? ""
            showNotice("Face detection stopped\(at). Add faces sheet resumes it.")
        }
    }

    // MARK: - Sort and filter

    /// Sort menu: one undo step.
    func sortSheet(_ sort: ThumbSort) {
        guard let ref = currentRef else { return }
        cancelScrub()
        let includeHidden = library.settings.showHiddenThumbs
        edit { $0.sortThumbs(ref, by: sort, includeHidden: includeHidden) }
    }

    /// Filter menu: one undo step per change.
    func setFaceFilter(_ filter: FaceFilter) {
        guard let ref = currentRef, currentSheet?.faceFilter ?? FaceFilter() != filter else { return }
        cancelScrub()
        edit { $0.setFaceFilter(ref, filter) }
    }

    /// Face rectangles are drawn on this sheet's thumbs in the window and
    /// the player.
    func showsFaceRectangles(_ sheet: Sheet) -> Bool {
        library.settings.showFaceRectangles && sheet.type == .faces
    }
}
