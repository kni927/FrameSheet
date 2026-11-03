import Foundation

/// The stored result of a shot scan (§10): per frame the difference to the
/// previous frame (Float32) and the frame's mean color, plus the method that
/// produced them. A partial scan (cancelled, failed or still running) holds
/// the frames read so far, from frame 0 on.
public struct ScanData: Sendable, Equatable {
    public var method: ShotDetectionMethod
    public var differences: [Float]
    /// R, G, B per frame.
    public var colors: [UInt8]
    /// Every frame has been read.
    public var complete: Bool
    /// The movie's frame count when the scan started; a partial scan only
    /// resumes for the same count.
    public var expectedFrameCount: Int

    public init(
        method: ShotDetectionMethod, differences: [Float] = [], colors: [UInt8] = [], complete: Bool = false,
        expectedFrameCount: Int
    ) {
        precondition(colors.count == differences.count * 3)
        self.method = method
        self.differences = differences
        self.colors = colors
        self.complete = complete
        self.expectedFrameCount = expectedFrameCount
    }

    /// Frames stored.
    public var frameCount: Int { differences.count }

    public func color(at frame: Int) -> RGB8 {
        guard frame >= 0, frame < frameCount else { return .black }
        return RGB8(red: colors[frame * 3], green: colors[frame * 3 + 1], blue: colors[frame * 3 + 2])
    }

    mutating func append(difference: Float, color: RGB8) {
        differences.append(difference)
        // Three appends: an array literal here would allocate every frame.
        colors.append(color.red)
        colors.append(color.green)
        colors.append(color.blue)
    }

    /// Fills a frame the decoder skipped with the previous frame's color and
    /// no difference (MoviePrint `repairFrameScanData`; black for frame 0).
    mutating func appendRepeatingLast() {
        append(difference: 0, color: frameCount > 0 ? color(at: frameCount - 1) : .black)
    }

    mutating func reserve(_ frames: Int) {
        differences.reserveCapacity(frames)
        colors.reserveCapacity(frames * 3)
    }
}

/// One small binary file per movie, `<movie id>.fsscan`, in
/// `~/Library/Application Support/FrameSheet/Scans/` next to the library.
/// Loaded only when asked for.
///
/// Layout, little endian: a 32-byte header — magic `FSSC`, format version
/// (UInt16, 1), method (UInt8: 0 mean, 1 histogram), flags (UInt8, bit 0
/// complete), stored frame count n (UInt32), expected frame count (UInt32),
/// 16 reserved bytes — then n Float32 differences, then n × 3 bytes R, G, B.
/// A 2 h film at 60 fps (432,000 frames) takes about 3 MB.
public struct ScanCacheStore: Sendable {
    public let directory: URL

    static let magic: [UInt8] = Array("FSSC".utf8)
    static let version: UInt16 = 1
    static let headerSize = 32

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/FrameSheet/Scans`.
    public static func defaultDirectory() throws -> URL {
        try LibraryStore.defaultURL().deletingLastPathComponent()
            .appending(path: "Scans", directoryHint: .isDirectory)
    }

    public func url(for fileId: UUID) -> URL {
        directory.appending(path: "\(fileId.uuidString).fsscan", directoryHint: .notDirectory)
    }

    /// The stored scan, or nil when there is none; throws on an unreadable
    /// or malformed file.
    public func load(_ fileId: UUID) throws -> ScanData? {
        let url = url(for: fileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decode(Data(contentsOf: url))
    }

    public func save(_ scan: ScanData, for fileId: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(scan).write(to: url(for: fileId), options: .atomic)
    }

    public func delete(_ fileId: UUID) {
        try? FileManager.default.removeItem(at: url(for: fileId))
    }

    // MARK: - Format

    struct FormatError: Error, LocalizedError {
        var reason: String
        var errorDescription: String? { "The scan cache is unreadable: \(reason)." }
    }

    static func encode(_ scan: ScanData) -> Data {
        let n = scan.frameCount
        var data = Data(capacity: headerSize + n * 7)
        data.append(contentsOf: magic)
        append(&data, version)
        data.append(scan.method == .mean ? 0 : 1)
        data.append(scan.complete ? 1 : 0)
        append(&data, UInt32(clamping: n))
        append(&data, UInt32(clamping: scan.expectedFrameCount))
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))
        scan.differences.withUnsafeBufferPointer { buffer in
            for value in buffer { append(&data, value.bitPattern) }
        }
        data.append(contentsOf: scan.colors)
        return data
    }

    static func decode(_ data: Data) throws -> ScanData {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, Array(bytes[0..<4]) == magic else { throw FormatError(reason: "no header") }
        guard read(UInt16.self, bytes, 4) == version else { throw FormatError(reason: "unknown version") }
        let method: ShotDetectionMethod = bytes[6] == 0 ? .mean : .histogram
        let complete = bytes[7] & 1 != 0
        let n = Int(read(UInt32.self, bytes, 8))
        let expected = Int(read(UInt32.self, bytes, 12))
        guard bytes.count == headerSize + n * 7 else { throw FormatError(reason: "wrong length") }
        var differences = [Float](repeating: 0, count: n)
        for i in 0..<n {
            differences[i] = Float(bitPattern: read(UInt32.self, bytes, headerSize + i * 4))
        }
        let colorStart = headerSize + n * 4
        let colors = Array(bytes[colorStart..<(colorStart + n * 3)])
        return ScanData(
            method: method, differences: differences, colors: colors, complete: complete,
            expectedFrameCount: expected)
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, _ bytes: [UInt8], _ offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(bytes[offset + i]) << (8 * i) }
        return value
    }
}
