import FrameSheetCore
import Foundation

/// A shot scan in progress (§10): the movie, the shot sheet its scenes
/// stream into, and the progress for the toast.
struct ScanJob: Equatable {
    var fileId: UUID
    var fileName: String
    var sheetId: UUID
    var framesScanned = 0
    var frameCount = 0
    /// Frame a cancelled scan resumed from (0 for a fresh scan).
    var resumedAt = 0
    var started = false

    var fraction: Double? {
        guard started, frameCount > 0 else { return nil }
        return min(1, Double(framesScanned) / Double(frameCount))
    }

    var message: String {
        let percent = fraction.map { " \(Int(($0 * 100).rounded(.down))) %" } ?? "…"
        return "Detecting shots in \(fileName)\(percent)"
    }
}

/// What the scan cache holds for a movie.
enum ScanCacheState {
    case none, partial, complete
}

/// Shot detection in the app (§5, §10): Add shot-detection sheet scans the
/// current movie, or takes its complete scan from the cache, and streams the
/// scenes into a new shot sheet; Cancel keeps the partial scan in the cache,
/// and the same button resumes it; Rescan (movie menu) scans again from the
/// start. Only one scan runs at a time. The scan holds the DecodeGate and
/// lets thumb requests of other sheets go first in turns (Part 1); the sheet
/// being filled shows its mean colors only until the scan ends, so the scan
/// is not made to reopen its reader for each new scene's thumb.
extension AppModel {
    var isScanning: Bool { streamingSheet != nil }

    /// The current sheet is the one a scan streams into.
    var isStreamingSheetShown: Bool {
        guard let ref = streamingSheet else { return false }
        return ref.fileId == library.currentFileId && ref.sheetId == library.currentSheetId
    }

    func scanCacheState(_ fileId: UUID) -> ScanCacheState {
        if library.file(fileId)?.scanState == .scanned { return .complete }
        if stoppedScans.contains(fileId) { return .partial }
        guard let store = scanStore else { return .none }
        return FileManager.default.fileExists(atPath: store.url(for: fileId).path) ? .partial : .none
    }

    /// Toolbar: Add shot-detection sheet for the current movie.
    func addShotDetectionSheet() {
        guard let fileId = library.currentFileId else { return }
        startScan(fileId, rescan: false)
    }

    /// Movie menu: Rescan for shots, from the first frame, ignoring the
    /// cache (a changed detection method also scans from the start).
    func rescan(_ fileId: UUID) {
        startScan(fileId, rescan: true)
    }

    func cancelScan() { scanTask?.cancel() }

    private func startScan(_ fileId: UUID, rescan: Bool) {
        guard scanJob == nil, let file = library.file(fileId) else { return }
        checkMovieFile(fileId)
        guard !missing.contains(fileId) else {
            toast = "\(file.name): the movie is missing."
            return
        }
        cancelScrub()
        // The scan holds the DecodeGate; playback would hold it as well.
        player.pause()
        let settings = library.settings
        // The sheet the scenes stream into: not undoable while it fills; the
        // finished sheet is added as one undo step.
        var sheetId: UUID?
        update { library in
            sheetId = library.addShotSheet(to: fileId, scenes: [])?.id
            if let sheetId {
                library.currentFileId = fileId
                library.currentSheetId = sheetId
            }
        }
        guard let sheetId else { return }
        let ref = SheetRef(fileId: fileId, sheetId: sheetId)
        selectedThumbId = nil
        scanJob = ScanJob(fileId: fileId, fileName: file.name, sheetId: sheetId)
        streamingSheet = ref
        let store = scanStore
        scanTask = Task {
            let request = ScanRequest(
                fileId: fileId, url: file.url, method: settings.shotDetectionMethod,
                threshold: settings.shotDetectionThreshold, ffmpeg: await ffmpegTools(), store: store,
                rescan: rescan)
            let clock = ContinuousClock()
            var lastApplied: ContinuousClock.Instant?
            var ended = false
            for await event in ShotScanner.scan(request) {
                switch event {
                case .started(_, let frameCount, let resumedAt):
                    scanJob?.started = true
                    scanJob?.frameCount = frameCount
                    scanJob?.resumedAt = resumedAt
                    scanJob?.framesScanned = resumedAt
                case .progress(let scanned, let frameCount):
                    scanJob?.framesScanned = scanned
                    scanJob?.frameCount = frameCount
                case .scenes(let spans):
                    // At most once a second: each update rebuilds the sheet
                    // (scenes keep their ids, so the views mostly stay).
                    let now = clock.now
                    if lastApplied.map({ now - $0 >= .seconds(1) }) ?? true {
                        lastApplied = now
                        updateWithoutSaving { $0.replaceScenes(ref, with: spans) }
                    }
                case .finished(let data):
                    ended = true
                    finishScan(ref, data: data, threshold: settings.shotDetectionThreshold)
                case .cancelled:
                    ended = true
                    endScan(ref, cancelled: true)
                case .failed(let message):
                    ended = true
                    endScan(ref, cancelled: false)
                    toast = "\(file.name): shot detection failed: \(message)"
                }
            }
            // Cancel ends the stream before the scanner's last event.
            if !ended { endScan(ref, cancelled: true) }
            scanTask = nil
        }
    }

