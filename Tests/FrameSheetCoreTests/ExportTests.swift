import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FrameSheetCore

@Suite struct FileNamingTests {
    @Test func defaultTemplates() {
        let sheet = FileNaming.expand(
            FileNaming.defaultSheetTemplate, movieFileName: "film.mp4", sheetName: "Sheet-1", fps: 25)
        #expect(sheet == "film.mp4-Sheet-1")
        let single = FileNaming.expand(
            FileNaming.defaultSingleThumbTemplate, movieFileName: "film.mp4", sheetName: "Sheet-1",
            frameNumber: 742, fps: 25)
        #expect(single == "film.mp4-frame000742")
        let individual = FileNaming.expand(
            FileNaming.defaultIndividualThumbTemplate, movieFileName: "film.mp4", sheetName: "Sheet-1",
            frameNumber: 7, fps: 25)
        #expect(individual == "film.mp4-000007")
    }

    @Test func everyTokenAndTheAlias() {
        let name = FileNaming.expand(
            "[MN]|[ME]|[SN]|[MPN]|[FN]|[TC]", movieName: "a.b", movieExtension: "mov",
            sheetName: "Sheet-2", frameNumber: 25 * 3661 + 7, fps: 25)
        // "|" is sanitized too.
        #expect(name == "a.b-mov-Sheet-2-Sheet-2-091532-01_01_01_07")
        // Without a frame number [FN] and [TC] are empty; other cases stay literal.
        #expect(FileNaming.expand("[MN]-[FN][TC]-[mn]", movieName: "x", movieExtension: "mp4",
                                  sheetName: "S", fps: 25) == "x--[mn]")
        // A value is not expanded again.
        #expect(FileNaming.expand("[SN]", movieName: "x", movieExtension: "", sheetName: "[MN]",
                                  fps: 25) == "[MN]")
    }

    @Test func splitLikeNode() {
        #expect(FileNaming.split(fileName: "a.b.mp4") == ("a.b", "mp4"))
        #expect(FileNaming.split(fileName: "noext") == ("noext", ""))
        #expect(FileNaming.split(fileName: ".hidden") == (".hidden", ""))
    }

    @Test func sanitizing() {
        #expect(FileNaming.sanitize(#"a/b\c?d%e*f:g|h"i<j>k"#) == "a-b-c-d-e-f-g-h-i-j-k")
        #expect(FileNaming.sanitize("Ünïcode film") == "Ünïcode film")
    }

    @Test func editSuffixWhenNotOverwriting() {
        let folder = URL(fileURLWithPath: "/out", isDirectory: true)
        let taken: Set<String> = ["/out/p.png", "/out/p edit 1.png"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        #expect(FileNaming.outputURL(folder: folder, baseName: "p", fileExtension: "png",
                                     overwrite: false, exists: exists).path == "/out/p edit 2.png")
        #expect(FileNaming.outputURL(folder: folder, baseName: "p", fileExtension: "png",
                                     overwrite: true, exists: exists).path == "/out/p.png")
        #expect(FileNaming.outputURL(folder: folder, baseName: "q", fileExtension: "jpg",
                                     overwrite: false, exists: exists).path == "/out/q.jpg")
        #expect(FileNaming.outputURL(folder: folder, baseName: "p", fileExtension: "png",
                                     overwrite: false, exists: { _ in true }).path == "/out/p edit 999.png")
    }

    @Test func missingFrameTokenWarning() {
        #expect(FileNaming.templateLacksFrameToken("[MN].[ME]-thumb"))
        #expect(!FileNaming.templateLacksFrameToken(FileNaming.defaultIndividualThumbTemplate))
        #expect(!FileNaming.templateLacksFrameToken("[MN]-[TC]"))
    }
}

