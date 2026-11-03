import Foundation

// Naming scheme for saved prints and thumbs (§6). Ported from MoviePrint
// v0.2.23 `getCustomFileName` and `getFilePathObject` (app/utils/utils.js,
// MIT, docs/licenses/MoviePrint-LICENSE), with `[SN]` for the sheet name
// and MoviePrint's `[MPN]` kept as an alias (decision 24).

public enum FileNaming {
    public static let defaultSheetTemplate = "[MN].[ME]-[SN]"
    public static let defaultSingleThumbTemplate = "[MN].[ME]-frame[FN]"
    public static let defaultIndividualThumbTemplate = "[MN].[ME]-[FN]"

    /// Characters a file name may not hold; each becomes "-".
    static let invalidCharacters: Set<Character> = ["/", "\\", "?", "%", "*", ":", "|", "\"", "<", ">"]

    /// The movie's file name split like Node's `path.parse`: the name
    /// without and the extension without the dot. A leading dot (".mov")
    /// is part of the name.
    public static func split(fileName: String) -> (name: String, extension: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, "")
        }
        return (String(fileName[..<dot]), String(fileName[fileName.index(after: dot)...]))
    }

    /// Expands `[MN]` movie name, `[ME]` extension, `[SN]` (or `[MPN]`)
    /// sheet name, `[FN]` frame number padded to 6 digits and `[TC]`
    /// timecode `HH_MM_SS_FF`, then sanitizes the result. Without a frame
    /// number `[FN]` and `[TC]` are empty. Tokens are matched in upper case
    /// only (MoviePrint's lookup fails on other cases).
    public static func expand(
        _ template: String, movieName: String, movieExtension: String, sheetName: String,
        frameNumber: Int? = nil, fps: Double
    ) -> String {
        let values: [String: String] = [
            "[MN]": movieName,
            "[ME]": movieExtension,
            "[SN]": sheetName,
            "[MPN]": sheetName,
            "[FN]": frameNumber.map { String(format: "%06d", $0) } ?? "",
            "[TC]": frameNumber.map { Timecode.string(frames: $0, fps: fps, separator: "_") } ?? "",
        ]
        var result = ""
        var rest = Substring(template)
        // One left-to-right pass, so a value is never expanded again.
        while !rest.isEmpty {
            if rest.first == "[", let token = values.keys.first(where: { rest.hasPrefix($0) }) {
                result += values[token]!
                rest = rest.dropFirst(token.count)
            } else {
                result.append(rest.removeFirst())
            }
        }
        return sanitize(result)
    }

    /// `expand` with the movie's file name ("film.mp4").
    public static func expand(
        _ template: String, movieFileName: String, sheetName: String, frameNumber: Int? = nil, fps: Double
    ) -> String {
        let parts = split(fileName: movieFileName)
        return expand(
            template, movieName: parts.name, movieExtension: parts.extension, sheetName: sheetName,
            frameNumber: frameNumber, fps: fps)
    }

    /// Replaces each of `/\?%*:|"<>` with "-".
    public static func sanitize(_ name: String) -> String {
        String(name.map { invalidCharacters.contains($0) ? "-" : $0 })
    }

    /// A thumb template without `[FN]` or `[TC]` gives every thumb the same
    /// name; the panel warns about it.
    public static func templateLacksFrameToken(_ template: String) -> Bool {
        !template.contains("[FN]") && !template.contains("[TC]")
    }

    /// `<folder>/<baseName>.<ext>`; when not overwriting and that exists,
    /// the first free `<baseName> edit N.<ext>` for N = 1…999, or the
    /// `edit 999` name when all are taken (MoviePrint `getFilePathObject`).
    public static func outputURL(
        folder: URL, baseName: String, fileExtension: String, overwrite: Bool,
        exists: (URL) -> Bool
    ) -> URL {
        func url(_ name: String) -> URL {
            folder.appending(path: "\(name).\(fileExtension)", directoryHint: .notDirectory)
        }
        var candidate = url(baseName)
        guard !overwrite, exists(candidate) else { return candidate }
        for i in 1..<1000 {
            candidate = url("\(baseName) edit \(i)")
            if !exists(candidate) { break }
        }
        return candidate
    }
}
