import AppKit
import FrameSheetCore
import Foundation
import Synchronization

/// A face scan in progress (§10): the movie, the scope and the progress for
/// the toast.
struct FaceScanJob: Equatable {
    var fileId: UUID
    var fileName: String
    var scope: FaceScanScope
    var fraction: Double?
    /// The shot scan reads part of the frames (the combined pass).
    var combined = false
    /// What the faces sheet stores of the scan.
    var source: FaceSheetSource
    /// Apply: the faces sheet whose thumbs the scan replaces; nil adds a
    /// faces sheet.
    var target: SheetRef?

    var message: String {
        let percent = fraction.map { " \(Int(($0 * 100).rounded(.down))) %" } ?? "…"
        return "Detecting faces in \(fileName)\(percent)"
    }
}

/// The face scan's thumbnails, handed from its analysis worker to the main
/// actor.
final class ScanThumbnailInbox: Sendable {
    struct Item: @unchecked Sendable {
        var frame: Int
        var image: CGImage
        var width: Int
    }

    private let items = Mutex<[Item]>([])

    func add(_ frame: Int, _ image: CGImage, _ width: Int) {
        items.withLock { $0.append(Item(frame: frame, image: image, width: width)) }
    }

    func take() -> [Item] {
        items.withLock { items in
            defer { items.removeAll() }
            return items
        }
    }
}

