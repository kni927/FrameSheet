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
        return try JSONDecoder().decode(Library.self, from: data)
    }

    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
