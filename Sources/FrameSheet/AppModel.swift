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
    /// Size of the main area, where the scrub overlay is drawn; the grid
    /// fills it.
    var mainAreaSize: CGSize = .zero

    /// Width thumbs are decoded at; enough for a 4-column grid on a
    /// Retina display.
    static let thumbWidth = 640
    static let posterWidth = 320

    let cache: ThumbnailCache
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
    /// Target rows set by the Rows slider for one sheet at one column count;
    /// not persisted, and void once the sheet or its columns change.
    private var rowsTarget: (sheetId: UUID, columns: Int, rows: Int)?
    @ObservationIgnored private var scrubPending: Int?
    /// Live scrub frames, kept apart from `cache`: display-size frames are
    /// several MB each, and filling the shared cache with them evicted the
    /// grid's thumbs, which then redrew. Only the most recent ones are kept.
    @ObservationIgnored private var scrubFrames: [(key: String, image: CGImage)] = []
    private static let scrubFrameLimit = 16
    @ObservationIgnored private var scrubDecode: Task<Void, Never>?

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
        self.missing = missing
        document = EditableLibrary(loaded)
        cache = ThumbnailCache(limitMB: loaded.settings.thumbnailCacheMB)
        toast = loadError
        findFFmpeg()
        for file in library.files { loadPoster(file) }
        loadCurrentSheet()
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
        if let image = cachedImage(file: file, frame: frame, width: width) { return image }
        // NSCache may have evicted it (cost limit or memory pressure): decode
        // it again, outside the view update that asked for it.
        let key = Self.loadingKey(file, frame, width)
        let now = Date()
        // At most one reload per image every 2 s, so a frame that never lands
        // under this key cannot turn redraws into a decode loop.
        if !loading.contains(key) && !failed.contains(key)
            && now.timeIntervalSince(lastReload[key] ?? .distantPast) > 2 {
            lastReload[key] = now
            Task { [weak self] in
                guard let self, let movie = library.file(file) else { return }
                load(frames: [frame], of: movie, width: width, sheetId: nil)
            }
        }
        return nil
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
    func setFFmpegPath(_ path: String?) {
        updateSettings { $0.ffmpegPath = path }
        backends = backends.filter { $0.value.kind != .ffmpeg }
        findFFmpeg()
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

    private func ffmpegTools() async -> FFmpegTools? {
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
                    let file = MovieFile(
                        url: url, bookmark: Self.bookmark(for: url), duration: info.duration,
                        frameCount: info.frameCount, fps: info.fps, width: info.width,
                        height: info.height, size: info.size, fourCC: info.fourCC)
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
        }
    }

    /// Opens a movie and probes it: the one path for Add movies, import,
    /// Locate and Replace movie.
    private func openMovie(_ url: URL) async throws -> any DecodeBackend {
        try await DecoderRouter.open(url, ffmpeg: await ffmpegTools())
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
            edit { library in
                library.relink(fileId, to: url, bookmark: Self.bookmark(for: url))
                library.applyProbe(fileId, info: backend.info)
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
    /// becomes a new movie entry with an interval sheet (MoviePrint's
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
                guard !(data.frameNumbers ?? []).isEmpty else {
                    errors.append("\(name): shot sheets come with T05.")
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

    /// Layout of the current sheet in the main area at the current zoom;
    /// nil while no sheet is shown or the area is not laid out yet.
    var currentGridGeometry: GridGeometry? {
        guard let file = currentFile, let sheet = currentSheet,
              mainAreaSize.width > 0, mainAreaSize.height > 0
        else { return nil }
        return SheetGridView.geometry(
            file: file, columns: sheet.columnCount, thumbCount: gridCellCount(of: sheet),
            settings: library.settings, size: mainAreaSize, zoom: zoom)
    }

    /// The print's height fills the grid area (it may scroll sideways).
    func zoomToFitHeight() {
        if let geometry = currentGridGeometry { zoom = Self.clampedZoom(geometry.zoomFillingHeight) }
    }

    /// The print's width fills the grid area (it may scroll up and down).
    func zoomToFitWidth() {
        if let geometry = currentGridGeometry { zoom = Self.clampedZoom(geometry.zoomFillingWidth) }
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

    /// Hide/Show; after hiding, the next visible thumb is selected.
    func toggleHidden(_ thumb: UUID) {
        guard let ref = currentRef, let sheet = currentSheet else { return }
        let hiding = sheet.thumbs.first { $0.id == thumb }?.hidden == false
        edit { $0.toggleHidden(ref, thumb: thumb) }
        if hiding { selectedThumbId = currentSheet?.selectionAfterHiding(thumb) }
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
        let (left, right) = sheet.visibleNeighbors(of: thumb)
        let layout = scrubLayout(for: file)
        let mapping = ScrubMapping(
            thumbFrame: own.frameNumber, leftFrame: left, rightFrame: right, frameCount: file.frameCount,
            liveMinX: layout.live.minX, liveMaxX: layout.live.maxX, containerWidth: mainAreaSize.width)
        selectedThumbId = thumb
        scrub = ScrubSession(
            ref: ref, thumbId: thumb, mapping: mapping, frame: own.frameNumber,
            modifiers: modifiers, keyboard: keyboard, lastX: x, lastY: y)
        scrubImage = cachedImage(file: file.id, frame: own.frameNumber, width: Self.thumbWidth)
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
        session.modifiers = modifiers
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
        guard let session = scrub, !session.keyboard, session.modifiers != modifiers else { return }
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
    /// undo step; over the Cancel bar it cancels.
    func endScrub() {
        guard let session = scrub else { return }
        cancelScrub()
        guard !session.overCancel else { return }
        let id = edit { $0.applyScrub(session.ref, thumb: session.thumbId, frame: session.frame, action: session.action) }
        selectedThumbId = id ?? session.thumbId
    }

    func cancelScrub() {
        scrub = nil
        scrubImage = nil
        scrubPending = nil
        scrubFrames.removeAll()
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
                if let cached = scrubFrames.first(where: { $0.key == key })?.image {
                    scrubImage = cached
                    continue
                }
                if let thumb = cachedImage(file: file.id, frame: frame, width: Self.thumbWidth) {
                    scrubImage = thumb
                }
                guard let backend = try? await backend(for: file),
                      let decoded = try? await backend.frame(frame, maxWidth: width)
                else { continue }
                scrubFrames.removeAll { $0.key == key }
                scrubFrames.append((key, decoded.image))
                if scrubFrames.count > Self.scrubFrameLimit { scrubFrames.removeFirst() }
                if scrub?.thumbId == session.thumbId { scrubImage = decoded.image }
            }
        }
    }

    // MARK: - Thumbnails

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

    /// Caches a decoded image, and pins it when it is on screen.
    private func store(_ image: CGImage, file: UUID, frame: Int, width: Int) {
        cache.insert(image, file: file, frame: frame, width: width)
        let onScreen = width == Self.posterWidth
            || (width == Self.thumbWidth && file == library.currentFileId)
        if onScreen { pinned[Self.loadingKey(file, frame, width)] = image }
    }

    /// Keeps only the posters and the current sheet's thumbs pinned.
    private func prunePinned() {
        var keep = Set(library.files.map { Self.loadingKey($0.id, $0.posterFrame, Self.posterWidth) })
        if let file = currentFile, let sheet = currentSheet {
            for thumb in sheet.thumbs { keep.insert(Self.loadingKey(file.id, thumb.frameNumber, Self.thumbWidth)) }
        }
        pinned = pinned.filter { keep.contains($0.key) }
    }

    private func loadCurrentSheet() {
        prunePinned()
        guard let file = currentFile, let sheet = currentSheet else { return }
        load(frames: sheet.thumbs.map(\.frameNumber), of: file, width: Self.thumbWidth, sheetId: sheet.id)
    }

    private func loadPoster(_ file: MovieFile) {
        load(frames: [file.posterFrame], of: file, width: Self.posterWidth, sheetId: nil)
    }

    /// Decodes the frames not yet cached. When the ±0.5 s retry returns
    /// another frame, the thumb takes that frame number (decision 11).
    private func load(frames: [Int], of file: MovieFile, width: Int, sheetId: UUID?) {
        let wanted = Array(Set(frames)).filter {
            cachedImage(file: file.id, frame: $0, width: width) == nil
                && !loading.contains(Self.loadingKey(file.id, $0, width))
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
            for await result in backend.frames(wanted, maxWidth: width) {
                switch result.result {
                case .success(let frame):
                    store(frame.image, file: file.id, frame: frame.actualFrame, width: width)
                    // Also under the requested frame, so a view asking for it
                    // finds it even before the thumb is retargeted (otherwise
                    // the reload-on-miss in `image` would loop).
                    store(frame.image, file: file.id, frame: frame.requestedFrame, width: width)
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
    /// edit, so it records no undo step.
    private func retarget(_ fileId: UUID, sheet sheetId: UUID, from: Int, to: Int) {
        guard let s = library.sheets[fileId]?.firstIndex(where: { $0.id == sheetId }) else { return }
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
