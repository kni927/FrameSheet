import Foundation
import Testing
@testable import FrameSheetCore

@Suite struct IntervalFramesTests {
    @Test func evenlySpreadIncludingBothEnds() {
        let frames = IntervalFrames.frameNumbers(amount: 16, start: 0, stop: 999, maxValue: 1000)
        #expect(frames.count == 16)
        #expect(frames.first == 0)
        #expect(frames.last == 999)
        // 999 / 15 = 66.6 per step, rounded half up
        #expect(frames[1] == 67)
        #expect(frames[2] == 133)
        #expect(frames == frames.sorted())
    }

    @Test func limitedToShortRange() {
        let frames = IntervalFrames.frameNumbers(
            amount: 16, start: 0, stop: 9, maxValue: 100, limitToMaxValue: true)
        #expect(frames == Array(0...9))
    }

    @Test func neverMoreThanFrameCountMinusOne() {
        // MoviePrint caps the amount at maxValue - 1.
        let frames = IntervalFrames.frameNumbers(amount: 16, start: 0, stop: 9, maxValue: 10)
        #expect(frames.count == 9)
        #expect(frames.first == 0)
        #expect(frames.last == 9)
    }

    @Test func widenedAndMovedInsideTheMovie() {
        let frames = IntervalFrames.frameNumbers(amount: 16, start: 990, stop: 995, maxValue: 1000)
        #expect(frames.count == 16)
        #expect(frames.first == 983)
        #expect(frames.last == 999)
    }

    @Test func mapRangeMatchesMoviePrint() {
        #expect(IntervalFrames.mapRange(5, 3, 3, 0, 10) == 0)
        #expect(IntervalFrames.mapRange(1, 0, 2, 0, 5) == 3)  // 2.5 rounds up
        #expect(IntervalFrames.mapRange(1, 0, 3, 0, 1, returnInt: false) == 0.333)
        #expect(IntervalFrames.mapRange(9, 0, 3, 0, 10) == 10)  // clamped
    }

    @Test func emptyMovie() {
        #expect(IntervalFrames.frameNumbers(amount: 16, start: 0, stop: 0, maxValue: 1).isEmpty)
    }
}

@Suite struct SheetNamingTests {
    private func libraryWithOneFile() -> (Library, UUID) {
        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
            width: 1920, height: 1080, size: 1, fourCC: "avc1")
        library.files.append(file)
        return (library, file.id)
    }

    @Test func namesCountPerFile() throws {
        var (library, id) = libraryWithOneFile()
        #expect(library.addDefaultIntervalSheet(to: id)?.name == "MoviePrint-1")
        #expect(library.addDefaultIntervalSheet(to: id)?.name == "MoviePrint-2")
        library.sheets[id]?.removeLast()
        #expect(library.addDefaultIntervalSheet(to: id)?.name == "MoviePrint-3")
        #expect(SheetNaming.newSheetName(sheetCount: 0) == "MoviePrint-1")
    }

    @Test func defaultIntervalSheet() throws {
        var (library, id) = libraryWithOneFile()
        let added = library.addDefaultIntervalSheet(to: id)
        let sheet = try #require(added)
        #expect(sheet.type == .interval)
        #expect(sheet.view == .grid)
        #expect(sheet.columnCount == 4)
        #expect(sheet.thumbs.map(\.frameNumber).first == 0)
        #expect(sheet.thumbs.map(\.frameNumber).last == 999)
        #expect(sheet.thumbs.map(\.index) == Array(0..<16))
    }
}

@Suite struct GridGeometryTests {
    @Test func unscaledPrint() {
        // Container as wide as the unscaled print → scale 1.
        let g = GridGeometry(.init(
            movieWidth: 1920, movieHeight: 1080, columnCount: 4, thumbCount: 16,
            containerWidth: 2006.4))
        #expect(g.rowCount == 4)
        #expect(abs(g.scale - 1) < 1e-9)
        #expect(abs(g.thumbWidth - 480) < 1e-9)
        #expect(abs(g.thumbHeight - 270) < 1e-9)
        #expect(abs(g.thumbMargin - 9.6) < 1e-9)
        #expect(abs(g.borderRadius - 19.2) < 1e-9)
        #expect(abs(g.printWidth - 2016.4) < 1e-9)
        // 1176 / 2006.4 of the print width
        #expect(abs(g.printHeight - 2016.4 * 1176 / 2006.4) < 1e-9)
        let f = g.thumbFrame(at: 5)
        #expect(abs(f.minX - 513.6) < 1e-9)
        #expect(abs(f.minY - 308.4) < 1e-9)
    }

    @Test func fitsTheSmallerSideAndZooms() {
        let g = GridGeometry(.init(
            movieWidth: 1920, movieHeight: 1080, columnCount: 4, thumbCount: 16,
            containerWidth: 2006.4, containerHeight: 588, zoom: 2))
        #expect(abs(g.scale - 1) < 1e-9)  // 588 / 1176 × 2
    }

    @Test func headerAndRows() {
        let g = GridGeometry(.init(
            movieWidth: 1920, movieHeight: 1080, columnCount: 3, thumbCount: 10,
            containerWidth: 1000, showHeader: true, roundedCorners: false))
        #expect(g.rowCount == 4)
        #expect(g.borderRadius == 0)
        // 1080 × 0.25 × 2 × 0.25 = 135 before scaling
        #expect(abs(g.headerHeight - 135 * g.scale) < 1e-9)
    }

    @Test func aspectRatioOverride() {
        let g = GridGeometry(.init(
            movieWidth: 1920, movieHeight: 1080, aspectRatioInv: 0.5, columnCount: 4,
            thumbCount: 16, containerWidth: 2006.4))
        #expect(abs(g.thumbHeight - 240) < 1e-9)
    }
}

@Suite struct PersistenceTests {
    @Test func roundTrip() throws {
        var library = Library()
        var file = MovieFile(
            url: URL(fileURLWithPath: "/movies/Ünïcode film.mov"), bookmark: Data([1, 2, 3]),
            duration: 7200.5, frameCount: 431_730, fps: 59.94, width: 1920, height: 1080,
            size: 4_000_000_000, fourCC: "hvc1")
        file.transform.rotation = 90
        file.inFrame = 10
        library.files.append(file)
        library.addDefaultIntervalSheet(to: file.id)
        library.sheets[file.id]?[0].thumbs[3].hidden = true
        library.settings.ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        library.currentFileId = file.id
        library.currentSheetId = library.sheets[file.id]?[0].id

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "FrameSheetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(url: dir.appending(path: "library.json"))
        try store.save(library)
        #expect(try store.load() == library)
    }

    @Test func missingFileGivesEmptyLibrary() throws {
        let store = LibraryStore(url: URL(fileURLWithPath: "/nonexistent/\(UUID())/library.json"))
        #expect(try store.load() == Library())
    }

    @Test func settingsToleratesMissingKeys() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"showHeader":true}"#.utf8))
        #expect(settings.showHeader)
        #expect(settings.marginSlider == 4)
        #expect(settings.thumbnailCacheMB == 256)
    }
}

@Suite struct TimecodeTests {
    @Test func timecode() {
        #expect(Timecode.string(frames: 25 * 3661 + 7, fps: 25) == "01:01:01:07")
        #expect(Timecode.string(frames: 60, fps: 59.94) == "00:00:01:00")
        #expect(Timecode.string(seconds: 7325.9) == "02:02:05")
    }
}
