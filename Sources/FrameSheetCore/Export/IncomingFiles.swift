import Foundation
import UniformTypeIdentifiers

/// Routes files that enter the app (Add movies, drop, Import Sheet…, Open
/// With): PNGs and JSON files are sheets to import (§12); everything else is
/// added as a movie.
public enum IncomingFiles {
    /// File name extensions of sheet files, in lower case.
    public static let sheetExtensions: Set<String> = ["png", "json"]

    /// A PNG or JSON file by its extension, in any case, or by the type the
    /// extension maps to.
    public static func isSheetFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if sheetExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .png) || type.conforms(to: .json)
    }

    /// Splits `urls`, keeping their order, into movies and sheet files.
    public static func route(_ urls: [URL]) -> (movies: [URL], sheets: [URL]) {
        var movies: [URL] = []
        var sheets: [URL] = []
        for url in urls {
            if isSheetFile(url) { sheets.append(url) } else { movies.append(url) }
        }
        return (movies, sheets)
    }
}
