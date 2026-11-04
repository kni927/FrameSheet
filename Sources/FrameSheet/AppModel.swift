import AppKit
import FrameSheetCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A scrub in progress (§7): the thumb, its neighbors' frames and the frame
/// under the pointer (or chosen with the arrow keys).
struct ScrubSession {
    var ref: SheetRef
    var thumbId: UUID
    var mapping: ScrubMapping
    var frame: Int
    /// Live modifiers while dragging; fixed at the start for the keyboard.
    var modifiers: ScrubModifiers
    var keyboard: Bool
    /// The pointer is over the Cancel bar.
    var overCancel = false
    var lastX: Double
    var lastY: Double
    var startedAt = Date()
    /// Opened by a click on the handle (released within a second, as in
    /// MoviePrint): the pointer scrubs without a button held, a click
    /// confirms.
    var sticky = false

    var action: ScrubAction { ScrubAction(modifiers) }
    /// A shot sheet's scrub: inside the scene, always change (§7).
    var sceneLimited: Bool { mapping.limitedToRange }
    /// Frames shown left and right of the live frame.
    var lowFrame: Int { modifiers.contains(.option) ? mapping.thumbFrame : mapping.leftFrame }
    var highFrame: Int { modifiers.contains(.shift) ? mapping.thumbFrame : mapping.rightFrame }
}

/// App state: the library with its undo history, the open decoders, the
/// thumbnail cache and the ffmpeg discovery. All UI work runs on the main
/// actor; decoding runs in the backends.
@MainActor @Observable
final class AppModel {
    private(set) var document: EditableLibrary
    var library: Library { document.library }
    private(set) var ffmpeg: FFmpegDiscovery?
    private(set) var isFindingFFmpeg = false
    /// Latest warning or error for the toast; nil hides it. It clears itself
    /// after `toastSeconds` (the close button hides it sooner).
    var toast: String? {
        didSet { scheduleToastDismissal() }
    }
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    static let toastSeconds = 10
    /// A short confirmation ("Saved …"), shown when no error is; clears
    /// itself after a few seconds.
    var notice: String?
    /// A save in progress, shown in the toast with Cancel.
    var progress: SaveProgress?
    /// The shot scan in progress (one at a time), shown in the toast with
    /// Cancel; its scenes stream into `scanJob.sheetId`.
    var scanJob: ScanJob?
    /// The face scan in progress (T07), shown in the toast with Cancel; it
    /// shares `scanTask` with the shot scan (one scan at a time).
    var faceScanJob: FaceScanJob?
    /// Movies whose scan stopped before the end in this session. The partial
    /// cache is written after the stream ends, so the toolbar reads this
    /// instead of waiting for the file.
    var stoppedScans: Set<UUID> = []
    /// The sheet a scan streams into, set when the scan starts and cleared
    /// when it ends. Thumb views and controls read this, not `scanJob`, so
    /// the progress updates redraw only the toast.
    var streamingSheet: SheetRef?
    /// Automatic IN/OUT → Apply is detecting.
    var isDetectingInOut = false
    /// The detection chart (key F) while it is open.
    var detectionChart: DetectionChartData?
    var showMovieList = true
    var showSettings = true
    /// Missing movie files by id (checked on launch and on open).
    private(set) var missing: Set<UUID> = []
    /// Bumped when images land in the cache, so views re-read it.
    private(set) var imageGeneration = 0

    // View state, not part of the document and not undoable.
    /// Grid zoom relative to Fit (1): one of `GridGeometry.zoomSteps`, or
    /// between them after Fit height or Fit width.
    private(set) var zoom = 1.0
    var selectedThumbId: UUID?
    private(set) var scrub: ScrubSession?
    /// Option is held: IN/OUT hide all before/after instead.
    var optionHeld = false
    /// A text field (the sheet rename field) has focus: Undo and Redo act
    /// on its typing.
    var isEditingText = false
    private(set) var scrubImage: CGImage?
    /// The frame `scrubImage` was decoded for and the frame it shows (the
    /// nearest decodable one when it did not decode exactly); nil while there
    /// is no image. While a newer frame decodes, it still names the old one.
    private(set) var scrubShown: (requested: Int, actual: Int)?
    /// Size of the main area, where the scrub overlay is drawn; the grid
    /// fills it.
    var mainAreaSize: CGSize = .zero

    /// The cache key of window thumbs, and the widest they are decoded at
    /// (enough for a 4-column grid on a Retina display). A grid's thumbs are
    /// decoded at the size they are drawn (`thumbDecodeWidth`), so a sheet
    /// of hundreds of small thumbs fits the cache (`ThumbnailWidth`).
    static let thumbWidth = ThumbnailWidth.maximum
    static let posterWidth = 320

    let cache: ThumbnailCache
    /// The player view (§9).
    let player = PlayerController()
    private let store: LibraryStore?
    @ObservationIgnored private var backends: [UUID: any DecodeBackend] = [:]
    /// The file each movie's backend and cached images came from; when undo
    /// or redo puts another file under the entry, they are dropped.
    @ObservationIgnored private var linkedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// Frames that failed to decode; not retried automatically on redraw.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var lastReload: [String: Date] = [:]
    /// Images on screen now (the current sheet's thumbs and the posters),
    /// held strongly: NSCache may drop entries under memory pressure even
    /// below its cost limit, and every drop showed as an empty cell and a
    /// redraw. Pruned to what is on screen when the sheet changes.
    @ObservationIgnored private var pinned: [String: CGImage] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Save Sheet while it runs (one at a time).
    @ObservationIgnored var saveJob: Task<Void, Never>?
    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private var columnsAtDragStart: Int?
    @ObservationIgnored private var secondsPerRowAtDragStart: Double?
    @ObservationIgnored var scanTask: Task<Void, Never>?
    /// Complete scans read from the scan cache, by movie id (§10).
    @ObservationIgnored var scanData: [UUID: ScanData] = [:]
    let scanStore: ScanCacheStore?
    /// Face scan results, next to the scan cache (§10).
    let faceStore: FaceCacheStore?
    /// The face request was warmed up in this process.
    @ObservationIgnored var facesWarmedUp = false
    /// Target rows set by the Rows slider for one sheet at one column count;
    /// not persisted, and void once the sheet or its columns change.
    private var rowsTarget: (sheetId: UUID, columns: Int, rows: Int)?
    @ObservationIgnored private var scrubPending: Int?
    /// Live scrub frames, kept apart from `cache`: display-size frames are
    /// several MB each, and filling the shared cache with them evicted the
    /// grid's thumbs, which then redrew. Only the most recent ones are kept.
    @ObservationIgnored private var scrubFrames: [(key: String, image: CGImage, actual: Int)] = []
    private static let scrubFrameLimit = 16
    @ObservationIgnored private var scrubDecode: Task<Void, Never>?
    /// Whether the scrub's frames decoded exactly, by frame, as the live
    /// preview found them; a confirmed frame that did not is not stored.
    @ObservationIgnored private var scrubExact: [Int: Bool] = [:]
    /// Thumbs moved to the nearest decodable frame (decision 11), by thumb
    /// id: the frame asked for and the frame shown. View state, not saved;
    /// the marker shows while the thumb still shows that frame.
    private(set) var nearestThumbs: [UUID: (requested: Int, shown: Int)] = [:]
    /// Images cached under the frame asked for that show another frame (the
    /// retry's), with the frame they show; turning the ffmpeg fallback on
    /// drops just these.
    @ObservationIgnored private var inexactImages: [ImageKey: Int] = [:]