@Suite struct IncomingFilesTests {
    @Test func sheetFilesGoToImportAndTheRestToMovies() {
        let urls = ["a.mp4", "b.png", "c.JSON", "d.Png", "e.mov", "noext", "f.json.mov", "g.mkv.json"]
            .map { URL(fileURLWithPath: "/tmp/\($0)") }
        let routed = IncomingFiles.route(urls)
        #expect(routed.sheets.map(\.lastPathComponent) == ["b.png", "c.JSON", "d.Png", "g.mkv.json"])
        #expect(routed.movies.map(\.lastPathComponent) == ["a.mp4", "e.mov", "noext", "f.json.mov"])
    }

    @Test func movieTypesAreNotSheets() {
        for name in ["clip.m4v", "clip.avi", "clip.MP4", "clip.jpg", ".png"] {
            #expect(!IncomingFiles.isSheetFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }
}

@Suite struct SheetNameMigrationTests {
    @Test func oldNamesBecomeSheetN() throws {
        #expect(SheetNaming.newSheetName(sheetCount: 2) == "Sheet-3")
        #expect(SheetNaming.migratedName("MoviePrint-12") == "Sheet-12")
        #expect(SheetNaming.migratedName("MoviePrint-") == nil)
        #expect(SheetNaming.migratedName("MoviePrint-2b") == nil)
        #expect(SheetNaming.migratedName("Opening") == nil)

        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 40, frameCount: 1000, fps: 25,
            width: 1920, height: 1080, size: 1, fourCC: "avc1")
        library.files.append(file)
        library.sheets[file.id] = [
            Sheet(name: "MoviePrint-1", type: .interval), Sheet(name: "Sequence 0 - 10", type: .interval),
        ]
        library.version = 1
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(url: dir.appending(path: "library.json"))
        try store.save(library)
        let loaded = try store.load()
        #expect(loaded.version == Library.currentVersion)
        #expect(loaded.sheets[file.id]?.map(\.name) == ["Sheet-1", "Sequence 0 - 10"])

        // A current library keeps a name the owner chose.
        var current = loaded
        current.sheets[file.id]?[0].name = "MoviePrint-1"
        try store.save(current)
        #expect(try store.load().sheets[file.id]?[0].name == "MoviePrint-1")
    }
}

@Suite struct OutputSettingsTests {
    @Test func defaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(s.outputFolder == nil)
        #expect(!s.outputSameFolderAsMovie)
        #expect(s.outputSize == 4096)
        #expect(!s.outputSizeMax)
        #expect(s.outputFormat == .png)
        #expect(s.outputQuality == 80)
        #expect(s.outputBackground == .clear)
        #expect(!s.overwrite)
        #expect(!s.includeIndividualThumbs)
        #expect(s.embedFrameNumbers)
        #expect(s.embedFilePath)
        #expect(!s.openFinderAfterSaving)
        #expect(s.thumbFormat == .jpg)
        #expect(s.thumbQuality == 95)
        #expect(s.sheetNameTemplate == "[MN].[ME]-[SN]")
        #expect(s.singleThumbNameTemplate == "[MN].[ME]-frame[FN]")
        #expect(s.individualThumbNameTemplate == "[MN].[ME]-[FN]")
        #expect(!s.showHeader)
        #expect(s.showPathInHeader && s.showDetailsInHeader && s.showTimelineInHeader)
        #expect(s == Settings())
    }

    @Test func roundTripAndTolerance() throws {
        var s = Settings()
        s.outputFolder = "/out"
        s.outputSize = 8192
        s.outputSizeMax = true
        s.outputFormat = .jpg
        s.outputBackground = RGBA(hex: 0x1E1E2E)
        s.embedFilePath = false
        s.sheetNameTemplate = "[MN]-[MPN]"
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s)
        // Off-step sizes snap; an unknown format falls back.
        let odd = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"outputSize":5000,"outputFormat":"tiff","thumbFormat":"png"}"#.utf8))
        #expect(odd.outputSize == 5120)
        #expect(odd.outputFormat == .png)
        #expect(odd.thumbFormat == .png)
        #expect(OutputSize.snapped(100_000) == 16384)
        #expect(OutputSize.snapped(0) == 1024)
        #expect(OutputSize.steps.count == 16)
    }
}

