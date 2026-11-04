import Foundation

/// The face scan results of one movie (§10, §12): which frames were
/// analyzed, and the faces of those that have any. Built up over scans of
/// different ranges and scopes; a scan only analyzes frames not yet in
/// `analyzed`. The thresholds are those the faces were found with: a scan
/// with other thresholds starts over.
public struct FaceData: Sendable, Equatable {
    public var thresholds: FaceThresholds
    public private(set) var analyzed: IndexSet
    /// Frames with at least one face, by frame number.
    public private(set) var frames: [Int: FaceFrame]

    public init(thresholds: FaceThresholds) {
        self.thresholds = thresholds
        analyzed = IndexSet()
        frames = [:]
    }

    public func isAnalyzed(_ frame: Int) -> Bool { analyzed.contains(frame) }

    /// The stored frame, or an empty one for an analyzed frame without
    /// faces; nil for a frame not analyzed.
    public func frame(_ number: Int) -> FaceFrame? {
        if let frame = frames[number] { return frame }
        return analyzed.contains(number) ? FaceFrame(frameNumber: number, faces: []) : nil
    }

    /// The frames of `numbers` that were not analyzed yet, in order.
    public func missing(_ numbers: [Int]) -> [Int] {
        numbers.filter { !analyzed.contains($0) }
    }

    public mutating func record(_ frame: FaceFrame) {
        analyzed.insert(frame.frameNumber)
        frames[frame.frameNumber] = frame.faceCount > 0 ? frame : nil
    }
}

extension FaceData: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, thresholds, analyzed, frames
    }

    /// 1: the first format.
    static let version = 1

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == Self.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c, debugDescription: "Unknown face cache version")
        }
        thresholds = try c.decode(FaceThresholds.self, forKey: .thresholds)
        analyzed = IndexSet(try c.decode([Int].self, forKey: .analyzed))
        frames = Dictionary(
            try c.decode([FaceFrame].self, forKey: .frames).map { ($0.frameNumber, $0) },
            uniquingKeysWith: { a, _ in a })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        try c.encode(thresholds, forKey: .thresholds)
        try c.encode(Array(analyzed), forKey: .analyzed)
        try c.encode(frames.values.sorted { $0.frameNumber < $1.frameNumber }, forKey: .frames)
    }
}

/// One JSON file per movie, `<movie id>.fsfaces`, next to its shot scan
/// cache (`ScanCacheStore`) in `~/Library/Application Support/FrameSheet/Scans/`.
/// Every 10th frame of a 2 h 60 fps film (43,200 frames) takes about
/// 300 KB plus the faces. Loaded only when asked for.
public struct FaceCacheStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for fileId: UUID) -> URL {
        directory.appending(path: "\(fileId.uuidString).fsfaces", directoryHint: .notDirectory)
    }

    /// The stored results, or nil when there are none; throws on an
    /// unreadable file.
    public func load(_ fileId: UUID) throws -> FaceData? {
        let url = url(for: fileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(FaceData.self, from: Data(contentsOf: url))
    }

    public func save(_ data: FaceData, for fileId: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: url(for: fileId), options: .atomic)
    }

    public func delete(_ fileId: UUID) {
        try? FileManager.default.removeItem(at: url(for: fileId))
    }
}

/// The stored scans of movies no longer in the library.
public enum StoredScans {
    static let extensions: Set<String> = ["fsscan", "fsfaces"]

    /// Deletes the shot and face scan files (`<movie id>.fsscan`,
    /// `<movie id>.fsfaces`) in `directory` whose movie id is not in `keep`;
    /// other files are left alone. Returns the ids whose files went.
    @discardableResult
    public static func removeStale(in directory: URL, keeping keep: Set<UUID>) -> Set<UUID> {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var removed = Set<UUID>()
        for url in urls where extensions.contains(url.pathExtension) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !keep.contains(id) else {
                continue
            }
            if (try? manager.removeItem(at: url)) != nil { removed.insert(id) }
        }
        return removed
    }
}