    /// The scan is complete: the movie is marked scanned, and its sheet
    /// gets the scenes at the threshold the scan used, as one undo step.
    private func finishScan(_ ref: SheetRef, data: ScanData, threshold: Double) {
        scanData[ref.fileId] = data
        stoppedScans.remove(ref.fileId)
        let spans = SceneList.scenes(from: data, threshold: threshold)
        let placeholder = library.sheet(ref.sheetId, of: ref.fileId)
        let index = library.sheets[ref.fileId]?.firstIndex { $0.id == ref.sheetId }
        let wasCurrent = library.currentSheetId == ref.sheetId
        scanJob = nil
        streamingSheet = nil
        update { library in
            library.sheets[ref.fileId]?.removeAll { $0.id == ref.sheetId }
            if wasCurrent { library.currentSheetId = library.sheets[ref.fileId]?.first?.id }
            if let i = library.files.firstIndex(where: { $0.id == ref.fileId }) { library.files[i].scanState = .scanned }
        }
        edit { library in
            guard let file = library.file(ref.fileId) else { return }
            if var sheet = placeholder {
                let content = SceneList.shotSheetContent(spans, frameCount: file.frameCount)
                sheet.thumbs = content.thumbs
                sheet.scenes = content.scenes
                let list = library.sheets[ref.fileId] ?? []
                library.sheets[ref.fileId, default: []].insert(sheet, at: min(index ?? list.count, list.count))
                if wasCurrent { library.currentSheetId = sheet.id }
            } else if let sheet = library.addShotSheet(to: ref.fileId, scenes: spans), wasCurrent {
                // The sheet was deleted (or undone) while it filled.
                library.currentSheetId = sheet.id
            }
        }
    }

    /// Cancelled or failed: the sheet goes; the partial scan stays in the
    /// cache, so Add shot-detection sheet resumes it.
    private func endScan(_ ref: SheetRef, cancelled: Bool) {
        guard scanJob?.sheetId == ref.sheetId else { return }
        let job = scanJob
        scanJob = nil
        streamingSheet = nil
        update { library in
            let wasCurrent = library.currentSheetId == ref.sheetId
            library.sheets[ref.fileId]?.removeAll { $0.id == ref.sheetId }
            if wasCurrent { library.currentSheetId = library.sheets[ref.fileId]?.first?.id }
            // A rescan replaced the complete scan with the partial one.
            if let i = library.files.firstIndex(where: { $0.id == ref.fileId }) { library.files[i].scanState = .none }
        }
        scanData[ref.fileId] = nil
        // The scanner keeps what it read, also when it failed part way.
        if job?.started == true { stoppedScans.insert(ref.fileId) }
        if cancelled, let job {
            let at = job.fraction.map { " at \(Int(($0 * 100).rounded(.down))) %" } ?? ""
            showNotice("Shot detection stopped\(at). The shot-detection button resumes it.")
        }
    }

    /// Settings → Add new sheet: a shot sheet at the current threshold,
    /// rebuilt from the stored scan without scanning again.
    func addShotSheetFromCache() {
        guard let fileId = library.currentFileId, let data = completeScan(fileId) else {
            toast = "Scan the movie first (Add shot-detection sheet)."
            return
        }
        let spans = SceneList.scenes(from: data, threshold: library.settings.shotDetectionThreshold)
        edit { library in
            if let sheet = library.addShotSheet(to: fileId, scenes: spans) { library.currentSheetId = sheet.id }
        }
    }

    /// The movie's complete scan, from memory or the cache.
    func completeScan(_ fileId: UUID) -> ScanData? {
        if let data = scanData[fileId], data.complete { return data }
        guard let data = (try? scanStore?.load(fileId)) ?? nil, data.complete else { return nil }
        scanData[fileId] = data
        return data
    }

    /// Grid → Automatic IN/OUT → Apply: detects IN and OUT for the
    /// current movie (sequentially, through the DecodeGate like every
    /// decode) and recaptures the current interval sheet's thumbs between
    /// them, with the movie's IN and OUT, as one undo step.
    func applyAutomaticInOut() {
        guard !isDetectingInOut, let ref = currentRef, let file = currentFile else { return }
        checkMovieFile(file.id)
        guard !missing.contains(file.id) else {
            toast = "\(file.name): the movie is missing."
            return
        }
        // The entry may have followed its bookmark.
        let url = library.file(file.id)?.url ?? file.url
        let threshold = library.settings.automaticInOutThreshold
        isDetectingInOut = true
        Task {
            defer { isDetectingInOut = false }
            do {
                let points = try await AutoInOut.detect(url, ffmpeg: await ffmpegTools(), threshold: threshold)
                guard points.inFrame < points.outFrame else {
                    showNotice("No IN/OUT found in \(file.name).")
                    return
                }
                edit { $0.applyInOut(ref, inFrame: points.inFrame, outFrame: points.outFrame) }
                showNotice("IN \(points.inFrame), OUT \(points.outFrame)")
            } catch {
                toast = "\(file.name): automatic IN/OUT failed: \(error.localizedDescription)"
            }
        }
    }
}
