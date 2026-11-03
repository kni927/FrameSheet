import CoreGraphics
import Foundation
import ImageIO

// Sizes, folders and encoding of a saved print (§6 Output, §12). The "max"
// size follows MoviePrint v0.2.23 `getMoviePrintSizeOptions`
// (app/containers/SettingsList.js, MIT, docs/licenses/MoviePrint-LICENSE).

extension GridGeometry.Input {
    /// The grid input for a movie, a column count and the global settings.
    public init(
        file: MovieFile, columnCount: Int, thumbCount: Int, settings: Settings, containerWidth: Double,
        containerHeight: Double = 99999, zoom: Double = 1
    ) {
        self.init(
            movieWidth: Double(file.width), movieHeight: Double(file.height),
            aspectRatioInv: file.transform.aspectRatioInv, columnCount: columnCount,
            thumbCount: thumbCount, containerWidth: containerWidth, containerHeight: containerHeight,
            zoom: zoom, marginRatioHorizontal: settings.marginRatioHorizontal,
            marginRatioVertical: settings.marginRatioVertical, showHeader: settings.showHeader,
            showPathInHeader: settings.showPathInHeader, showDetailsInHeader: settings.showDetailsInHeader,
            showTimelineInHeader: settings.showTimelineInHeader, borderRadiusRatio: settings.borderRadiusRatio)
    }
}

extension GridGeometry {
    /// Print height / width; the same at every scale.
    public var printAspectRatioInv: Double { printWidth > 0 ? printHeight / printWidth : 0 }

    /// The print without the window's `minPrintWidthMargin`: 1.5 margins
    /// left and right of the thumbs, the size a saved print has.
    public var printContentSize: CGSize {
        let width = max(0, printWidth - Self.minPrintWidthMargin)
        return CGSize(width: width, height: width * printAspectRatioInv)
    }

    /// The header above the thumbs: as wide as the thumb columns, from the
    /// top of the print (MoviePrint `ThumbGridHeader`: margins of one
    /// thumb margin left and two right inside a print padded by none).
    public var headerFrame: CGRect {
        let first = thumbFrame(at: 0)
        let last = thumbFrame(at: columnCount - 1)
        return CGRect(x: first.minX, y: 0, width: last.maxX - first.minX, height: headerHeight)
    }
}

public enum PrintOutput {
    /// The pixel width "max" stands for: 16384 for a print wider than tall,
    /// else the width whose height is 16384 (MoviePrint adds its max option
    /// only for prints taller than wide, at `round(limit / ratio)`).
    public static func maxWidth(printAspectRatioInv ratio: Double) -> Int {
        guard ratio > 1 else { return OutputSize.limit }
        return max(1, Int((Double(OutputSize.limit) / ratio).rounded()))
    }

    /// The width to save at: "max", or the chosen step, held to "max" so
    /// the height stays within 16384 (MoviePrint leaves taller steps out of
    /// its menu).
    public static func width(selected: Int, useMax: Bool, printAspectRatioInv ratio: Double) -> Int {
        let largest = maxWidth(printAspectRatioInv: ratio)
        return useMax ? largest : min(OutputSize.snapped(selected), largest)
    }

    /// The print's height at `width`, for the "(× H px)" label.
    public static func height(width: Int, printAspectRatioInv ratio: Double) -> Int {
        max(1, Int((Double(width) * ratio).rounded()))
    }

    /// The print laid out at `width` pixels (zoom 1, height unlimited); its
    /// `printContentSize` is `width` wide.
    public static func geometry(_ input: GridGeometry.Input, width: Int) -> GridGeometry {
        var input = input
        input.containerWidth = Double(width)
        input.containerHeight = .greatestFiniteMagnitude
        input.zoom = 1
        return GridGeometry(input)
    }

    /// Width frames are decoded at for the print: twice the thumb's width
    /// in output pixels, at most the movie's own width (§12).
    public static func decodeWidth(thumbWidth: Double, movieWidth: Int) -> Int {
        let doubled = max(1, Int((thumbWidth * 2).rounded(.up)))
        return movieWidth > 0 ? min(doubled, movieWidth) : doubled
    }

    /// The thumbs in a saved print: hidden ones only with Show hidden
    /// thumbs (drawn dimmed, as in the window).
    public static func printThumbs(of sheet: Sheet, settings: Settings) -> [Thumb] {
        settings.showHiddenThumbs ? sheet.thumbs : sheet.visibleThumbs
    }

    /// Where saved files go: the movie's folder with Same as movie file,
    /// else the chosen folder, else the Desktop.
    public static func folder(settings: Settings, movieURL: URL?, desktop: URL) -> URL {
        if settings.outputSameFolderAsMovie, let movieURL { return movieURL.deletingLastPathComponent() }
        if let path = settings.outputFolder, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return desktop
    }

    /// The folder for Include individual thumbs: next to the print, named
    /// after it without its extension (§12).
    public static func individualThumbsFolder(printURL: URL) -> URL {
        printURL.deletingLastPathComponent()
            .appending(path: printURL.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
    }

    /// The background as saved: JPG has no alpha, so the colour is opaque
    /// there (transparent becomes black).
    public static func background(_ colour: RGBA, format: ImageFormat) -> RGBA {
        guard format == .jpg else { return colour }
        var opaque = colour
        opaque.alpha = 1
        return opaque
    }

    /// The base file name of a saved print or thumb from its template; the
    /// sheet name when the template expands to nothing.
    public static func baseName(
        template: String, movieFileName: String, sheetName: String, frameNumber: Int? = nil, fps: Double
    ) -> String {
        let name = FileNaming.expand(
            template, movieFileName: movieFileName, sheetName: sheetName, frameNumber: frameNumber, fps: fps)
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? FileNaming.sanitise(sheetName) : name
    }

    /// What a save of one sheet needs: its thumbs, the pixel size and the
    /// layout at that size, and the decode width.
    public struct Plan: Sendable {
        public var thumbs: [Thumb]
        public var width: Int
        public var height: Int
        public var geometry: GridGeometry
        public var decodeWidth: Int

        public init(file: MovieFile, sheet: Sheet, settings: Settings) {
            thumbs = PrintOutput.printThumbs(of: sheet, settings: settings)
            let input = GridGeometry.Input(
                file: file, columnCount: sheet.columnCount, thumbCount: thumbs.count, settings: settings,
                containerWidth: 1000)
            let ratio = GridGeometry(input).printAspectRatioInv
            width = PrintOutput.width(
                selected: settings.outputSize, useMax: settings.outputSizeMax, printAspectRatioInv: ratio)
            height = PrintOutput.height(width: width, printAspectRatioInv: ratio)
            geometry = PrintOutput.geometry(input, width: width)
            decodeWidth = PrintOutput.decodeWidth(thumbWidth: geometry.thumbWidth, movieWidth: file.width)
        }
    }
}

public enum ImageEncodingError: Error, Equatable {
    case encodingFailed
}

/// PNG and JPG files from a CGImage (ImageIO).
public enum ImageEncoding {
    /// JPG quality is 0–100.
    public static func data(_ image: CGImage, format: ImageFormat, quality: Int) throws -> Data {
        let data = NSMutableData()
        let type = (format == .png ? "public.png" : "public.jpeg") as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw ImageEncodingError.encodingFailed
        }
        var properties: [CFString: Any] = [:]
        if format == .jpg {
            properties[kCGImageDestinationLossyCompressionQuality] = Double(min(max(quality, 0), 100)) / 100
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.encodingFailed }
        return data as Data
    }
}