    /// The width each window thumb (cached under `thumbWidth`) was decoded
    /// or made for, by loading key; a missing entry means `thumbWidth`. A
    /// thumb drawn wider than that is decoded again, once.
    @ObservationIgnored private var thumbWidths: [String: Int] = [:]
    /// Thumb misses waiting to be decoded together, by movie and width.
    @ObservationIgnored private var pendingReloads: [ReloadGroup: Set<Int>] = [:]
    @ObservationIgnored private var reloadFlush: Task<Void, Never>?
    /// The last `thumbDecodeWidth` result and what it was computed from.
    @ObservationIgnored private var decodeWidthMemo: (key: DecodeWidthKey, width: Int)?
    /// The movie a face scan runs on and the frames it will analyze: a
    /// faces sheet of that movie does not decode them meanwhile, since the
    /// scan gives the thumbnails of those with faces (each decode would
    /// also make the scan pause).
    @ObservationIgnored var faceScanFrames: (fileId: UUID, frames: Set<Int>)?

    private struct ReloadGroup: Hashable {
        var file: UUID
        var width: Int
    }

    private struct DecodeWidthKey: Equatable {
        var sheet: UUID
        var columns: Int
        var cells: Int
        var area: CGSize
        var zoom: Double
        var scale: Double
    }

    struct ImageKey: Hashable {
        var file: UUID
        var frame: Int
        var width: Int
    }

    init() {
        let store = (try? LibraryStore.defaultURL()).map(LibraryStore.init)
        var loaded = Library()
        var loadError: String?
        if let store {
            do {
                loaded = try store.load()
            } catch {
                loadError = "The movie list could not be read: \(error.localizedDescription)"
            }
        }
        var missing: Set<UUID> = []
        for i in loaded.files.indices { Self.resolveBookmark(at: i, in: &loaded, missing: &missing) }
        self.store = store
        scanStore = (try? ScanCacheStore.defaultDirectory()).map(ScanCacheStore.init)
        faceStore = (try? ScanCacheStore.defaultDirectory()).map(FaceCacheStore.init)
        self.missing = missing
        document = EditableLibrary(loaded)
        cache = ThumbnailCache(limitMB: loaded.settings.thumbnailCacheMB)
        toast = loadError
        findFFmpeg()
        for file in library.files { loadPoster(file) }
        loadCurrentSheet()
        player.model = self
    }

    // MARK: - Library access

    var currentFile: MovieFile? { library.currentFileId.flatMap(library.file) }

    var currentSheet: Sheet? {
        guard let fileId = library.currentFileId, let sheetId = library.currentSheetId else { return nil }
        return library.sheet(sheetId, of: fileId)
    }

    var currentRef: SheetRef? {
        guard let fileId = library.currentFileId, let sheetId = library.currentSheetId,
              library.sheet(sheetId, of: fileId) != nil
        else { return nil }
        return SheetRef(fileId: fileId, sheetId: sheetId)
    }

    func sheets(of fileId: UUID) -> [Sheet] { library.sheets[fileId] ?? [] }

    /// Thumbs on screen: all of them with Show hidden thumbs, else the
    /// visible ones.
    func shownThumbs(of sheet: Sheet) -> [Thumb] {
        library.settings.showHiddenThumbs ? sheet.thumbs : sheet.visibleThumbs
    }

    func image(file: UUID, frame: Int, width: Int) -> CGImage? {
        _ = imageGeneration
        if let image = cachedImage(file: file, frame: frame, width: width) {
            // Drawn wider than it was decoded (zoom, fewer columns): shown
            // as it is until the wider one arrives.
            if width == Self.thumbWidth, file == library.currentFileId, !isStreamingSheetShown,
               let target = currentThumbDecodeWidth, decodedWidth(file, frame) < target {
                requestReload(file: file, frame: frame, width: width)
            }
            return image
        }
        // The sheet a scan fills shows mean colors until the scan ends: each
        // thumb decoded meanwhile would make the scan reopen its reader.
        if isStreamingSheetShown, file == library.currentFileId, width == Self.thumbWidth { return nil }
        if width == Self.thumbWidth, awaitsFaceScan(file, frame) { return nil }
        // Evicted from the cache (or never decoded): decode it again, outside
        // the view update that asked for it.
        requestReload(file: file, frame: frame, width: width)
        return nil
    }

