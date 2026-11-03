import CoreGraphics
import Foundation
import Testing
@testable import FrameSheetCore

@Suite struct PrintOutputTests {
    private func input(columns: Int, thumbs: Int, header: Bool = false) -> GridGeometry.Input {
        GridGeometry.Input(
            movieWidth: 1920, movieHeight: 1080, columnCount: columns, thumbCount: thumbs,
            containerWidth: 1000, showHeader: header)
    }

    private func file() -> MovieFile {
        MovieFile(
            url: URL(fileURLWithPath: "/movies/film.mp4"), duration: 100, frameCount: 2500, fps: 25,
            width: 1920, height: 1080, size: 1_000_000, fourCC: "avc1")
    }

    @Test func maxIsTheLimitForWidePrints() {
        // 4 × 4 at 16:9: 2006.4 wide, 1176 high.
        let ratio = GridGeometry(input(columns: 4, thumbs: 16)).printAspectRatioInv
        #expect(abs(ratio - 1176 / 2006.4) < 1e-9)
        #expect(PrintOutput.maxWidth(printAspectRatioInv: ratio) == 16384)
        #expect(PrintOutput.width(selected: 4096, useMax: false, printAspectRatioInv: ratio) == 4096)
        #expect(PrintOutput.width(selected: 4096, useMax: true, printAspectRatioInv: ratio) == 16384)
        #expect(PrintOutput.height(width: 4096, printAspectRatioInv: ratio) == 2401)
    }

    @Test func maxKeepsTallPrintsWithin16384() {
        // 2 columns × 10 rows: 1008 wide, 2911.2 high.
        let ratio = GridGeometry(input(columns: 2, thumbs: 20)).printAspectRatioInv
        #expect(abs(ratio - 2911.2 / 1008) < 1e-9)
        let largest = PrintOutput.maxWidth(printAspectRatioInv: ratio)
        #expect(largest == 5673)
        #expect(PrintOutput.height(width: largest, printAspectRatioInv: ratio) == 16384)
        // A larger step is held to max, a smaller one kept.
        #expect(PrintOutput.width(selected: 8192, useMax: false, printAspectRatioInv: ratio) == 5673)
        #expect(PrintOutput.width(selected: 4096, useMax: false, printAspectRatioInv: ratio) == 4096)
        // Off-step values snap.
        #expect(PrintOutput.width(selected: 3000, useMax: false, printAspectRatioInv: ratio) == 3072)
    }

    @Test func outputGeometryFillsTheWidthSymmetrically() {
        let g = PrintOutput.geometry(input(columns: 4, thumbs: 16, header: true), width: 4096)
        let size = g.printContentSize
        #expect(abs(size.width - 4096) < 1e-6)
        #expect(abs(size.height - 4096 * g.printAspectRatioInv) < 1e-6)
        let first = g.thumbFrame(at: 0)
        let last = g.thumbFrame(at: 3)
        #expect(abs(first.minX - (size.width - last.maxX)) < 1e-6)
        // The last row ends a bottom margin pair above the print's end.
        let bottom = g.thumbFrame(at: 15).maxY
        #expect(abs(size.height - bottom - 2 * g.thumbMarginVertical) < 1e-6)
        // The header spans the thumb columns above the first row.
        #expect(g.headerFrame == CGRect(x: first.minX, y: 0, width: last.maxX - first.minX, height: g.headerHeight))
        #expect(g.headerFrame.maxY < first.minY)
    }

    @Test func decodeWidthIsTwiceTheThumbCappedAtTheMovie() {
        #expect(PrintOutput.decodeWidth(thumbWidth: 400, movieWidth: 1920) == 800)
        #expect(PrintOutput.decodeWidth(thumbWidth: 400.2, movieWidth: 1920) == 801)
        #expect(PrintOutput.decodeWidth(thumbWidth: 980, movieWidth: 1920) == 1920)
        // Unknown movie width: not capped.
        #expect(PrintOutput.decodeWidth(thumbWidth: 980, movieWidth: 0) == 1960)
    }

    @Test func planUsesThePrintThumbs() {
        var settings = Settings()
        var sheet = Sheet(name: "Sheet-1", type: .interval, thumbs: (0..<16).map { Thumb(frameNumber: $0 * 100, index: $0) })
        sheet.thumbs[3].hidden = true
        let hiddenLeftOut = PrintOutput.Plan(file: file(), sheet: sheet, settings: settings)
        #expect(hiddenLeftOut.thumbs.count == 15)
        #expect(hiddenLeftOut.width == 4096)
        settings.showHiddenThumbs = true
        settings.outputSizeMax = true
        let all = PrintOutput.Plan(file: file(), sheet: sheet, settings: settings)
        #expect(all.thumbs.count == 16)
        #expect(all.width == 16384)
        #expect(abs(all.geometry.printContentSize.width - 16384) < 1e-6)
        #expect(all.height == PrintOutput.height(width: 16384, printAspectRatioInv: all.geometry.printAspectRatioInv))
        // Thumbs about 4000 px wide: decoded at the movie's 1920.
        #expect(all.decodeWidth == 1920)
    }