/// A small PNG made with ImageIO.
private func makePNG(width: Int = 2, height: Int = 1) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite struct PNGTextTests {
    @Test func crcOfIEND() {
        // Every PNG ends with IEND's well-known CRC AE 42 60 82.
        #expect(CRC32.checksum(Array("IEND".utf8)) == 0xAE42_6082)
    }

    @Test func writeThenRead() throws {
        let png = try makePNG()
        let entries: [(keyword: String, text: String)] = [("version", "FrameSheet 3.0.0"), ("Comment", "café [1,2]")]
        let out = try PNGText.inserting(entries, into: png)
        let read = try PNGText.entries(in: out)
        #expect(read.map(\.keyword) == ["version", "Comment"])
        #expect(read.map(\.text) == ["FrameSheet 3.0.0", "café [1,2]"])
        #expect(try PNGText.dictionary(in: out)["Comment"] == "café [1,2]")

        // Placed right before IEND, the original bytes kept around them.
        let chunks = try PNGText.parse([UInt8](out))
        #expect(chunks.suffix(3).map(\.type) == ["tEXt", "tEXt", "IEND"])
        let added = out.count - png.count
        #expect(added == entries.reduce(0) { $0 + 12 + $1.keyword.utf8.count + 1 + $1.text.count })
        #expect(out.prefix(png.count - 12) == png.prefix(png.count - 12))
        #expect(out.suffix(12) == png.suffix(12))
        // Still a valid image.
        let source = try #require(CGImageSourceCreateWithData(out as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2)
    }

    @Test func badInput() throws {
        #expect(throws: PNGText.Error.invalidPNG) { try PNGText.entries(in: Data("not a png".utf8)) }
        var png = [UInt8](try makePNG())
        png[png.count - 1] ^= 0xFF  // IEND CRC
        #expect(throws: PNGText.Error.invalidPNG) { try PNGText.entries(in: Data(png)) }
        let truncated = Data(try makePNG().dropLast(12))
        #expect(throws: PNGText.Error.missingIEND) { try PNGText.inserting([("a", "b")], into: truncated) }
        let good = try makePNG()
        #expect(throws: PNGText.Error.self) { try PNGText.inserting([("k", "日本")], into: good) }
        #expect(throws: PNGText.Error.self) { try PNGText.inserting([("k", "")], into: good) }
        #expect(throws: PNGText.Error.self) { try PNGText.inserting([("", "x")], into: good) }
    }
}

@Suite struct SheetExchangeTests {
    private func fixture(type: SheetType = .interval) -> (MovieFile, Sheet) {
        var file = MovieFile(
            url: URL(fileURLWithPath: "/Volumes/Media/Movies/Ünïcode film #1.mp4"), duration: 40,
            frameCount: 1000, fps: 25, width: 1920, height: 1080, size: 1, fourCC: "avc1")
        file.transform.rotation = 90
        file.transform.cropTop = 10
        file.transform.aspectRatioInv = 0.5625
        var sheet = Sheet(name: "Sheet-3", type: type, columnCount: 5, thumbs: [
            Thumb(frameNumber: 0, index: 0), Thumb(frameNumber: 500, index: 1, hidden: true),
            Thumb(frameNumber: 999, index: 2),
        ])
        if type == .shot {
            sheet.scenes = [
                Scene(id: sheet.thumbs[0].id, start: 0, length: 400, colorRGB: [10, 20, 30]),
                Scene(id: sheet.thumbs[2].id, start: 400, length: 600, colorRGB: [40, 50, 60]),
            ]
        }
        return (file, sheet)
    }