/// Faces in the app (§4, §5, §10; T07): Add faces sheet scans the current
/// movie's frames of a scope for faces (frames already in the face cache are
/// not read again) and adds a faces sheet of the frames with faces; Cancel
/// keeps what was found, so the same scope resumes. When the shot scan has
/// not read the frames, the face scan reads them in the shot scan's pass
/// (combined), which leaves the shot scan stopped part way (or complete).
/// Sort and Filter are one undo step each.
///
/// The scan makes the thumbnails of the frames with faces from the frames it
/// analyzes, at the size the faces sheet draws them, so the sheet shows as
/// soon as it is added; decoding them again took minutes on open-GOP films.
extension AppModel {
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
        let source = FaceSheetSource(
            scope: scope, thumbFrames: shownThumbs(of: sheet).map(\.frameNumber), frameCount: file.frameCount,
            thresholds: library.settings.faceThresholds)
        runFaceScan(file, source: source, target: nil)
    }

    /// Apply (Settings, Face detection) is available: the current sheet is
    /// a faces sheet made with other thresholds than the current ones, and
    /// nothing scans.
    var canApplyFaceThresholds: Bool {
        guard !isScanning, let ref = currentRef else { return false }
        return library.faceSheetNeedsRescan(ref, thresholds: library.settings.faceThresholds)
    }

    /// The current sheet is a faces sheet whose faces were found with
    /// another rotation or crop (the banner and Apply's caption say so).
    var facesSheetTransformChanged: Bool {
        guard let ref = currentRef else { return false }
        return library.faceSheetTransformChanged(ref)
    }

    /// The current sheet is a faces sheet.
    var isFacesSheetShown: Bool { currentSheet?.type == .faces }

    /// Apply: rescans the current faces sheet's frames with the current
    /// thresholds and replaces its thumbs in place (one undo step); Cancel
    /// keeps what was found, and Apply resumes it.
    func applyFaceThresholds() {
        guard scanJob == nil, faceScanJob == nil, canApplyFaceThresholds, let file = currentFile,
              let ref = currentRef, let source = library.faceSheetSource(ref)
        else { return }
        runFaceScan(file, source: source.with(library.settings.faceThresholds), target: ref)
    }

    /// Scans `source`'s frames of `file` for faces, then adds a faces sheet
    /// or, with `target`, replaces that sheet's thumbs.
    private func runFaceScan(_ file: MovieFile, source: FaceSheetSource, target: SheetRef?) {
        var source = source
        source.transform = library.file(file.id)?.transform ?? file.transform
        checkMovieFile(file.id)
        guard !missing.contains(file.id) else {
            toast = "\(file.name): the movie is missing."
            return
        }
        let scope = source.scope
        let frames = source.frames(frameCount: file.frameCount)
        guard !frames.isEmpty else { return }
        cancelScrub()
        // The scan holds the DecodeGate; playback would hold it as well.
        player.pause()
        let settings = library.settings
        let store = faceStore
        let scans = scanStore
        faceScanJob = FaceScanJob(fileId: file.id, fileName: file.name, scope: scope, source: source, target: target)
        // The frames the scan will analyze (those not in the face cache).
        var pending = frames
        if let stored = (try? store?.load(file.id)) ?? nil, stored.thresholds == settings.faceThresholds {
            pending = stored.missing(frames)
        }
        faceScanFrames = (file.id, Set(pending))
        let inbox = ScanThumbnailInbox()
        let thumbnails = scanThumbnails(for: file, settings: settings, inbox: inbox)
        let log = ScanLog("face scan")
        scanLog = log
        let decoder = openBackend(file.id)?.kind.rawValue ?? "not open yet"
        log.write("app: face scan of \(file.name)\(target == nil ? "" : " (Apply)"), "
            + "scope \(scope.label.lowercased()), frames \(frames.first ?? 0)–"
            + "\(frames.last ?? 0) (\(frames.count) frames, \(pending.count) not in the face cache), "
            + "thresholds confidence \(settings.faceThresholds.confidence) size \(settings.faceThresholds.size), "
            + "thumbnail backend \(decoder), main area \(Int(mainAreaSize.width))x\(Int(mainAreaSize.height)) pt")
        scanTask = Task {
            var single: (any DecodeBackend)?
            if scope == .thumbs {
                do {
                    single = try await backend(for: file)
                } catch {
                    faceScanJob = nil
                    faceScanFrames = nil
                    scanTask = nil
                    log.end("could not open the movie: \(error.localizedDescription)")
                    scanLog = nil
                    toast = "\(file.name): \(error.localizedDescription)"
                    return
                }
            }
            var request = FaceScanRequest(
                fileId: file.id, url: library.file(file.id)?.url ?? file.url, frames: frames,
                thresholds: settings.faceThresholds, analyzer: VisionFaceAnalyzer.shared,
                ffmpeg: await ffmpegTools(), singleFrames: single, faceStore: store, scanStore: scans,
                method: settings.shotDetectionMethod, shotThreshold: settings.shotDetectionThreshold,
                thumbnails: thumbnails)
            request.transform = library.file(file.id)?.transform ?? file.transform
            request.log = log.sink
            let clock = ContinuousClock()
            var how = "stream ended by Cancel"
            var ended = false
            for await event in FaceScanner.scan(request) {
                let handling = clock.now
                var kind = "progress"
                switch event {
                case .started(let missing, let combined):
                    kind = "started"
                    log.write("app: started, \(missing) frames to analyze, \(combined ? "combined" : "faces-only") pass")
                    faceScanJob?.combined = combined
                    faceScanJob?.fraction = 0
                case .progress(let fraction):
                    faceScanJob?.fraction = fraction
                    let stored = storeScanThumbnails(inbox, file.id)
                    log.write("app: progress \(String(format: "%.1f", fraction * 100)) %, \(stored) thumbnail(s) "
                        + "stored, main \(ScanLog.ms(clock.now - handling))")
                case .finished(let data, let shotScan):
                    kind = "end"
                    ended = true
                    how = "finished, \(data.frames.count) frames with faces"
                    storeScanThumbnails(inbox, file.id)
                    noteShotScan(file.id, shotScan)
                    finishFaceScan(file.id, frames: frames, data: data)
                case .cancelled(_, let shotScan):
                    kind = "end"
                    ended = true
                    how = "cancelled"
                    storeScanThumbnails(inbox, file.id)
                    noteShotScan(file.id, shotScan)
                    endFaceScan(cancelled: true)
                case .failed(let message, _):
                    kind = "end"
                    ended = true
                    how = "failed: \(message)"
                    storeScanThumbnails(inbox, file.id)
                    endFaceScan(cancelled: false)
                    toast = "\(file.name): face detection failed: \(message)"
                }
                log.mainActor(kind, clock.now - handling)
            }
            // Cancel ends the stream before the scanner's last event.
            if !ended {
                let handling = clock.now
                storeScanThumbnails(inbox, file.id)
                if faceScanJob?.combined == true { stoppedScans.insert(file.id) }
                endFaceScan(cancelled: true)
                log.mainActor("end", clock.now - handling)
            }
            log.end(how)
            if scanLog === log { scanLog = nil }
            scanTask = nil
        }
    }

    /// Thumbnails from the face scan's frames: the n-th frame with faces at
    /// the width a faces sheet of n thumbs draws them in the main area now
    /// (so each is at least as wide as the finished sheet needs, and the
    /// first few, drawn largest, are few), cached as they arrive.
    private func scanThumbnails(
        for file: MovieFile, settings: FrameSheetCore.Settings, inbox: ScanThumbnailInbox
    ) -> FaceScanThumbnails {
        let padding = SheetGridView.padding
        let width = mainAreaSize.width - padding * 2 - GridGeometry.minPrintWidthMargin
        let height = mainAreaSize.height - padding * 2
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return FaceScanThumbnails(
            width: { count in
                ThumbnailWidth.facesSheetDecodeWidth(
                    file: file, thumbCount: count, settings: settings, containerWidth: width,
                    containerHeight: height, scale: scale)
            },
            deliver: { frame, image, madeFor in inbox.add(frame, image, madeFor) })
    }

    /// Caches the thumbnails the scan made since the last call; before the
    /// faces sheet is added, so it finds all of them. Returns how many.
    @discardableResult
    private func storeScanThumbnails(_ inbox: ScanThumbnailInbox, _ fileId: UUID) -> Int {
        let items = inbox.take()
        for item in items {
            storeScanThumbnail(item.image, file: fileId, frame: item.frame, width: item.width)
        }
        return items.count
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

    /// The scan is done: a faces sheet of the scope's frames with faces, or
    /// (Apply) the target sheet's thumbs replaced, as one undo step.
    private func finishFaceScan(_ fileId: UUID, frames: [Int], data: FaceData) {
        let job = faceScanJob
        faceScanJob = nil
        faceScanFrames = nil
        thumbnailsChanged()
        if let job, let target = job.target {
            let replaced = edit { $0.replaceFacesSheetThumbs(target, frames: frames, faces: data, source: job.source) }
            if replaced {
                if currentRef == target { selectedThumbId = nil }
            } else if library.sheet(target.sheetId, of: target.fileId) == nil {
                showNotice("The faces sheet was removed during the scan.")
            } else {
                showNotice(FaceScanNotice.noFaces(
                    fileName: job.fileName, requested: frames, data: data,
                    detail: " with these thresholds. The sheet is unchanged."))
            }
            return
        }
        let added = edit { library -> Bool in
            guard let sheet = library.addFacesSheet(to: fileId, frames: frames, faces: data, source: job?.source)
            else { return false }
            library.currentFileId = fileId
            library.currentSheetId = sheet.id
            return true
        }
        if added {
            selectedThumbId = nil
        } else {
            showNotice(FaceScanNotice.noFaces(
                fileName: job?.fileName ?? "the movie", requested: frames, data: data,
                detail: job.map { ", \($0.scope.label.lowercased())." } ?? "."))
        }
    }

    private func endFaceScan(cancelled: Bool) {
        let job = faceScanJob
        faceScanJob = nil
        faceScanFrames = nil
        thumbnailsChanged()
        loadCurrentSheet()
        if cancelled, let job {
            let at = job.fraction.map { " at \(Int(($0 * 100).rounded(.down))) %" } ?? ""
            showNotice("Face detection stopped\(at). \(job.target == nil ? "Add faces sheet" : "Apply") resumes it.")
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
