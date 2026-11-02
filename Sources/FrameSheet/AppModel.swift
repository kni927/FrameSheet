import AppKit
import FrameSheetCore
import Observation
import SwiftUI

/// App state: the library, the open decoders, the thumbnail cache and the
/// ffmpeg discovery. All UI work runs on the main actor; decoding runs in
/// the backends.
@MainActor @Observable
final class AppModel {
    private(set) var library: Library
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

    /// Width thumbs are decoded at; enough for a 4-column grid on a
    /// Retina display.
    static let thumbWidth = 640
    static let posterWidth = 320

    let cache: ThumbnailCache
    private let store: LibraryStore?
    @ObservationIgnored private var backends: [UUID: any DecodeBackend] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var discovery: Task<Void, Never>?

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
        self.store = store
        library = loaded
        cache = ThumbnailCache(limitMB: loaded.settings.thumbnailCacheMB)
        toast = loadError
        for i in library.files.indices { resolveBookmark(at: i) }
        findFFmpeg()
        for file in library.files { loadPoster(file) }
        if let id = library.currentFileId { loadCurrentSheet(id) }
    }

    // MARK: - Library access

    var currentFile: MovieFile? { library.currentFileId.flatMap(library.file) }

    var currentSheet: Sheet? {
        guard let fileId = library.currentFileId, let sheetId = library.currentSheetId else { return nil }
        return library.sheet(sheetId, of: fileId)
    }

    func sheets(of fileId: UUID) -> [Sheet] { library.sheets[fileId] ?? [] }

    func image(file: UUID, frame: Int, width: Int) -> CGImage? {
        _ = imageGeneration
        return cache.image(file: file, frame: frame, width: width)
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
        library.settings.ffmpegPath = path
        backends = backends.filter { $0.value.kind != .ffmpeg }
        scheduleSave()
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

    // MARK: - Adding movies

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
            var added: [UUID] = []
            for url in urls where url.isFileURL {
                if library.files.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    continue
                }
                do {
                    let backend = try await DecoderRouter.open(url, ffmpeg: await ffmpegTools())
                    let info = backend.info
                    let file = MovieFile(
                        url: url, bookmark: Self.bookmark(for: url), duration: info.duration,
                        frameCount: info.frameCount, fps: info.fps, width: info.width,
                        height: info.height, size: info.size, fourCC: info.fourCC)
                    library.files.append(file)
                    backends[file.id] = backend
                    added.append(file.id)
                    loadPoster(file)
                } catch {
                    toast = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            if library.currentFileId == nil, let first = added.first { select(file: first) }
            scheduleSave()
        }
    }

    func clearList() {
        library.removeAll()
        backends = [:]
        missing = []
        cache.removeAll()
        scheduleSave()
    }

    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Follows the bookmark if the file moved; marks the movie missing if
    /// it cannot be found.
    private func resolveBookmark(at index: Int) {
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
                if stale { library.files[index].bookmark = Self.bookmark(for: url) }
            }
        }
        if !FileManager.default.fileExists(atPath: library.files[index].url.path) {
            missing.insert(file.id)
        }
    }

    // MARK: - Selection

    func select(file id: UUID) {
        guard library.file(id) != nil else { return }
        library.currentFileId = id
        if sheets(of: id).isEmpty {
            library.addDefaultIntervalSheet(to: id)
        }
        library.currentSheetId = sheets(of: id).first?.id
        scheduleSave()
        loadCurrentSheet(id)
    }

    func select(sheet sheetId: UUID, of fileId: UUID) {
        library.currentFileId = fileId
        library.currentSheetId = sheetId
        scheduleSave()
        loadCurrentSheet(fileId)
    }

    // MARK: - Thumbnails

    private func backend(for file: MovieFile) async throws -> any DecodeBackend {
        if let backend = backends[file.id] { return backend }
        guard !missing.contains(file.id) else { throw DecodeError("Movie is missing") }
        let backend = try await DecoderRouter.open(file.url, ffmpeg: await ffmpegTools())
        backends[file.id] = backend
        return backend
    }

    private func loadCurrentSheet(_ fileId: UUID) {
        guard let file = library.file(fileId), let sheet = currentSheet else { return }
        load(frames: sheet.thumbs.map(\.frameNumber), of: file, width: Self.thumbWidth, sheetId: sheet.id)
    }

    private func loadPoster(_ file: MovieFile) {
        load(frames: [file.posterFrame], of: file, width: Self.posterWidth, sheetId: nil)
    }

    /// Decodes the frames not yet cached. When the ±0.5 s retry returns
    /// another frame, the thumb takes that frame number (decision 11).
    private func load(frames: [Int], of file: MovieFile, width: Int, sheetId: UUID?) {
        let wanted = frames.filter {
            cache.image(file: file.id, frame: $0, width: width) == nil
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
                    cache.insert(frame.image, file: file.id, frame: frame.actualFrame, width: width)
                    if frame.actualFrame != frame.requestedFrame, let sheetId {
                        moveThumb(of: file.id, sheet: sheetId, from: frame.requestedFrame, to: frame.actualFrame)
                    }
                    imageGeneration += 1
                case .failure:
                    failures += 1
                }
            }
            if failures > 0 { toast = "\(file.name): \(failures) frame(s) could not be decoded." }
        }
    }

    private func moveThumb(of fileId: UUID, sheet sheetId: UUID, from: Int, to: Int) {
        guard let s = library.sheets[fileId]?.firstIndex(where: { $0.id == sheetId }),
              let t = library.sheets[fileId]?[s].thumbs.firstIndex(where: { $0.frameNumber == from })
        else { return }
        library.sheets[fileId]?[s].thumbs[t].frameNumber = to
        scheduleSave()
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