    /// Queues a frame for decoding with the other misses of this moment,
    /// in one batch: one wait at the DecodeGate (and at most one pause of a
    /// running scan) instead of one per thumb.
    private func requestReload(file: UUID, frame: Int, width: Int) {
        let key = Self.loadingKey(file, frame, width)
        let now = Date()
        // At most one reload per image every 2 s, so a frame that never lands
        // under this key cannot turn redraws into a decode loop.
        guard !loading.contains(key), !failed.contains(key),
              now.timeIntervalSince(lastReload[key] ?? .distantPast) > 2
        else { return }
        lastReload[key] = now
        pendingReloads[ReloadGroup(file: file, width: width), default: []].insert(frame)
        guard reloadFlush == nil else { return }
        reloadFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            reloadFlush = nil
            let groups = pendingReloads
            pendingReloads = [:]
            for (group, frames) in groups {
                guard let movie = library.file(group.file) else { continue }
                load(frames: Array(frames), of: movie, width: group.width, sheetId: nil)
            }
        }
    }

    // MARK: - Edits

    /// The one undoable path: every user-visible change to the library goes
    /// through here (one undo step, only when something changed). Saves and
    /// loads the thumbs the change needs.
    @discardableResult
    func edit<T>(_ change: (inout Library) -> T) -> T {
        let result = document.edit(change)
        didChange()
        return result
    }

    /// Selection and settings: saved, but not undoable.
    func update(_ change: (inout Library) -> Void) {
        document.update(change)
        didChange()
    }

    func updateSettings(_ change: (inout FrameSheetCore.Settings) -> Void) {
        update { change(&$0.settings) }
    }

    var canUndo: Bool { document.history.canUndo }
    var canRedo: Bool { document.history.canRedo }

    func undo() {
        cancelScrub()
        if document.undo() { refreshLinks(); didChange() }
    }

    func redo() {
        cancelScrub()
        if document.redo() { refreshLinks(); didChange() }
    }

    /// Undo and Redo in the Edit menu and the window toolbar: the typing
    /// while a text field is being edited (KNOWN_ISSUES 5), else the library.
    /// They stay enabled while the rename field has focus, so the shortcut
    /// reaches it.
    var canPerformUndo: Bool { canUndo || isEditingText }
    var canPerformRedo: Bool { canRedo || isEditingText }

    func performUndo() {
        if let text = Self.editedText { text.undoManager?.undo() } else { undo() }
    }

    func performRedo() {
        if let text = Self.editedText { text.undoManager?.redo() } else { redo() }
    }

    /// The field editor of the text field being edited in the key window.
    private static var editedText: NSText? {
        NSApp.keyWindow?.firstResponder as? NSText
    }

    /// After undo or redo (of Replace movie, Clear movie list or an import):
    /// drops backends and images that belong to another file than the entry
    /// now names, checks again which movies are missing and loads posters.
    private func refreshLinks() {
        var relinked = false
        for file in library.files {
            if let linked = linkedURLs[file.id], linked != file.url {
                backends[file.id] = nil
                relinked = true
            }
            linkedURLs[file.id] = file.url
            if FileManager.default.fileExists(atPath: file.url.path) {
                missing.remove(file.id)
            } else {
                missing.insert(file.id)
            }
        }
        if relinked { forgetImages() }
        for file in library.files { loadPoster(file) }
    }

    /// Scenes streamed by a running scan: applied like `update` but not
    /// saved (the finished sheet is), so a long scan does not write the
    /// library every second.
    func updateWithoutSaving(_ change: (inout Library) -> Void) {
        document.update(change)
        if let id = selectedThumbId, currentSheet?.thumbs.contains(where: { $0.id == id }) != true {
            selectedThumbId = nil
        }
        loadCurrentSheet()
    }

    private func didChange() {
        if let id = selectedThumbId, currentSheet?.thumbs.contains(where: { $0.id == id }) != true {
            selectedThumbId = nil
        }
        scheduleSave()
        loadCurrentSheet()
    }

    /// Restarts the timer that clears the toast, for each new message.
    private func scheduleToastDismissal() {
        toastDismissal?.cancel()
        guard let message = toast else { return }
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled, let self, toast == message else { return }
            toast = nil
        }
    }

    // MARK: - ffmpeg

    func findFFmpeg() {
        isFindingFFmpeg = true
        let userPath = library.settings.ffmpegPath
        discovery = Task {
            let found = await FFmpegLocator(userPath: userPath).discover()
            ffmpeg = found
            isFindingFFmpeg = false
        }
    }

    /// Sets (or with nil clears) the user's ffmpeg path and searches again.
    /// AVFoundation backends are dropped too: their exact-frame fallback
    /// names the old ffmpeg.
    func setFFmpegPath(_ path: String?) {
        updateSettings { $0.ffmpegPath = path }
        backends = [:]
        findFFmpeg()
    }

    /// The exact-frame fallback can run: an ffmpeg with ffprobe next to it.
    var canFetchExactFramesWithFFmpeg: Bool { ffmpeg?.tools?.ffprobe != nil }

    /// Settings → Fetch exact frames with ffmpeg (decision 25). The open
    /// movies keep their backends and every exact image stays cached: the
    /// backends only switch the ffmpeg step on or off. Turned on, thumbs
    /// that were moved to the nearest decodable frame go back to the frame
    /// they asked for and only those decode again; turned off, nothing on
    /// screen changes and later misses take the retry.
    func setExactFramesWithFFmpeg(_ on: Bool) {
        guard on != library.settings.exactFramesWithFFmpeg else { return }
        cancelScrub()
        updateSettings { $0.exactFramesWithFFmpeg = on }
        Task {
            let tools = on ? await ffmpegTools() : nil
            // The choice may have flipped back while ffmpeg was looked up.
            guard library.settings.exactFramesWithFFmpeg == on else { return }
            for backend in backends.values {
                (backend as? AVFoundationBackend)?.setExactFallback(tools)
            }
            // Frames that failed outright may decode now (on), or with the
            // retry (off); they have no image, so nothing is redrawn.
            failed.removeAll()
            guard on else { return }
            refetchInexactImages()
        }
    }

    /// Drops only the images cached under a frame they do not show (see
    /// `load`) and puts the thumbs moved to the nearest decodable frame back
    /// on the frame they asked for, then loads what is now missing.
    private func refetchInexactImages() {
        for key in inexactImages.keys {
            cache.remove(file: key.file, frame: key.frame, width: key.width)
            pinned[Self.loadingKey(key.file, key.frame, key.width)] = nil
            lastReload[Self.loadingKey(key.file, key.frame, key.width)] = nil
        }
        inexactImages.removeAll()
        let moved = nearestThumbs
        nearestThumbs = [:]
        if !moved.isEmpty {
            document.update { library in
                for (fileId, sheets) in library.sheets {
                    for s in sheets.indices {
                        for t in sheets[s].thumbs.indices {
                            let thumb = sheets[s].thumbs[t]
                            if let entry = moved[thumb.id], thumb.frameNumber == entry.shown {
                                library.sheets[fileId]![s].thumbs[t].frameNumber = entry.requested
                            }
                        }
                    }
                }
            }
        }
        imageGeneration += 1
        didChange()
        for file in library.files { loadPoster(file) }
    }

    /// The frame a thumb asked for when it shows the nearest decodable frame
    /// instead; nil for a thumb that shows its own frame.
    func nearestFrame(of thumb: Thumb) -> Int? {
        guard let entry = nearestThumbs[thumb.id], entry.shown == thumb.frameNumber else { return nil }
        return entry.requested
    }

    /// The frame a cached image asked for as `frame` shows: `frame` itself,
    /// or the nearest decodable frame when it did not decode exactly.
    func shownFrame(file: UUID, frame: Int, width: Int) -> Int {
        inexactImages[ImageKey(file: file, frame: frame, width: width)] ?? frame
    }

    /// Why a frame can be shown only as the nearest decodable one, for the
    /// marker's tooltip and the scrub's toast.
    var exactFrameHint: String {
        if library.settings.exactFramesWithFFmpeg && canFetchExactFramesWithFFmpeg {
            return "ffmpeg could not decode it exactly either"
        }
        return canFetchExactFramesWithFFmpeg
            ? "turn on Fetch exact frames with ffmpeg in Settings"
            : "the exact frame needs ffmpeg"
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.message = "Choose the ffmpeg executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFFmpegPath(url.path)
    }

    func ffmpegTools() async -> FFmpegTools? {
        await discovery?.value
        return ffmpeg?.tools
    }

    // MARK: - Thumbnail cache

    func setCacheLimit(_ megabytes: Int) {
        updateSettings { $0.thumbnailCacheMB = megabytes }
        cache.setLimit(megabytes: megabytes)
    }

    func clearThumbnailCache() {
        forgetImages()
        for file in library.files { loadPoster(file) }
        loadCurrentSheet()
    }

    /// Empties the cache and what is pinned or marked failed.
    private func forgetImages() {
        cache.removeAll()
        pinned.removeAll()
        failed.removeAll()
        inexactImages.removeAll()
        thumbWidths.removeAll()
        imageGeneration += 1
    }

    // MARK: - Adding and removing movies

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.message = "Add movies (PNG and JSON files are imported as sheets)"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        openFiles(panel.urls)
    }

    /// Every way files come in (Add movies, drop, Import Sheet…, Open With)
    /// ends here: PNGs and JSON files are imported as sheets, the rest are
    /// added as movies. `clearFirst` (Option-drop) clears the list first.
    func openFiles(_ urls: [URL], clearFirst: Bool = false) {
        // A file reference URL (/.file/id=…) has no extension to route by.
        let files = urls.filter(\.isFileURL).map { ($0 as NSURL).filePathURL ?? $0 }
        let routed = IncomingFiles.route(files)
        guard !routed.movies.isEmpty || !routed.sheets.isEmpty else { return }
        if clearFirst { clearList() }
        if !routed.movies.isEmpty { addMovies(routed.movies) }
        if !routed.sheets.isEmpty { importSheets(routed.sheets) }
    }

    /// Adds movies as they are; files from outside go through `openFiles`.
    private func addMovies(_ urls: [URL]) {
        Task {
            var added: [MovieFile] = []
            for url in urls where url.isFileURL {
                let known = library.files + added
                if known.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    continue
                }
                do {
                    let backend = try await openMovie(url)
                    let info = backend.info
                    var file = MovieFile(
                        url: url, bookmark: Self.bookmark(for: url), duration: info.duration,
                        frameCount: info.frameCount, fps: info.fps, width: info.width,
                        height: info.height, size: info.size, fourCC: info.fourCC)
                    // Experimental (§10): IN/OUT from the first and last
                    // frames, before the default sheet is made between them.
                    if library.settings.automaticInOut {
                        do {
                            try await AutoInOut.apply(
                                to: &file, ffmpeg: await ffmpegTools(),
                                threshold: library.settings.automaticInOutThreshold)
                        } catch {
                            toast = "\(url.lastPathComponent): automatic IN/OUT failed: \(error.localizedDescription)"
                        }
                    }
                    added.append(file)
                    backends[file.id] = backend
                    linkedURLs[file.id] = url
                } catch {
                    toast = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            guard !added.isEmpty else { return }
            // One undo step for the whole drop; the first movie gets its
            // default sheet when nothing was selected.
            edit { library in
                library.files.append(contentsOf: added)
                if library.currentFileId == nil, let first = added.first {
                    Self.selectFile(first.id, in: &library)
                }
            }
            for file in added { loadPoster(file) }
            warmUpFaceDetection()
        }
    }

    /// Opens a movie and probes it: the one path for Add movies, import,
    /// Locate and Replace movie.
    private func openMovie(_ url: URL) async throws -> any DecodeBackend {
        let tools = await ffmpegTools()
        return try await DecoderRouter.open(
            url, ffmpeg: tools, exactFallback: library.settings.exactFramesWithFFmpeg)
    }

    /// Clear movie list (and Option-drop): one undo step; undo brings the
    /// movies back and `refreshLinks` checks them again.
    func clearList() {
        cancelScrub()
        edit { $0.removeAll() }
        backends = [:]
        linkedURLs = [:]
        missing = []
        cache.removeAll()
        pinned.removeAll()
        failed.removeAll()
        inexactImages.removeAll()
    }

    func removeMovie(_ fileId: UUID) {
        cancelScrub()
        edit { $0.removeFile(fileId) }
    }

    func revealInFinder(_ file: MovieFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Locate: points a missing movie at a file the user picks, then probes
    /// and opens it again.
    func locate(_ fileId: UUID) {
        guard let file = library.file(fileId) else { return }
        let panel = NSOpenPanel()
        panel.message = "Locate \(file.name)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = file.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relink(fileId, to: url)
    }

    /// Replace movie (MoviePrint's `onReplaceMovieListItemClick`): the entry
    /// takes another file and keeps its sheets; the same as Locate in effect.
    func replaceMovie(_ fileId: UUID) {
        guard let file = library.file(fileId) else { return }
        let panel = NSOpenPanel()
        panel.message = "Replace \(file.name)"
        panel.prompt = "Replace with"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = file.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relink(fileId, to: url)
    }

    /// Probes the new file, then relinks the entry and fills its probe data
    /// as one undo step (thumb frames kept, clamped to the new length); the
    /// cached thumbs are dropped and decoded again from the new file.
    private func relink(_ fileId: UUID, to url: URL) {
        guard !IncomingFiles.isSheetFile(url) else {
            toast = "\(url.lastPathComponent) is a sheet file, not a movie: use Import Sheet… to import it."
            return
        }
        Task {
            let backend: any DecodeBackend
            do {
                backend = try await openMovie(url)
            } catch {
                toast = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
            guard library.file(fileId) != nil else { return }
            cancelScrub()
            backends[fileId] = backend
            linkedURLs[fileId] = url
            missing.remove(fileId)
            forgetImages()
            // The stored scans were of the old file.
            scanStore?.delete(fileId)
            faceStore?.delete(fileId)
            scanData[fileId] = nil
            stoppedScans.remove(fileId)
            edit { library in
                library.relink(fileId, to: url, bookmark: Self.bookmark(for: url))
                library.applyProbe(fileId, info: backend.info)
                if let i = library.files.firstIndex(where: { $0.id == fileId }) { library.files[i].scanState = .none }
            }
            for file in library.files { loadPoster(file) }
        }
    }

    // MARK: - Import (§12)

    /// More options → Import Sheet…
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.message = "Import a PNG with embedded sheet data, or a JSON file, saved by FrameSheet or MoviePrint"
        panel.allowedContentTypes = [.png, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        openFiles(panel.urls)
    }

    /// Reads PNGs and JSON files from FrameSheet or MoviePrint 0.2.x: each
    /// becomes a new movie entry with an interval sheet in grid view, or a
    /// shot sheet in timeline view for a scene list (MoviePrint's
    /// `onImportMoviePrint`), all in one undo step. A movie that exists is
    /// probed like Add movies; one that does not shows as missing, for
    /// Locate.
    private func importSheets(_ urls: [URL]) {
        Task {
            var errors: [String] = []
            var found: [(id: UUID, name: String, data: SheetExchange, backend: (any DecodeBackend)?, missing: Bool)] = []
            for url in urls where url.isFileURL {
                let name = url.lastPathComponent
                let data: SheetExchange
                do {
                    data = try SheetExchange(fileData: try Data(contentsOf: url))
                } catch {
                    errors.append("\(name): \(Self.importMessage(error))")
                    continue
                }
                guard let path = data.filePath, !path.isEmpty else {
                    errors.append("\(name): \(Self.importMessage(SheetExchangeError.noFilePath))")
                    continue
                }
                let movie = URL(fileURLWithPath: path)
                var backend: (any DecodeBackend)?
                let exists = FileManager.default.fileExists(atPath: movie.path)
                if exists {
                    do {
                        backend = try await openMovie(movie)
                    } catch {
                        errors.append("\(movie.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                found.append((UUID(), name, data, backend, !exists))
            }
            if !found.isEmpty {
                cancelScrub()
                for item in found {
                    if let backend = item.backend {
                        backends[item.id] = backend
                        linkedURLs[item.id] = URL(fileURLWithPath: item.data.filePath ?? "")
                    }
                    if item.missing { missing.insert(item.id) }
                }
                edit { library in
                    for item in found {
                        guard (try? library.importSheet(item.data, fileId: item.id)) != nil else { continue }
                        guard let backend = item.backend, let file = library.file(item.id) else { continue }
                        library.relink(item.id, to: file.url, bookmark: Self.bookmark(for: file.url))
                        library.applyProbe(item.id, info: backend.info)
                    }
                }
                for item in found { if let file = library.file(item.id) { loadPoster(file) } }
                showNotice(found.count == 1 ? "Imported \(found[0].name)" : "Imported \(found.count) sheets")
            }
            if !errors.isEmpty { toast = errors.joined(separator: "\n") }
        }
    }

    private static func importMessage(_ error: any Error) -> String {
        switch error {
        case SheetExchangeError.noData: "no sheet data found or embedded."
        case SheetExchangeError.noFilePath: "the data names no movie file."
        case SheetExchangeError.invalidJSON: "not a FrameSheet or MoviePrint JSON file."
        case PNGText.Error.invalidPNG: "the PNG could not be read."
        default: error.localizedDescription
        }
    }

    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Follows the bookmark if the file moved; marks the movie missing if
    /// it cannot be found.
    private static func resolveBookmark(at index: Int, in library: inout Library, missing: inout Set<UUID>) {
        let file = library.files[index]
        if let data = file.bookmark {
            var stale = false
            let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale))
            if let url {
                _ = url.startAccessingSecurityScopedResource()
                if url != file.url {
                    library.files[index].url = url
                    library.files[index].name = url.lastPathComponent
                    library.files[index].folder = url.deletingLastPathComponent().path
                }
                if stale { library.files[index].bookmark = bookmark(for: url) }
            }
        }
        if !FileManager.default.fileExists(atPath: library.files[index].url.path) {
            missing.insert(file.id)
        }
    }

    /// Whether a movie is still where its entry says; a cheap check (no
    /// probe) after a decode failure and on selecting a movie or sheet. A
    /// file that is not at its URL is looked up by its bookmark as on launch:
    /// when the bookmark finds it elsewhere, the entry follows (not undoable,
    /// like launch) and its images are decoded again; when it is gone, the
    /// movie is marked missing (Locate in the movie list) and its backend
    /// dropped. Returns false in both cases, so the caller shows no
    /// decode-failure toast.
    @discardableResult
    func checkMovieFile(_ fileId: UUID) -> Bool {
        guard let i = library.files.firstIndex(where: { $0.id == fileId }) else { return false }
        guard !missing.contains(fileId) else { return false }
        if FileManager.default.fileExists(atPath: library.files[i].url.path) { return true }
        var resolved = library
        var gone: Set<UUID> = []
        Self.resolveBookmark(at: i, in: &resolved, missing: &gone)
        backends[fileId] = nil
        if scrub?.ref.fileId == fileId { cancelScrub() }
        if gone.contains(fileId) {
            missing.insert(fileId)
        } else {
            let moved = resolved.files[i]
            linkedURLs[fileId] = moved.url
            forgetImages()
            update { $0.files[i] = moved }
            for file in library.files { loadPoster(file) }
        }
        return false
    }

    // MARK: - Selection

    func select(file id: UUID) {
        guard library.file(id) != nil else { return }
        checkMovieFile(id)
        update { Self.selectFile(id, in: &$0) }
        warmUpFaceDetection()
    }

    /// Selects a movie and its first sheet, adding the default interval
    /// sheet when it has none (§5).
    private static func selectFile(_ id: UUID, in library: inout Library) {
        library.currentFileId = id
        if (library.sheets[id] ?? []).isEmpty { library.addDefaultIntervalSheet(to: id) }
        library.currentSheetId = library.sheets[id]?.first?.id
    }

    func select(sheet sheetId: UUID, of fileId: UUID) {
        cancelScrub()
        checkMovieFile(fileId)
        update {
            $0.currentFileId = fileId
            $0.currentSheetId = sheetId
        }
    }

    // MARK: - Sheets

    func backToParent() {
        guard let ref = currentRef, let parent = currentSheet?.parentSheetId,
              library.sheet(parent, of: ref.fileId) != nil
        else { return }
        select(sheet: parent, of: ref.fileId)
    }

    func addIntervalSheet(columns: Int, rows: Int) {
        guard let fileId = library.currentFileId else { return }
        edit { library in
            if let sheet = library.addIntervalSheet(to: fileId, columns: columns, rows: rows) {
                library.currentSheetId = sheet.id
            }
        }
    }

    func duplicateSheet(_ ref: SheetRef) {
        edit { library in
            if let copy = library.duplicateSheet(ref) {
                library.currentFileId = copy.fileId
                library.currentSheetId = copy.sheetId
            }
        }
    }

    func renameSheet(_ ref: SheetRef, to name: String) {
        edit { $0.renameSheet(ref, to: name) }
    }

    func deleteSheet(_ ref: SheetRef) {
        cancelScrub()
        edit { $0.deleteSheet(ref) }
    }

    // MARK: - Grid

    /// Columns slider: live while dragging, one undo step when released.
    func setColumnsLive(_ columns: Int, editing: Bool) {
        guard let ref = currentRef, let sheet = currentSheet else { return }
        if editing {
            if columnsAtDragStart == nil { columnsAtDragStart = sheet.columnCount }
            update { $0.setColumns(ref, columns) }
        } else {
            edit { $0.setColumns(ref, columns) }
        }
    }

    func endColumnsDrag() {
        guard let start = columnsAtDragStart, let ref = currentRef, let sheet = currentSheet else {
            columnsAtDragStart = nil
            return
        }
        columnsAtDragStart = nil
        let final = sheet.columnCount
        update { $0.setColumns(ref, start) }
        edit { $0.setColumns(ref, final) }
    }

    /// Recaptures columns × rows thumbs as one undo step and clears the
    /// target rows.
    func applyThumbCount(columns: Int, rows: Int) {
        guard let ref = currentRef else { return }
        edit { $0.applyThumbCount(ref, columns: columns, rows: rows) }
        rowsTarget = nil
    }

    /// Rows the sheet's visible thumbs fill at its columns.
    static func neededRows(of sheet: Sheet) -> Int {
        max(1, GridLayout.rows(columns: sheet.columnCount, thumbCount: sheet.visibleThumbs.count))
    }

    /// Target rows of the sheet: set by the Rows slider, else the rows its
    /// thumbs fill. Never reloads; Replace applies it.
    func targetRows(of sheet: Sheet) -> Int {
        if let target = rowsTarget, target.sheetId == sheet.id, target.columns == sheet.columnCount {
            return target.rows
        }
        return Self.neededRows(of: sheet)
    }

    /// Whether the Rows slider holds a target for the sheet.
    func hasRowsTarget(_ sheet: Sheet) -> Bool {
        targetRows(of: sheet) != Self.neededRows(of: sheet)
    }

    func setTargetRows(_ rows: Int) {
        guard let sheet = currentSheet else { return }
        rowsTarget = (sheet.id, sheet.columnCount, max(1, rows))
    }

    /// Cells of the grid: the shown thumbs, plus empty placeholders up to
    /// columns × target rows.
    func gridCellCount(of sheet: Sheet) -> Int {
        max(shownThumbs(of: sheet).count, sheet.columnCount * targetRows(of: sheet))
    }

    func optimizeGrid() {
        guard let ref = currentRef else { return }
        edit { $0.optimizeGrid(ref) }
    }

    func zoom(in zoomIn: Bool) { zoom = GridLayout.zoom(from: zoom, in: zoomIn) }
    func zoomToFit() { zoom = 1 }

    /// Layout of the current sheet in the main area at the current zoom, in
    /// grid or timeline view; nil while no sheet is shown or the area is not
    /// laid out yet.
    var currentFit: (any PrintFit)? {
        guard let file = currentFile, let sheet = currentSheet,
              mainAreaSize.width > 0, mainAreaSize.height > 0
        else { return nil }
        if isTimeline(sheet) {
            return timelineGeometry(file: file, sheet: sheet, size: mainAreaSize)
        }
        return SheetGridView.geometry(
            file: file, columns: sheet.columnCount, thumbCount: gridCellCount(of: sheet),
            settings: library.settings, size: mainAreaSize, zoom: zoom)
    }

    /// The print's height fills the main area (it may scroll sideways).
    func zoomToFitHeight() {
        if let fit = currentFit { zoom = Self.clampedZoom(fit.zoomFillingHeight) }
    }

    /// The print's width fills the main area (it may scroll up and down).
    func zoomToFitWidth() {
        if let fit = currentFit { zoom = Self.clampedZoom(fit.zoomFillingWidth) }
    }

    // MARK: - Timeline (§6, §10)

    /// The sheet is drawn as a timeline (faces sheets stay grids).
    func isTimeline(_ sheet: Sheet) -> Bool { sheet.view == .timeline && sheet.type != .faces }

    /// The scenes a sheet shows in timeline view, hidden ones with Show
    /// hidden thumbs.
    func timelineScenes(of sheet: Sheet) -> [FrameSheetCore.Scene] {
        SceneList.timelineScenes(of: sheet, includeHidden: library.settings.showHiddenThumbs)
    }

    /// The timeline layout of a sheet in an area of `size` at the current
    /// zoom; the selected scene is drawn at full aspect width.
    func timelineGeometry(file: MovieFile, sheet: Sheet, size: CGSize) -> TimelineGeometry {
        let scenes = timelineScenes(of: sheet)
        let selected = selectedThumbId.flatMap { id in scenes.firstIndex { $0.id == id } }
        return SheetGridView.timelineGeometry(
            file: file, sheet: sheet, scenes: scenes, settings: library.settings, size: size, zoom: zoom,
            expandedIndex: selected)
    }

    /// Grid ↔ timeline (sheet menu, toolbar, key G); faces sheets stay grids.
    func toggleView(_ ref: SheetRef) {
        guard let sheet = library.sheet(ref.sheetId, of: ref.fileId) else { return }
        cancelScrub()
        edit { $0.setView(ref, sheet.view == .grid ? .timeline : .grid) }
    }

    func convertToInterval(_ ref: SheetRef) {
        edit { $0.convertToInterval(ref) }
    }

    /// Minutes per row slider: live while dragging, one undo step when
    /// released.
    func setSecondsPerRowLive(_ seconds: Double, editing: Bool) {
        guard let ref = currentRef, let sheet = currentSheet else { return }
        if editing {
            if secondsPerRowAtDragStart == nil { secondsPerRowAtDragStart = sheet.secondsPerRow }
            update { $0.setSecondsPerRow(ref, seconds) }
        } else {
            edit { $0.setSecondsPerRow(ref, seconds) }
        }
    }

    func endSecondsPerRowDrag() {
        guard let start = secondsPerRowAtDragStart, let ref = currentRef, let sheet = currentSheet else {
            secondsPerRowAtDragStart = nil
            return
        }
        secondsPerRowAtDragStart = nil
        let final = sheet.secondsPerRow
        update { $0.setSecondsPerRow(ref, start) }
        edit { $0.setSecondsPerRow(ref, final) }
    }

    private static func clampedZoom(_ zoom: Double) -> Double {
        min(max(zoom, GridGeometry.zoomSteps.first!), GridGeometry.zoomSteps.last!)
    }

    func cycleFrameInfo() {
        updateSettings { $0.frameInfo = FrameInfoText.next(after: $0.frameInfo) }
    }

    // MARK: - Thumbs (§7)

    func expand(_ thumb: UUID) {
        guard let ref = currentRef else { return }
        cancelScrub()
        edit { library in
            if let child = library.expand(ref, thumb: thumb) {
                library.currentSheetId = child.sheetId
            }
        }
    }

    /// Hide/Show; after hiding, the next visible thumb is selected (grid).
    /// In the timeline the selection stays, except on the scene hidden.
    func toggleHidden(_ thumb: UUID) {
        guard let ref = currentRef, let sheet = currentSheet else { return }
        let hiding = sheet.thumbs.first { $0.id == thumb }?.hidden == false
        edit { $0.toggleHidden(ref, thumb: thumb) }
        guard hiding else { return }
        if isTimeline(sheet) {
            if selectedThumbId == thumb { selectedThumbId = nil }
        } else {
            selectedThumbId = currentSheet?.selectionAfterHiding(thumb)
        }
    }

    /// IN / OUT: on interval sheets recapture between this thumb and the
    /// other end; with Option, or on other sheet types, hide all before or
    /// after it.
    func setInOut(_ position: InsertPosition, thumb: UUID, option: Bool) {
        guard let ref = currentRef, let sheet = currentSheet else { return }
        if option || sheet.type != .interval {
            edit { $0.hideAll(ref, position, of: thumb) }
        } else if position == .before {
            edit { $0.setIn(ref, thumb: thumb) }
        } else {
            edit { $0.setOut(ref, thumb: thumb) }
        }
    }

    func insertThumb(_ position: InsertPosition, relativeTo thumb: UUID) {
        guard let ref = currentRef else { return }
        if let id = edit({ $0.insertThumb(ref, relativeTo: thumb, position) }) { selectedThumbId = id }
    }

    /// Drag reorder: `dragged` lands before or after `target`.
    func moveThumb(_ dragged: UUID, onto target: UUID, after: Bool) {
        guard let ref = currentRef, let sheet = currentSheet, dragged != target,
              sheet.type != .shot,
              sheet.thumbs.contains(where: { $0.id == dragged }),
              let t = sheet.thumbs.firstIndex(where: { $0.id == target })
        else { return }
        edit { $0.moveThumb(ref, thumb: dragged, to: after ? t + 1 : t) }
        selectedThumbId = dragged
    }

    /// ⇧⌥← / ⇧⌥→.
    func selectAdjacentThumb(_ step: Int) {
        guard let sheet = currentSheet else { return }
        selectedThumbId = sheet.visibleThumb(from: selectedThumbId, step: step)
    }

    // MARK: - Scrub (§7)

    /// Starts a scrub of `thumb`; `keyboard` scrubs step with the arrows and
    /// keep the action the modifiers chose at the start.
    func beginScrub(_ thumb: UUID, keyboard: Bool, modifiers: ScrubModifiers, x: Double = 0, y: Double = 0) {
        guard let ref = currentRef, let sheet = currentSheet, let file = currentFile,
              let own = sheet.thumbs.first(where: { $0.id == thumb })
        else { return }
        let layout = scrubLayout(for: file)
        // A drag starts at the thumb's frame where the handle was pressed.
        let pressX = keyboard ? nil : x
        let mapping: ScrubMapping
        var modifiers = modifiers
        if sheet.type == .shot {
            // Shot sheets keep one thumb per scene: the scrub stays inside
            // the thumb's scene and always changes it (§7).
            guard let scene = sheet.scenes.first(where: { $0.id == thumb }) else { return }
            mapping = .scene(
                scene, thumbFrame: own.frameNumber, frameCount: file.frameCount, liveMinX: layout.live.minX,
                liveMaxX: layout.live.maxX, containerWidth: mainAreaSize.width, pressX: pressX)
            modifiers = []
        } else {
            let (left, right) = sheet.visibleNeighbors(of: thumb)
            mapping = ScrubMapping(
                thumbFrame: own.frameNumber, leftFrame: left, rightFrame: right, frameCount: file.frameCount,
                liveMinX: layout.live.minX, liveMaxX: layout.live.maxX, containerWidth: mainAreaSize.width,
                pressX: pressX)
        }
        selectedThumbId = thumb
        scrub = ScrubSession(
            ref: ref, thumbId: thumb, mapping: mapping, frame: mapping.thumbFrame,
            modifiers: modifiers, keyboard: keyboard, lastX: x, lastY: y)
        if let image = cachedImage(file: file.id, frame: own.frameNumber, width: Self.thumbWidth) {
            showScrub(
                image, requested: own.frameNumber,
                actual: shownFrame(file: file.id, frame: own.frameNumber, width: Self.thumbWidth))
        } else {
            scrubImage = nil
            scrubShown = nil
        }
        if !keyboard { scrubMoved(x: x, y: y, modifiers: modifiers) }
        requestScrubFrame(scrub?.frame ?? own.frameNumber)
    }

    func scrubLayout(for file: MovieFile) -> ScrubLayout {
        let ratio = file.transform.aspectRatioInv
            ?? (file.width > 0 ? Double(file.height) / Double(file.width) : 9.0 / 16.0)
        return ScrubLayout(
            containerWidth: mainAreaSize.width, containerHeight: mainAreaSize.height, aspectRatioInv: ratio)
    }

    /// Pointer moved (x, y in the main area's coordinates).
    func scrubMoved(x: Double, y: Double, modifiers: ScrubModifiers) {
        guard var session = scrub, !session.keyboard else { return }
        session.modifiers = session.sceneLimited ? [] : modifiers
        session.lastX = x
        session.lastY = y
        session.overCancel = y < ScrubLayout.cancelBarHeight
        session.frame = session.mapping.frame(atX: x, modifiers: modifiers)
        let changed = session.frame != scrub?.frame
        scrub = session
        if changed { requestScrubFrame(session.frame) }
    }

    /// Modifier keys changed while dragging.
    func scrubModifiersChanged(_ modifiers: ScrubModifiers) {
        guard let session = scrub, !session.keyboard, !session.sceneLimited, session.modifiers != modifiers else { return }
        scrubMoved(x: session.lastX, y: session.lastY, modifiers: modifiers)
    }

    /// ← / → in a keyboard scrub; Shift steps by 10.
    func scrubStep(_ delta: Int) {
        guard var session = scrub, session.keyboard else { return }
        let range = session.mapping.keyboardRange(modifiers: session.modifiers)
        session.frame = min(max(session.frame + delta, range.lowerBound), range.upperBound)
        guard session.frame != scrub?.frame else { return }
        scrub = session
        requestScrubFrame(session.frame)
    }

    /// The handle's mouse-up. Released within a second of pressing it, the
    /// scrub stays open and follows the pointer until a click (MoviePrint's
    /// `scrubWindowTriggerTime`); otherwise it confirms.
    func releaseScrub() {
        guard var session = scrub, !session.keyboard, !session.sticky else { return }
        if Date().timeIntervalSince(session.startedAt) < 1, !session.overCancel {
            session.sticky = true
            scrub = session
        } else {
            endScrub()
        }
    }

    /// Release (or Return, or a click in a sticky scrub) confirms with one
    /// undo step; over the Cancel bar it cancels. A frame that does not
    /// decode exactly is not stored (the thumb keeps its frame) and the toast
    /// says so; one the preview has not decoded yet is decoded first.
    func endScrub() {
        guard let session = scrub else { return }
        let exact = scrubExact[session.frame]
        cancelScrub()
        guard !session.overCancel else { return }
        switch exact {
        case true?:
            applyScrub(session)
        case false?:
            refuseScrub(session)
        case nil:
            Task {
                guard let file = library.file(session.ref.fileId) else { return }
                do {
                    let backend = try await backend(for: file)
                    let decoded = try await backend.frame(session.frame, maxWidth: Self.thumbWidth)
                    if decoded.isExact {
                        store(decoded.image, file: file.id, frame: decoded.actualFrame, width: Self.thumbWidth)
                        inexactImages[ImageKey(file: file.id, frame: decoded.actualFrame, width: Self.thumbWidth)] = nil
                        applyScrub(session)
                    } else {
                        refuseScrub(session)
                    }
                } catch {
                    // Not decodable at all: stored as before; loading the
                    // thumb reports the failure.
                    applyScrub(session)
                }
            }
        }
    }

    private func applyScrub(_ session: ScrubSession) {
        let id = edit { $0.applyScrub(session.ref, thumb: session.thumbId, frame: session.frame, action: session.action) }
        selectedThumbId = id ?? session.thumbId
    }

    /// The confirmed frame did not decode exactly: nothing changes.
    private func refuseScrub(_ session: ScrubSession) {
        let kept = library.sheet(session.ref.sheetId, of: session.ref.fileId)?
            .thumbs.first { $0.id == session.thumbId }?.frameNumber
        toast = "Frame \(session.frame) could not be decoded exactly"
            + (kept.map { ", so the thumb keeps frame \($0)" } ?? "")
            + " (\(exactFrameHint))."
    }

    func cancelScrub() {
        scrub = nil
        scrubImage = nil
        scrubShown = nil
        scrubPending = nil
        scrubFrames.removeAll()
        scrubExact.removeAll()
    }

    /// Width the live frame is decoded at: its on-screen pixels, in steps of
    /// 128 so nearby sizes share cache entries.
    private var scrubDecodeWidth: Int {
        guard let file = currentFile else { return Self.thumbWidth }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = scrubLayout(for: file).live.width * scale
        let stepped = Int((pixels / 128).rounded(.up)) * 128
        return max(Self.thumbWidth, min(stepped, max(Self.thumbWidth, file.width)))
    }

    private func showScrub(_ image: CGImage, requested: Int, actual: Int) {
        scrubImage = image
        scrubShown = (requested, actual)
    }

    /// Newest request wins: one decode in flight, and the latest position
    /// is decoded next.
    private func requestScrubFrame(_ frame: Int) {
        scrubPending = frame
        guard scrubDecode == nil else { return }
        scrubDecode = Task {
            defer { scrubDecode = nil }
            while let frame = scrubPending, let session = scrub, let file = library.file(session.ref.fileId) {
                scrubPending = nil
                let width = scrubDecodeWidth
                let key = Self.loadingKey(file.id, frame, width)
                if let cached = scrubFrames.first(where: { $0.key == key }) {
                    showScrub(cached.image, requested: frame, actual: cached.actual)
                    continue
                }
                if let thumb = cachedImage(file: file.id, frame: frame, width: Self.thumbWidth),
                   scrubExact[frame] != false {
                    showScrub(
                        thumb, requested: frame,
                        actual: shownFrame(file: file.id, frame: frame, width: Self.thumbWidth))
                }
                guard let backend = try? await backend(for: file),
                      let decoded = try? await backend.frame(frame, maxWidth: width)
                else { continue }
                if scrub?.thumbId == session.thumbId { scrubExact[frame] = decoded.isExact }
                scrubFrames.removeAll { $0.key == key }
                scrubFrames.append((key, decoded.image, decoded.actualFrame))
                if scrubFrames.count > Self.scrubFrameLimit { scrubFrames.removeFirst() }
                if scrub?.thumbId == session.thumbId {
                    showScrub(decoded.image, requested: frame, actual: decoded.actualFrame)
                }
            }
        }
    }

    // MARK: - Thumbnails

    /// The movie's backend if it is open (no probe).
    func openBackend(_ fileId: UUID) -> (any DecodeBackend)? { backends[fileId] }

    func backend(for file: MovieFile) async throws -> any DecodeBackend {
        if let backend = backends[file.id] { return backend }
        guard !missing.contains(file.id) else { throw DecodeError("Movie is missing") }
        let backend = try await openMovie(file.url)
        backends[file.id] = backend
        linkedURLs[file.id] = file.url
        return backend
    }

    func cachedImage(file: UUID, frame: Int, width: Int) -> CGImage? {
        pinned[Self.loadingKey(file, frame, width)] ?? cache.image(file: file, frame: frame, width: width)
    }

    /// Caches a decoded image, and pins it when it is on screen. A window
    /// thumb records the width it was decoded for (`decodedFor`).
    private func store(_ image: CGImage, file: UUID, frame: Int, width: Int, decodedFor: Int? = nil) {
        cache.insert(image, file: file, frame: frame, width: width)
        if width == Self.thumbWidth { thumbWidths[Self.loadingKey(file, frame, width)] = decodedFor ?? width }
        let onScreen = width == Self.posterWidth
            || (width == Self.thumbWidth && file == library.currentFileId)
        if onScreen { pinned[Self.loadingKey(file, frame, width)] = image }
    }

    /// Keeps only the posters and the current sheet's thumbs pinned, and
    /// pins the current sheet's thumbs that are cached (also those a face
    /// scan made), so the cache's limit cannot drop what is on screen.
    private func prunePinned() {
        var keep = Set(library.files.map { Self.loadingKey($0.id, $0.posterFrame, Self.posterWidth) })
        if let file = currentFile, let sheet = currentSheet {
            for thumb in sheet.thumbs {
                let key = Self.loadingKey(file.id, thumb.frameNumber, Self.thumbWidth)
                keep.insert(key)
                if pinned[key] == nil,
                   let image = cache.image(file: file.id, frame: thumb.frameNumber, width: Self.thumbWidth) {
                    pinned[key] = image
                }
            }
        }
        pinned = pinned.filter { keep.contains($0.key) }
    }

    func loadCurrentSheet() {
        decodeWidthMemo = nil
        prunePinned()
        guard let file = currentFile, let sheet = currentSheet, !isStreamingSheetShown else { return }
        load(frames: sheet.thumbs.map(\.frameNumber), of: file, width: Self.thumbWidth, sheetId: sheet.id)
    }

    /// Pixel width the current sheet's thumbs are decoded at: their size
    /// in the grid at the current zoom, rounded up to a step
    /// (`ThumbnailWidth`); the widest in timeline view (a selected scene
    /// widens) and before the main area is laid out. Nil without a sheet.
    var currentThumbDecodeWidth: Int? {
        guard let file = currentFile, let sheet = currentSheet else { return nil }
        guard !isTimeline(sheet), mainAreaSize.width > 0, mainAreaSize.height > 0 else {
            return min(Self.thumbWidth, max(1, file.width))
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = DecodeWidthKey(
            sheet: sheet.id, columns: sheet.columnCount, cells: sheet.thumbs.count, area: mainAreaSize, zoom: zoom,
            scale: scale)
        if let memo = decodeWidthMemo, memo.key == key { return memo.width }
        let geometry = SheetGridView.geometry(
            file: file, columns: sheet.columnCount, thumbCount: gridCellCount(of: sheet),
            settings: library.settings, size: mainAreaSize, zoom: zoom)
        let width = ThumbnailWidth.decodeWidth(points: geometry.thumbWidth, scale: scale, movieWidth: file.width)
        decodeWidthMemo = (key, width)
        return width
    }

    /// The width a cached window thumb was decoded or made for.
    private func decodedWidth(_ file: UUID, _ frame: Int) -> Int {
        thumbWidths[Self.loadingKey(file, frame, Self.thumbWidth)] ?? Self.thumbWidth
    }

    /// A frame a running face scan will analyze, asked for by a faces sheet
    /// of the movie it scans: it waits for the scan's thumbnail.
    private func awaitsFaceScan(_ file: UUID, _ frame: Int) -> Bool {
        guard let scan = faceScanFrames, scan.fileId == file, file == library.currentFileId,
              currentSheet?.type == .faces
        else { return false }
        return scan.frames.contains(frame)
    }

    /// A thumbnail the face scan made from the frame it analyzed (exact),
    /// cached like a decoded thumb at the width it was made for; a wider one
    /// already cached is kept. Views are told once the scan ends.
    func storeScanThumbnail(_ image: CGImage, file: UUID, frame: Int, width: Int) {
        let key = Self.loadingKey(file, frame, Self.thumbWidth)
        if cachedImage(file: file, frame: frame, width: Self.thumbWidth) != nil, decodedWidth(file, frame) >= width {
            return
        }
        cache.insert(image, file: file, frame: frame, width: Self.thumbWidth)
        thumbWidths[key] = width
        inexactImages[ImageKey(file: file, frame: frame, width: Self.thumbWidth)] = nil
        if pinned[key] != nil { pinned[key] = image }
    }

    /// Images landed in the cache outside `load`: views read them again.
    func thumbnailsChanged() {
        imageGeneration += 1
    }

    private func loadPoster(_ file: MovieFile) {
        load(frames: [file.posterFrame], of: file, width: Self.posterWidth, sheetId: nil)
    }

    /// Decodes the frames not yet cached. When the ±0.5 s retry returns
    /// another frame, the thumb takes that frame number (decision 11).
    private func load(frames: [Int], of file: MovieFile, width: Int, sheetId: UUID?) {
        // Window thumbs of the current movie at the current sheet's size.
        let decodeWidth = width == Self.thumbWidth && file.id == library.currentFileId
            ? currentThumbDecodeWidth ?? width : width
        let wanted = Array(Set(frames)).filter {
            guard !loading.contains(Self.loadingKey(file.id, $0, width)) else { return false }
            if width == Self.thumbWidth, awaitsFaceScan(file.id, $0) { return false }
            guard cachedImage(file: file.id, frame: $0, width: width) != nil else { return true }
            return width == Self.thumbWidth && decodedWidth(file.id, $0) < decodeWidth
        }
        guard !wanted.isEmpty, !missing.contains(file.id) else { return }
        for frame in wanted { loading.insert(Self.loadingKey(file.id, frame, width)) }
        Task {
            defer { for frame in wanted { loading.remove(Self.loadingKey(file.id, frame, width)) } }
            let backend: any DecodeBackend
            do {
                backend = try await self.backend(for: file)
            } catch {
                for frame in wanted { loading.remove(Self.loadingKey(file.id, frame, width)) }
                if checkMovieFile(file.id) { toast = "\(file.name): \(error.localizedDescription)" }
                return
            }
            var failures = 0
            for await result in backend.frames(wanted, maxWidth: decodeWidth) {
                switch result.result {
                case .success(let frame):
                    store(frame.image, file: file.id, frame: frame.actualFrame, width: width, decodedFor: decodeWidth)
                    // Also under the requested frame, so a view asking for it
                    // finds it even before the thumb is retargeted (otherwise
                    // the reload-on-miss in `image` would loop).
                    store(
                        frame.image, file: file.id, frame: frame.requestedFrame, width: width,
                        decodedFor: decodeWidth)
                    inexactImages[ImageKey(file: file.id, frame: frame.actualFrame, width: width)] = nil
                    if !frame.isExact {
                        inexactImages[ImageKey(file: file.id, frame: frame.requestedFrame, width: width)] = frame.actualFrame
                    }
                    if frame.actualFrame != frame.requestedFrame, let sheetId {
                        retarget(file.id, sheet: sheetId, from: frame.requestedFrame, to: frame.actualFrame)
                    }
                    imageGeneration += 1
                case .failure:
                    failed.insert(Self.loadingKey(file.id, result.frameNumber, width))
                    failures += 1
                }
            }
            guard failures > 0 else { return }
            // A moved or deleted file shows as missing in the movie list
            // instead; done loading first, so a followed file decodes again.
            for frame in wanted { loading.remove(Self.loadingKey(file.id, frame, width)) }
            if checkMovieFile(file.id) { toast = "\(file.name): \(failures) frame(s) could not be decoded." }
        }
    }

    /// Moves thumbs to the frame the retry decoded; a correction, not an
    /// edit, so it records no undo step. The moved thumbs get the marker.
    private func retarget(_ fileId: UUID, sheet sheetId: UUID, from: Int, to: Int) {
        guard let s = library.sheets[fileId]?.firstIndex(where: { $0.id == sheetId }) else { return }
        for thumb in library.sheets[fileId]![s].thumbs where thumb.frameNumber == from {
            // A thumb moved twice keeps the frame it first asked for.
            let requested = nearestFrame(of: thumb) ?? from
            nearestThumbs[thumb.id] = (requested, to)
        }
        update { library in
            for t in library.sheets[fileId]![s].thumbs.indices
            where library.sheets[fileId]![s].thumbs[t].frameNumber == from {
                library.sheets[fileId]![s].thumbs[t].frameNumber = to
            }
        }
    }

    private static func loadingKey(_ file: UUID, _ frame: Int, _ width: Int) -> String {
        "\(file)/\(frame)/\(width)"
    }

    // MARK: - Persistence

    /// Saves half a second after the last change (§12).
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard let store else { return }
        do {
            try store.save(library)
        } catch {
            toast = "The movie list could not be saved: \(error.localizedDescription)"
        }
    }
}