    @Test func pngChunksMatchMoviePrint() throws {
        let (file, sheet) = fixture()
        let data = SheetExchange(file: file, sheet: sheet, includeHidden: false, appVersion: "3.0.0")
        let entries = data.pngTextEntries()
        #expect(entries.map(\.keyword)
            == ["version", "filePath", "transformObject", "columnCount", "frameNumberArray", "sceneArray"])
        let text = Dictionary(uniqueKeysWithValues: entries.map { ($0.keyword, $0.text) })
        #expect(text["version"] == "FrameSheet 3.0.0")
        // The URL may hold the path decomposed, so compare decoded.
        let filePath = try #require(text["filePath"])
        #expect(filePath.hasPrefix("%2FVolumes%2FMedia%2FMovies%2F"))
        #expect(filePath.hasSuffix("code%20film%20%231.mp4"))
        #expect(filePath.removingPercentEncoding == file.url.path)
        #expect(SheetExchange.encodeURIComponent("/a b/\u{E9}!'()*~-_.#?%")
            == "%2Fa%20b%2F%C3%A9!'()*~-_.%23%3F%25")
        #expect(text["transformObject"]
            == #"{"cropTop":10,"cropLeft":0,"cropBottom":0,"cropRight":0,"rotationFlag":0,"aspectRatioInv":0.5625}"#)
        #expect(text["columnCount"] == "5")
        #expect(text["frameNumberArray"] == "[0,999]")
        #expect(text["sceneArray"] == "undefined")
    }

    @Test func embedOptions() throws {
        let (file, sheet) = fixture()
        let noPath = SheetExchange(file: file, sheet: sheet, includeHidden: true, embedFilePath: false)
        #expect(noPath.filePath == nil)
        #expect(noPath.frameNumbers == [0, 500, 999])
        let noFrames = SheetExchange(file: file, sheet: sheet, includeHidden: false, embedFrameData: false)
        #expect(noFrames.transform == nil && noFrames.columnCount == nil && noFrames.frameNumbers == nil)
        let text = noFrames.pngTextEntries().map(\.text)
        #expect(text.dropFirst(2).allSatisfy { $0 == "undefined" })
        let png = try noFrames.embedded(in: makePNG())
        #expect(throws: SheetExchangeError.noData) { try SheetExchange(png: png) }
    }

    @Test func pngRoundTripAndImport() throws {
        let (file, sheet) = fixture()
        let data = SheetExchange(file: file, sheet: sheet, includeHidden: false, appVersion: "3.0.0")
        let png = try data.embedded(in: makePNG())
        let read = try SheetExchange(fileData: png)
        #expect(read == data)
        #expect(read.isFrameSheet)
        #expect(read.filePath == "/Volumes/Media/Movies/Ünïcode film #1.mp4")

        var library = Library()
        let ref = try library.importSheet(read)
        let imported = try #require(library.sheet(ref.sheetId, of: ref.fileId))
        let entry = try #require(library.file(ref.fileId))
        #expect(entry.url.path == file.url.path)
        #expect(entry.name == "Ünïcode film #1.mp4")
        #expect(entry.transform.rotation == 0)  // ignored on import
        #expect(entry.transform.cropTop == 10)
        #expect(entry.transform.aspectRatioInv == 0.5625)
        #expect(imported.name == "Sheet-1")
        #expect(imported.type == .interval && imported.view == .grid)
        #expect(imported.columnCount == 5)
        #expect(imported.thumbs.map(\.frameNumber) == [0, 999])
        #expect(imported.thumbs.map(\.index) == [0, 1])
        #expect(library.currentFileId == ref.fileId && library.currentSheetId == ref.sheetId)
        #expect(library.files[0].sheetCounter == 1)
    }

    @Test func jsonRoundTrip() throws {
        let (file, sheet) = fixture()
        let data = SheetExchange(file: file, sheet: sheet, includeHidden: true, appVersion: "3.0.0")
        let json = data.jsonData()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["filePath", "transformObject", "columnCount", "frameNumberArray"])
        #expect(object["filePath"] as? String == file.url.path)  // plain, not URI-encoded
        let jsonText = String(decoding: json, as: UTF8.self)
        #expect(!jsonText.contains(#"\/"#))
        #expect(jsonText.hasPrefix("{\n\t\"filePath\": \"/Volumes/Media/Movies/"))
        var expected = data
        expected.version = nil  // not in JSON files
        #expect(try SheetExchange(fileData: json) == expected)
        #expect(SheetExchange.jsonFileName(movieFileName: "film.mp4", sheetName: "Sheet-1")
            == "film.mp4-Sheet-1.json")
        #expect(SheetExchange.jsonFileName(movieFileName: "a.mov", sheetName: "x/y") == "a.mov-x-y.json")
    }

    @Test func shotSheetScenes() throws {
        let (file, sheet) = fixture(type: .shot)
        let data = SheetExchange(file: file, sheet: sheet, includeHidden: false)
        #expect(data.frameNumbers == nil)
        #expect(data.scenes == [
            ExchangeScene(start: 0, length: 400, frameNumber: 0, colorArray: [10, 20, 30]),
            ExchangeScene(start: 400, length: 600, frameNumber: 999, colorArray: [40, 50, 60]),
        ])
        let text = data.pngTextEntries()
        #expect(text[4].text == "undefined")
        #expect(text[5].text.hasPrefix(#"[{"start":0,"length":400"#))
        let read = try SheetExchange(png: data.embedded(in: makePNG()))
        var library = Library()
        let ref = try library.importSheet(read)
        let imported = try #require(library.sheet(ref.sheetId, of: ref.fileId))
        #expect(imported.type == .shot && imported.view == .timeline)
        #expect(imported.thumbs.map(\.frameNumber) == [200, 700])  // start + length / 2
        #expect(imported.scenes.map(\.id) == imported.thumbs.map(\.id))
        #expect(imported.scenes.map(\.colorRGB) == [[10, 20, 30], [40, 50, 60]])
    }

    /// Chunks as MoviePrint 0.2.x writes them (`saveBlob`): bare version,
    /// URI-encoded path, "undefined" for an unset transform, a string
    /// column count, and no sceneArray chunk (0.2.12) or "undefined"
    /// (0.2.23). Synthetic path.
    @Test func moviePrintPNG() throws {
        let frames = (0..<21).map { $0 * 742 }
        for sceneArray in [nil, "undefined"] as [String?] {
            var entries: [(keyword: String, text: String)] = [
                ("version", "0.2.12"),
                ("filePath", "%2FVolumes%2FMedia%2FMovies%2FFree%20Videos%2Fsample.mov"),
                ("transformObject", "undefined"),
                ("columnCount", "4"),
                ("frameNumberArray", "[" + frames.map(String.init).joined(separator: ",") + "]"),
            ]
            if let sceneArray { entries.append(("sceneArray", sceneArray)) }
            let png = try PNGText.inserting(entries, into: makePNG())
            let read = try SheetExchange(fileData: png)
            #expect(!read.isFrameSheet)
            #expect(read.version == "0.2.12")
            #expect(read.filePath == "/Volumes/Media/Movies/Free Videos/sample.mov")
            #expect(read.transform == nil)
            #expect(read.columnCount == 4)
            #expect(read.frameNumbers == frames)
            #expect(read.scenes == nil)

            var library = Library()
            let ref = try library.importSheet(read)
            let sheet = try #require(library.sheet(ref.sheetId, of: ref.fileId))
            #expect(library.file(ref.fileId)?.name == "sample.mov")
            #expect(library.file(ref.fileId)?.transform == MovieTransform())
            #expect(sheet.name == "Sheet-1")
            #expect(sheet.columnCount == 4)
            #expect(sheet.thumbs.map(\.frameNumber) == frames)
        }
    }

    /// A 0.2.23 transform object (rotation flag, null aspect ratio).
    @Test func moviePrintTransform() throws {
        let json = #"{"cropTop":0,"cropLeft":4,"cropBottom":0,"cropRight":0,"rotationFlag":1,"aspectRatioInv":null}"#
        let t = try JSONDecoder().decode(ExchangeTransform.self, from: Data(json.utf8))
        #expect(t.cropLeft == 4 && t.rotationFlag == ExchangeTransform.rotate180 && t.aspectRatioInv == nil)
        #expect(t.movieTransform(keepRotation: true).rotation == 180)
        #expect(t.movieTransform(keepRotation: false).rotation == 0)
        #expect(ExchangeTransform(MovieTransform()).rotationFlag == ExchangeTransform.noRotation)
        #expect(ExchangeTransform().jsonText.rendered()
            == #"{"cropTop":0,"cropLeft":0,"cropBottom":0,"cropRight":0,"rotationFlag":3,"aspectRatioInv":null}"#)
        // JSON.stringify(value, null, "\t") layout, strings escaped.
        let pretty = JSONText.object([("a", .string(#"x"\y"#)), ("b", .array([.int(1), .number(0.5)])), ("c", .array([]))])
            .rendered(indent: "\t")
        #expect(pretty == "{\n\t\"a\": \"x\\\"\\\\y\",\n\t\"b\": [\n\t\t1,\n\t\t0.5\n\t],\n\t\"c\": []\n}")
    }

    /// MoviePrint's tab-indented JSON export (`onExportSheetClick`), with
    /// the transform absent or null and the column count a number.
    @Test func moviePrintJSON() throws {
        let absent = "{\n\t\"filePath\": \"/Volumes/Media/Movies/sample.mov\",\n\t\"columnCount\": 4,\n\t\"frameNumberArray\": [\n\t\t0,\n\t\t742,\n\t\t1484\n\t]\n}"
        let read = try SheetExchange(fileData: Data(absent.utf8))
        #expect(read.filePath == "/Volumes/Media/Movies/sample.mov")
        #expect(read.transform == nil)
        #expect(read.columnCount == 4)
        #expect(read.frameNumbers == [0, 742, 1484])
        let null = #"{"filePath":"/m/a.mov","transformObject":null,"columnCount":"3","sceneArray":[{"start":0,"length":10,"frameNumber":5,"colorArray":[1.4,2.6,3]}]}"#
        let shot = try SheetExchange(json: Data(null.utf8))
        #expect(shot.transform == nil)
        #expect(shot.columnCount == 3)
        #expect(shot.scenes == [ExchangeScene(start: 0, length: 10, frameNumber: 5, colorArray: [1, 3, 3])])
    }

    @Test func importFailures() throws {
        #expect(throws: SheetExchangeError.invalidJSON) { try SheetExchange(json: Data("nope".utf8)) }
        #expect(throws: SheetExchangeError.noData) {
            try SheetExchange(json: Data(#"{"filePath":"/m/a.mov","frameNumberArray":[]}"#.utf8))
        }
        #expect(throws: SheetExchangeError.noData) { try SheetExchange(png: makePNG()) }
        var library = Library()
        #expect(throws: SheetExchangeError.noFilePath) {
            try library.importSheet(SheetExchange(frameNumbers: [1, 2]))
        }
        #expect(library.files.isEmpty)
    }

    /// The probe fills an imported placeholder; the frames stay as imported,
    /// clamped to the last frame.
    @Test func probeFillsImportedPlaceholder() throws {
        var library = Library()
        let id = UUID()
        let ref = try library.importSheet(
            SheetExchange(filePath: "/m/a.mov", columnCount: 3, frameNumbers: [0, 742, 1484, 9000]), fileId: id)
        #expect(ref.fileId == id)
        #expect(library.file(id)?.frameCount == 0)
        let info = MediaInfo(
            duration: 200, frameCount: 5000, fps: 25, width: 1920, height: 1080, fourCC: "avc1", size: 1234)
        library.applyProbe(id, info: info)
        let file = try #require(library.file(id))
        #expect(file.duration == 200 && file.frameCount == 5000 && file.fps == 25)
        #expect(file.width == 1920 && file.height == 1080 && file.fourCC == "avc1" && file.size == 1234)
        #expect(file.posterFrame == 2500)
        #expect(file.inFrame == 0 && file.outFrame == 4999)
        let sheet = try #require(library.sheet(ref.sheetId, of: id))
        #expect(sheet.thumbs.map(\.frameNumber) == [0, 742, 1484, 4999])
        #expect(sheet.columnCount == 3)
        #expect(sheet.name == "Sheet-1")
    }

    /// The same movie imported twice gets two entries, as in MoviePrint.
    @Test func importSameMovieTwice() throws {
        var library = Library()
        let data = SheetExchange(filePath: "/m/a.mov", frameNumbers: [1, 2])
        let first = try library.importSheet(data)
        let second = try library.importSheet(data)
        #expect(first.fileId != second.fileId)
        #expect(library.files.map(\.url.path) == ["/m/a.mov", "/m/a.mov"])
        #expect(library.currentFileId == second.fileId)
    }

    /// Replace movie: relink and probe as one undo step; sheets kept, frames
    /// clamped; undo restores the old file and its data.
    @Test func replaceMovieKeepsSheets() throws {
        let file = MovieFile(
            url: URL(fileURLWithPath: "/m/a.mov"), duration: 400, frameCount: 10000, fps: 25, width: 1920,
            height: 1080, size: 99, fourCC: "hvc1")
        var start = Library()
        start.files = [file]
        start.addSheet(to: file.id, type: .interval, thumbs: [100, 5000, 9999].enumerated().map {
            Thumb(frameNumber: $1, index: $0)
        })
        var document = EditableLibrary(start)
        let info = MediaInfo(
            duration: 100, frameCount: 2500, fps: 25, width: 1280, height: 720, fourCC: "avc1", size: 7)
        document.edit { library in
            library.relink(file.id, to: URL(fileURLWithPath: "/n/b.mp4"), bookmark: nil)
            library.applyProbe(file.id, info: info)
        }
        let replaced = try #require(document.library.file(file.id))
        #expect(replaced.name == "b.mp4" && replaced.frameCount == 2500 && replaced.width == 1280)
        #expect(document.library.sheets[file.id]?.count == 1)
        #expect(document.library.sheets[file.id]?.first?.thumbs.map(\.frameNumber) == [100, 2499, 2499])
        let undone = document.undo()
        #expect(undone)
        #expect(document.library == start)
        #expect(!document.history.canUndo)
    }

    @Test func clearListAndUndo() throws {
        var start = Library()
        let ref = try start.importSheet(SheetExchange(filePath: "/m/a.mov", frameNumbers: [1, 2]))
        var document = EditableLibrary(start)
        document.edit { $0.removeAll() }
        #expect(document.library.files.isEmpty && document.library.sheets.isEmpty)
        #expect(document.library.currentFileId == nil)
        let undone = document.undo()
        #expect(undone)
        #expect(document.library == start)
        #expect(document.library.currentSheetId == ref.sheetId)
    }
}

@Suite struct PrintHeaderTests {
    @Test func headerGeometry() {
        func header(_ path: Bool, _ details: Bool, _ timeline: Bool) -> GridGeometry {
            GridGeometry(.init(
                movieWidth: 1920, movieHeight: 1080, columnCount: 4, thumbCount: 16, containerWidth: 2006.4,
                showHeader: true, showPathInHeader: path, showDetailsInHeader: details,
                showTimelineInHeader: timeline))
        }
        // 1080 × 0.25 × (1 + n / 3) × 0.25 at scale 1 (the unscaled width
        // stays 2006.4).
        #expect(abs(header(false, false, false).headerHeight - 67.5) < 1e-9)
        #expect(abs(header(true, false, false).headerHeight - 90) < 1e-9)
        #expect(abs(header(true, true, false).headerHeight - 112.5) < 1e-9)
        #expect(abs(header(true, true, true).headerHeight - 135) < 1e-9)
        #expect(abs(header(true, true, true).logoHeight - 67.5) < 1e-9)
        let g = header(true, true, true)
        #expect(abs(g.thumbFrame(at: 0).minY - (135 + 9.6 * 2)) < 1e-9)
        // Off: no height.
        let off = GridGeometry(.init(
            movieWidth: 1920, movieHeight: 1080, columnCount: 4, thumbCount: 16, containerWidth: 1000))
        #expect(off.headerHeight == 0)
        // Scales with the print.
        let half = GridGeometry(.init(
            movieWidth: 1920, movieHeight: 1080, columnCount: 4, thumbCount: 16, containerWidth: 1003.2,
            showHeader: true))
        #expect(abs(half.headerHeight - 67.5) < 1e-9)
        #expect(abs(half.logoHeight - 33.75) < 1e-9)
    }

    @Test func detailsLine() {
        var file = MovieFile(
            url: URL(fileURLWithPath: "/Volumes/Media/Movies/sample.mov"), duration: 408.5, frameCount: 9789,
            fps: 23.976, width: 1280, height: 720, size: 41_104_179, fourCC: "avc1")
        // Fields apart by an en space and a six-per-em space (about
        // 0.67 em), not MoviePrint's " | ".
        #expect(PrintHeader.detailsSeparator == "\u{2002}\u{2006}")
        let sep = PrintHeader.detailsSeparator
        #expect(PrintHeader.detailsLine(file: file)
                == "00:06:47:21\(sep)23.98 FPS\(sep)1280 × 720\(sep)39.2 MB\(sep)avc1")
        file.fps = 25
        file.size = 4 * 1024 * 1024 * 1024
        #expect(PrintHeader.detailsLine(file: file) == "00:06:31:14\(sep)25 FPS\(sep)1280 × 720\(sep)4 GB\(sep)avc1")
        #expect(!PrintHeader.detailsLine(file: file).contains("|"))
        #expect(PrintHeader.folderLine(file: file, home: "/Volumes/Home") == "/Volumes/Media/Movies/")
        #expect(PrintHeader.folderLine(file: file, home: "/Volumes/Media") == "~/Movies/")
    }

    @Test func homeAbbreviation() {
        let home = "/Volumes/Home/someone"
        #expect(PathDisplay.abbreviatingHome("/Volumes/Home/someone/Movies/a", home: home) == "~/Movies/a")
        #expect(PathDisplay.abbreviatingHome("/Volumes/Home/someone", home: home) == "~")
        #expect(PathDisplay.abbreviatingHome("/Volumes/Home/someone/", home: home + "/") == "~/")
        // Only whole components: a sibling with the same prefix stays.
        #expect(PathDisplay.abbreviatingHome("/Volumes/Home/someone2/x", home: home) == "/Volumes/Home/someone2/x")
        #expect(PathDisplay.abbreviatingHome("/Volumes/Media/x", home: home) == "/Volumes/Media/x")
        #expect(PathDisplay.abbreviatingHome("/x", home: "/") == "/x")
        #expect(PathDisplay.abbreviatingHome("/x", home: "") == "/x")
    }

    @Test func formatting() {
        #expect(PrintHeader.formatBytes(0) == "0 Bytes")
        #expect(PrintHeader.formatBytes(512) == "512 Bytes")
        #expect(PrintHeader.formatBytes(1536) == "1.5 KB")
        #expect(PrintHeader.formatNumber(29.97002997, decimals: 2) == "29.97")
        #expect(PrintHeader.formatNumber(59.94, decimals: 2) == "59.94")
        #expect(PrintHeader.formatNumber(30, decimals: 2) == "30")
    }

    @Test func miniTimeline() {
        let t = PrintHeader.timeline(frameNumbers: [250, 0, 500], frameCount: 1001)
        #expect(t.rangeStart == 0)
        #expect(abs(t.rangeWidth - 0.5) < 1e-12)
        #expect(t.thumbPositions == [0.25, 0, 0.5])
        let narrow = PrintHeader.timeline(frameNumbers: [100, 101], frameCount: 1001)
        #expect(narrow.rangeWidth == PrintHeader.minimumRangeWidth)
        #expect(PrintHeader.timeline(frameNumbers: [0], frameCount: 1).thumbPositions == [0])
        #expect(PrintHeader.timeline(frameNumbers: [], frameCount: 100).rangeStart == 0)
    }
}
