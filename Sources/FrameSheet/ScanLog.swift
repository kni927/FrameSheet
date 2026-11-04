import FrameSheetCore
import Foundation
import Synchronization

/// The scan timing log: one plain-text file, `~/Library/Logs/FrameSheet/scan.log`,
/// appended to by every shot and face scan started from the app. Each scan
/// starts with a header line (local date and time, scan kind); every
/// following line is `<ms since the scan started> <event>`. Lines are
/// buffered and written at most once a second, and at the end of the scan
/// (lines that arrive after the end, such as the analysis worker's totals,
/// are written at once).
final class ScanLog: Sendable {
    private struct State {
        var lines: [String] = []
        var lastFlush = ContinuousClock.now
        var ended = false
        /// Main-actor time spent handling the scan's events, by kind.
        var mainTime: [String: Duration] = [:]
        var mainCount: [String: Int] = [:]
        /// Thumb decodes requested while the scan ran.
        var thumbRequests = 0
        var thumbFrames = 0
        var thumbTime: Duration = .zero
    }

    let started = ContinuousClock.now
    private let state = Mutex(State())

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/FrameSheet/scan.log", directoryHint: .notDirectory)
    }

    init(_ title: String) {
        let date = Date.ISO8601FormatStyle(timeZone: .current).format(Date())
        state.withLock { $0.lines.append("=== \(date) \(title)") }
    }

    /// The core's sink for this scan.
    var sink: ScanLogSink { { [self] line in self.write(line) } }

    func write(_ text: String) {
        let line = stamped(text)
        state.withLock { s in
            s.lines.append(line)
            guard s.ended || ContinuousClock.now - s.lastFlush >= .seconds(1) else { return }
            s.lastFlush = ContinuousClock.now
            // Under the lock, so lines from the scan's tasks and the main
            // actor reach the file in order.
            Self.append(s.lines)
            s.lines.removeAll()
        }
    }

    private func stamped(_ text: String) -> String {
        let ms = String(Int((ContinuousClock.now - started) / .milliseconds(1)))
        return String(repeating: " ", count: max(0, 8 - ms.count)) + ms + " " + text
    }

    /// Adds the time a main-actor handler took for one event of `kind`.
    func mainActor(_ kind: String, _ duration: Duration) {
        state.withLock {
            $0.mainTime[kind, default: .zero] += duration
            $0.mainCount[kind, default: 0] += 1
        }
    }

    /// A batch of thumb decodes that ran while the scan did.
    func thumbDecode(frames: Int, width: Int, took: Duration, failures: Int) {
        state.withLock {
            $0.thumbRequests += 1
            $0.thumbFrames += frames
            $0.thumbTime += took
        }
        write("app: thumb decode of \(frames) frame(s) at \(width) px took \(Self.ms(took))"
            + (failures > 0 ? ", \(failures) failed" : ""))
    }

    /// The summary and the end; later lines are written at once.
    func end(_ how: String) {
        let s = state.withLock { $0 }
        let main = s.mainTime.keys.sorted().map { kind in
            "\(kind) \(s.mainCount[kind] ?? 0)× \(Self.ms(s.mainTime[kind] ?? .zero))"
        }.joined(separator: ", ")
        write("app: main-actor time: " + (main.isEmpty ? "none" : main))
        write("app: thumb decodes during the scan: \(s.thumbRequests) request(s), \(s.thumbFrames) frame(s), "
            + "\(Self.ms(s.thumbTime)) from request to image")
        let line = stamped("app: \(how), wall \(Self.ms(ContinuousClock.now - started))")
        state.withLock { s in
            s.ended = true
            s.lines.append(line)
            Self.append(s.lines)
            s.lines.removeAll()
        }
    }

    static func ms(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration / .microseconds(1)) / 1000)
    }

    private static func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let url = url
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
