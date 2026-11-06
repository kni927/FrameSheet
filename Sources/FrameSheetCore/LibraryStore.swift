import Foundation

/// Reads and writes the library as JSON (§12). The app saves shortly after
/// each change and loads once on launch.
public struct LibraryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/FrameSheet/library.json`.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "FrameSheet", directoryHint: .isDirectory)
            .appending(path: "library.json", directoryHint: .notDirectory)
    }

    /// Returns an empty library when there is no file yet.
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let data = try Data(contentsOf: url)
        var library = try JSONDecoder().decode(Library.self, from: data)
        library.migrate()
        return library
    }

    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}

/// The library file as the app uses it: loaded once on launch, then saved
/// after changes. When the load fails (a file this version cannot read),
/// saving stays off for the session, so the file is kept as it is instead of
/// being replaced by the empty list the app starts with; the next launch
/// reads it again.
public struct LibraryPersistence: Sendable {
    public let store: LibraryStore
    /// The last load failed; nothing is written.
    public private(set) var loadFailed = false

    public init(store: LibraryStore) {
        self.store = store
    }

    /// The stored library, or an empty one with the error when it cannot be
    /// read.
    public mutating func load() -> (library: Library, error: (any Error)?) {
        do {
            loadFailed = false
            return (try store.load(), nil)
        } catch {
            loadFailed = true
            return (Library(), error)
        }
    }

    /// Writes the library; false, writing nothing, after a failed load.
    @discardableResult
    public func save(_ library: Library) throws -> Bool {
        guard !loadFailed else { return false }
        try store.save(library)
        return true
    }
}
