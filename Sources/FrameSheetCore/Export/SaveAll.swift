import Foundation

// Save All sheets (§12; MoviePrint 0.2.23 `onSaveAllMoviePrints` in
// app/containers/App.js, MIT, docs/licenses/MoviePrint-LICENSE): every sheet
// of every movie, in movie-list order, one after the other; a movie without
// a sheet gets the default interval sheet first.

/// What Save All saves.
public enum SaveAllPlan {
    /// Movies with no sheet, which get the default interval sheet first.
    public static func moviesWithoutSheets(_ library: Library) -> [UUID] {
        library.files.filter { (library.sheets[$0.id] ?? []).isEmpty }.map(\.id)
    }

    /// Every sheet of every movie, in movie-list and sheet order.
    public static func items(_ library: Library) -> [SheetRef] {
        library.files.flatMap { file in
            (library.sheets[file.id] ?? []).map { SheetRef(fileId: file.id, sheetId: $0.id) }
        }
    }
}

/// How one queued save ended.
public enum SaveAllOutcome: Sendable, Equatable {
    case saved
    /// Saved, but not every frame could be decoded for it (the window's
    /// thumb or an empty cell in its place), with what is missing.
    case savedIncomplete(String)
    /// Not saved, with the reason (a missing movie, no thumbs, an error).
    case failed(String)
}

/// The result of a Save All run.
public struct SaveAllReport: Sendable, Equatable {
    public var saved = 0
    public var failures: [(item: SheetRef, reason: String)] = []
    /// Saved, but with frames missing (counted in `saved` too).
    public var incomplete: [(item: SheetRef, reason: String)] = []
    /// Items not started because of Cancel.
    public var skipped = 0
    public var cancelled = false
    public var seconds: Double = 0

    public init() {}

    public static func == (a: SaveAllReport, b: SaveAllReport) -> Bool {
        a.saved == b.saved && a.skipped == b.skipped && a.cancelled == b.cancelled
            && a.failures.map(\.item) == b.failures.map(\.item) && a.failures.map(\.reason) == b.failures.map(\.reason)
            && a.incomplete.map(\.item) == b.incomplete.map(\.item)
            && a.incomplete.map(\.reason) == b.incomplete.map(\.reason)
    }

    /// One line for the notice: what was saved, what failed, how long it took.
    public var summary: String {
        var text = "Saved \(saved) sheet\(saved == 1 ? "" : "s")"
        if !incomplete.isEmpty { text += " (\(incomplete.count) with frames missing)" }
        if !failures.isEmpty { text += ", \(failures.count) failed" }
        if cancelled { text += ", \(skipped) not saved (canceled)" }
        return text + String(format: " in %.1f s", seconds)
    }
}

/// Runs the queue: one save at a time, in order, each awaited before the
/// next starts (so their decodes pass the DecodeGate one after the other).
/// Cancelling the calling task stops before the next item; the save in
/// progress gets the cancellation too and counts as not saved.
public enum SaveAllQueue {
    public static func run(
        _ items: [SheetRef],
        progress: (_ index: Int, _ item: SheetRef) async -> Void = { _, _ in },
        save: (SheetRef) async throws -> SaveAllOutcome,
        isolation: isolated (any Actor)? = #isolation
    ) async -> SaveAllReport {
        var report = SaveAllReport()
        let started = ContinuousClock.now
        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                report.cancelled = true
                report.skipped = items.count - index
                break
            }
            await progress(index, item)
            do {
                switch try await save(item) {
                case .saved: report.saved += 1
                case .savedIncomplete(let reason):
                    report.saved += 1
                    report.incomplete.append((item, reason))
                case .failed(let reason): report.failures.append((item, reason))
                }
            } catch is CancellationError {
                report.cancelled = true
                report.skipped = items.count - index
                break
            } catch {
                report.failures.append((item, error.localizedDescription))
            }
        }
        if Task.isCancelled, !report.cancelled {
            report.cancelled = true
        }
        let elapsed = ContinuousClock.now - started
        report.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return report
    }
}
