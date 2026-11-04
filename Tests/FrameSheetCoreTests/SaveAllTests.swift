import Foundation
import Testing
@testable import FrameSheetCore

/// Save All sheets (§12, T08).
@Suite struct SaveAllTests {
    private func library() -> (Library, [MovieFile]) {
        var library = Library()
        let files = ["a", "b", "c"].map {
            MovieFile(
                url: URL(fileURLWithPath: "/m/\($0).mov"), duration: 40, frameCount: 1000, fps: 25, width: 1920,
                height: 1080, size: 1, fourCC: "avc1")
        }
        library.files = files
        _ = library.addDefaultIntervalSheet(to: files[0].id)
        _ = library.addDefaultIntervalSheet(to: files[0].id)
        _ = library.addDefaultIntervalSheet(to: files[2].id)
        return (library, files)
    }

    @Test func planCoversEverySheetInOrder() throws {
        var (library, files) = library()
        #expect(SaveAllPlan.moviesWithoutSheets(library) == [files[1].id])
        for id in SaveAllPlan.moviesWithoutSheets(library) { _ = library.addDefaultIntervalSheet(to: id) }
        #expect(SaveAllPlan.moviesWithoutSheets(library).isEmpty)
        let items = SaveAllPlan.items(library)
        #expect(items.map(\.fileId) == [files[0].id, files[0].id, files[1].id, files[2].id])
        #expect(items.map(\.sheetId) == files.flatMap { library.sheets[$0.id]!.map(\.id) })
    }

    @Test func runsOneAtATimeAndReports() async {
        let (library, _) = library()
        let items = SaveAllPlan.items(library)
        let running = Counter()
        let order = Recorder()
        let report = await SaveAllQueue.run(items) { index, _ in
            await order.add("start \(index)")
        } save: { item in
            #expect(await running.enter() == 1)
            try? await Task.sleep(for: .milliseconds(5))
            await running.leave()
            return item == items[1] ? .failed("Movie is missing") : .saved
        }
        #expect(report.saved == 2 && report.failures.count == 1 && !report.cancelled && report.skipped == 0)
        #expect(report.failures.first?.reason == "Movie is missing")
        #expect(await order.lines == ["start 0", "start 1", "start 2"])
        #expect(report.summary.hasPrefix("Saved 2 sheets, 1 failed in "))
    }

    @Test func cancelStopsBeforeTheNext() async {
        let (library, _) = library()
        let items = SaveAllPlan.items(library)
        let started = Recorder()
        let task = Task {
            await SaveAllQueue.run(items) { index, _ in
                await started.add("\(index)")
            } save: { item in
                if item == items[0] { return .saved }
                // The second save is in progress when Cancel comes.
                try await Task.sleep(for: .seconds(10))
                return .saved
            }
        }
        while await started.lines.count < 2 { try? await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        let report = await task.value
        #expect(report.cancelled)
        #expect(report.saved == 1 && report.skipped == 2 && report.failures.isEmpty)
        #expect(await started.lines == ["0", "1"])
        #expect(report.summary.contains("2 not saved (canceled)"))
    }

    @Test func errorsDoNotStopTheQueue() async {
        struct Failure: Error, LocalizedError { var errorDescription: String? { "No frame could be decoded." } }
        let (library, _) = library()
        let items = SaveAllPlan.items(library)
        let report = await SaveAllQueue.run(items) { item in
            if item == items[0] { throw Failure() }
            return .saved
        }
        #expect(report.saved == 2 && report.failures.map(\.reason) == ["No frame could be decoded."])
    }
}

private actor Counter {
    private var value = 0
    func enter() -> Int { value += 1; return value }
    func leave() { value -= 1 }
}

private actor Recorder {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}