    @Test func folders() {
        let desktop = URL(fileURLWithPath: "/desk", isDirectory: true)
        let movie = URL(fileURLWithPath: "/movies/film.mp4")
        var settings = Settings()
        #expect(PrintOutput.folder(settings: settings, movieURL: movie, desktop: desktop) == desktop)
        settings.outputFolder = "/out"
        #expect(PrintOutput.folder(settings: settings, movieURL: movie, desktop: desktop).path == "/out")
        settings.outputSameFolderAsMovie = true
        #expect(PrintOutput.folder(settings: settings, movieURL: movie, desktop: desktop).path == "/movies")
        // No movie: the chosen folder.
        #expect(PrintOutput.folder(settings: settings, movieURL: nil, desktop: desktop).path == "/out")
        let print = URL(fileURLWithPath: "/out/film.mp4-Sheet-1 edit 2.png")
        #expect(PrintOutput.individualThumbsFolder(printURL: print).path == "/out/film.mp4-Sheet-1 edit 2")
    }

    @Test func backgroundIsOpaqueInJPG() {
        let half = RGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        #expect(PrintOutput.background(half, format: .png) == half)
        #expect(PrintOutput.background(half, format: .jpg) == RGBA(red: 0.2, green: 0.4, blue: 0.6))
        #expect(PrintOutput.background(.clear, format: .jpg) == RGBA(red: 0, green: 0, blue: 0))
    }

    @Test func baseNameFallsBackToTheSheet() {
        #expect(PrintOutput.baseName(template: "[MN]-[FN]", movieFileName: "a.mov", sheetName: "Sheet-2",
                                     frameNumber: 5, fps: 25) == "a-000005")
        #expect(PrintOutput.baseName(template: "[FN]", movieFileName: "a.mov", sheetName: "Sheet-2", fps: 25)
                == "Sheet-2")
    }

    @Test func headerContentFitsTheHeader() {
        for path in [false, true] {
            for details in [false, true] {
                for timeline in [false, true] {
                    var i = input(columns: 4, thumbs: 16, header: true)
                    i.showPathInHeader = path
                    i.showDetailsInHeader = details
                    i.showTimelineInHeader = timeline
                    let g = GridGeometry(i)
                    let m = PrintHeader.Metrics(logoHeight: g.logoHeight)
                    #expect(m.contentHeight(path: path, details: details, timeline: timeline) <= g.headerHeight + 1e-9)
                }
            }
        }
        let m = PrintHeader.Metrics(logoHeight: 100)
        #expect(m.unit == 25)
        #expect(m.imageSize == 50)
        #expect(abs(m.titleSize - 37.5) < 1e-9)
        #expect(abs(m.timelineHeight - 30) < 1e-9)
    }

    private func image(width: Int, height: Int, alpha: Bool) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.5, green: 0.2, blue: 0.8, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func encodesPNGWithEmbeddedDataAndJPG() throws {
        let png = try ImageEncoding.data(image(width: 8, height: 4, alpha: true), format: .png, quality: 80)
        #expect(png.starts(with: PNGText.signature))
        let sheet = Sheet(name: "Sheet-1", type: .interval, columnCount: 2,
                          thumbs: [Thumb(frameNumber: 10, index: 0), Thumb(frameNumber: 20, index: 1)])
        let exchange = SheetExchange(file: file(), sheet: sheet, includeHidden: false, appVersion: "3.0.0")
        let embedded = try exchange.embedded(in: png)
        let read = try SheetExchange(png: embedded)
        #expect(read.frameNumbers == [10, 20])
        #expect(read.columnCount == 2)
        #expect(read.filePath == "/movies/film.mp4")
        #expect(read.version == "FrameSheet 3.0.0")

        let jpg = try ImageEncoding.data(image(width: 8, height: 4, alpha: false), format: .jpg, quality: 80)
        #expect(jpg.starts(with: [0xFF, 0xD8]))
        let small = try ImageEncoding.data(image(width: 64, height: 64, alpha: false), format: .jpg, quality: 0)
        let large = try ImageEncoding.data(image(width: 64, height: 64, alpha: false), format: .jpg, quality: 100)
        #expect(small.count <= large.count)
    }
}
