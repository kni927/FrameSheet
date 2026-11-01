import AVFoundation
import Darwin
import Foundation

// MARK: - Command-line arguments

/// `spike <command> <file> [--key value] [--flag]`
struct Args {
    let command: String
    let file: String?
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String]) {
        command = argv.count > 1 ? argv[1] : "help"
        var file: String?
        var i = 2
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                file = arg
                i += 1
            }
        }
        self.file = file
    }

    func string(_ key: String, _ fallback: String) -> String { options[key] ?? fallback }
    func int(_ key: String, _ fallback: Int) -> Int { options[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String) -> Double? { options[key].flatMap(Double.init) }
    func flag(_ key: String) -> Bool { flags.contains(key) }

    func requireFile() throws -> String {
        guard let file else { throw SpikeError("missing input file") }
        return file
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Output

/// Writes a line to stdout unbuffered, so `tee` shows progress during long runs.
func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Ordered name → value pairs for one run.
struct Metrics {
    private(set) var items: [(String, Double)] = []

    mutating func set(_ key: String, _ value: Double) {
        if let i = items.firstIndex(where: { $0.0 == key }) {
            items[i].1 = value
        } else {
            items.append((key, value))
        }
    }

    subscript(key: String) -> Double? { items.first { $0.0 == key }?.1 }

    var formatted: String {
        items.map { key, value in
            value == value.rounded() && abs(value) < 1e9
                ? "\(key)=\(Int(value))"
                : "\(key)=\(String(format: "%.3f", value))"
        }.joined(separator: " ")
    }
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/// Runs `body` `runs` times, prints each run, then the per-key median.
func runRepeated(_ runs: Int, _ body: (Int) async throws -> Metrics) async throws {
    var all: [Metrics] = []
    for run in 1...max(1, runs) {
        let metrics = try await body(run)
        log("run \(run): \(metrics.formatted)")
        all.append(metrics)
    }
    guard let first = all.first else { return }
    var result = Metrics()
    for (key, _) in first.items {
        result.set(key, median(all.compactMap { $0[key] }))
    }
    log("median: \(result.formatted)")
}

// MARK: - Clocks, CPU, memory

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

private func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }

/// User + system CPU time of this process (`RUSAGE_SELF`) or of its waited-for children.
func cpuSeconds(children: Bool = false) -> Double {
    var usage = rusage()
    getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &usage)
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// System-wide busy and total CPU ticks. Decoding runs in VTDecoderXPCService, outside
/// this process, so `RUSAGE_SELF` misses it; the system-wide delta catches it (plus noise).
func systemTicks() -> (busy: Double, total: Double) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    let ticks = info.cpu_ticks
    let busy = Double(ticks.0) + Double(ticks.1) + Double(ticks.3)
    return (busy, busy + Double(ticks.2))
}

/// Average number of busy cores across the whole system since `start`.
func systemCores(since start: (busy: Double, total: Double)) -> Double {
    let end = systemTicks()
    let total = end.total - start.total
    return total > 0 ? (end.busy - start.busy) / total * Double(ProcessInfo.processInfo.activeProcessorCount) : 0
}

/// Current physical footprint of this process in MB (what Activity Monitor shows as Memory).
func footprintMB() -> Double {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
}

// MARK: - Video input

struct VideoInfo {
    let width: Int
    let height: Int
    let duration: Double
    let fps: Double
    let codec: String
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

func loadVideo(_ path: String) async throws -> (AVURLAsset, AVAssetTrack, VideoInfo) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw SpikeError("no video track (AVFoundation cannot read this file)")
    }
    let (size, fps, formats) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
    let duration = try await asset.load(.duration).seconds
    let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
    let info = VideoInfo(width: Int(size.width), height: Int(size.height), duration: duration,
                         fps: Double(fps), codec: codec)
    log("input: \(codec) \(info.width)x\(info.height) \(String(format: "%.3f", info.fps)) fps "
        + "\(String(format: "%.1f", duration / 60)) min")
    return (asset, track, info)
}

/// Size whose long side is `maxSide`, keeping the aspect ratio, rounded to even numbers.
/// `maxSide` 0 keeps the source size.
func scaledSize(_ width: Int, _ height: Int, maxSide: Int) -> (Int, Int) {
    if maxSide == 0 { return (width, height) }
    func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
    if width >= height {
        return (maxSide, even(Double(height) * Double(maxSide) / Double(width)))
    }
    return (even(Double(width) * Double(maxSide) / Double(height)), maxSide)
}

struct ReaderOutput {
    let pixelFormat: OSType
    /// Size the reader scales to; nil keeps the track's size.
    let size: (Int, Int)?
}

/// An `AVAssetReader` with one track output per entry of `outputs`, already started.
func makeReader(_ asset: AVAsset, _ track: AVAssetTrack, outputs: [ReaderOutput],
                seconds: Double?, start: Double = 0) throws -> (AVAssetReader, [AVAssetReaderTrackOutput]) {
    let reader = try AVAssetReader(asset: asset)
    if seconds != nil || start > 0 {
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
                                           ?? .positiveInfinity)
    }
    let trackOutputs = outputs.map { output in
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: output.pixelFormat]
        if let (width, height) = output.size {
            settings[kCVPixelBufferWidthKey as String] = width
            settings[kCVPixelBufferHeightKey as String] = height
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        return trackOutput
    }
    guard reader.startReading() else {
        throw SpikeError("startReading failed: \(reader.error.map { "\($0)" } ?? "?")")
    }
    return (reader, trackOutputs)
}

func checkFinished(_ reader: AVAssetReader) throws {
    if reader.status == .failed {
        throw SpikeError("reader failed: \(reader.error.map { "\($0)" } ?? "?")")
    }
}

// MARK: - Shot metric

/// Mean of HSV V (= max(R, G, B)) over a BGRA image, as MoviePrint's Mean method uses.
func meanV(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> Double {
    var total: UInt64 = 0
    for y in 0..<height {
        let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        var rowSum: UInt32 = 0
        var x = 0
        while x < width * 4 {
            rowSum &+= UInt32(max(row[x], row[x + 1], row[x + 2]))
            x += 4
        }
        total += UInt64(rowSum)
    }
    return Double(total) / Double(width * height)
}

func meanV(_ buffer: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return meanV(base: CVPixelBufferGetBaseAddress(buffer)!, width: CVPixelBufferGetWidth(buffer),
                 height: CVPixelBufferGetHeight(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
}

/// Mean of the Y plane of a 420f buffer: a cheaper luma-only stand-in for meanV.
func meanLuma(_ buffer: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    var total: UInt64 = 0
    for y in 0..<height {
        let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        var rowSum: UInt32 = 0
        for x in 0..<width { rowSum &+= UInt32(row[x]) }
        total += UInt64(rowSum)
    }
    return Double(total) / Double(width * height)
}
