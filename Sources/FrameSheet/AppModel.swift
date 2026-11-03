import AppKit
import FrameSheetCore
import Observation
import SwiftUI

/// A scrub in progress (§7): the thumb, its neighbours' frames and the frame
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
    /// Latest error or notice for the toast; nil hides it.
    var toast: String?
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
    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private var columnsAtDragStart: Int?
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
        if document.undo() { didChange() }
    }

    func redo() {
        cancelScrub()
        if document.redo() { didChange() }
    }

    private func didChange() {
        if let id = selectedThumbId, currentSheet?.thumbs.contains(where: { $0.id == id }) != true {
            selectedThumbId = nil
        }
        scheduleSave()
        loadCurrentSheet()
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
        cache.removeAll()
        pinned.removeAll()
        failed.removeAll()
        imageGeneration += 1
        for file in library.files { loadPoster(file) }
        loadCurrentSheet()
    }

    // MARK: - Adding and removing movies

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.message = "Add movies"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        addMovies(panel.urls, clearFirst: false)
    }

    func addMovies(_ urls: [URL], clearFirst: Bool) {
        if clearFirst { clearList() }
        Task {
            var added: [MovieFile] = []
            for url in urls where url.isFileURL {
                let known = library.files + added
                if known.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    continue
                }
                do {
                    let backend = try await DecoderRouter.open(url, ffmpeg: await ffmpegTools())
                    let info = backend.info
                    let file = MovieFile(
                        url: url, bookmark: Self.bookmark(for: url), duration: info.duration,
                        frameCount: info.frameCount, fps: info.fps, width: info.width,
                        height: info.height, size: info.size, fourCC: info.fourCC)
                    added.append(file)
                    backends[file.id] = backend
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

    func clearList() {
        cancelScrub()
        edit { $0.removeAll() }
        backends = [:]
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

    /// Locate: points a missing movie at a file the user picks, then opens
    /// it again.
    func locate(_ fileId: UUID) {
        guard let file = library.file(fileId) else { return }
        let panel = NSOpenPanel()
        panel.message = "Locate \(file.name)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = file.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit { $0.relink(fileId, to: url, bookmark: Self.bookmark(for: url)) }
        backends[fileId] = nil
        missing.remove(fileId)
        cache.removeAll()
        pinned.removeAll()
        failed.removeAll()
        imageGeneration += 1
        if let relinked = library.file(fileId) { loadPoster(relinked) }
        loadCurrentSheet()
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

    // MARK: - Selection

    func select(file id: UUID) {
        guard library.file(id) != nil else { return }
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

    func applyThumbCount(columns: Int, rows: Int) {
        guard let ref = currentRef else { return }
        edit { $0.applyThumbCount(ref, columns: columns, rows: rows) }
    }

    /// Rows slider: rearranges like the Columns slider (columns follow from
    /// rows); the thumb count stays. Ends with `endColumnsDrag`.
    func setRowsLive(_ rows: Int, editing: Bool) {
        guard let sheet = currentSheet else { return }
        let columns = GridLayout.columns(rows: rows, thumbCount: sheet.visibleThumbs.count)
        guard editing || columns != sheet.columnCount else { return }
        setColumnsLive(columns, editing: editing)
    }

    func optimiseGrid() {
        guard let ref = currentRef else { return }
        edit { $0.optimiseGrid(ref) }
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
            file: file, columns: sheet.columnCount, thumbCount: shownThumbs(of: sheet).count,
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
        let (left, right) = sheet.visibleNeighbours(of: thumb)
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

    private func backend(for file: MovieFile) async throws -> any DecodeBackend {
        if let backend = backends[file.id] { return backend }
        guard !missing.contains(file.id) else { throw DecodeError("Movie is missing") }
        let backend = try await DecoderRouter.open(file.url, ffmpeg: await ffmpegTools())
        backends[file.id] = backend
        return backend
    }

    private func cachedImage(file: UUID, frame: Int, width: Int) -> CGImage? {
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
                toast = "\(file.name): \(error.localizedDescription)"
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
            if failures > 0 { toast = "\(file.name): \(failures) frame(s) could not be decoded." }
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
