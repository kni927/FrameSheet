import Foundation

// Sheet data embedded in a saved PNG and written by Export JSON (§12), in
// MoviePrint v0.2.23's shapes so either app reads the other's files:
// `prepareDataToExportOrEmbed` and `getSceneArrayForExport`
// (app/utils/utils.js), `saveBlob` (app/utils/saveMoviePrint.js) and
// `onImportMoviePrint` and `onExportSheetClick` (app/containers/App.js)
// (MIT, docs/licenses/MoviePrint-LICENSE).

/// MoviePrint's `transformObject`. Rotation is OpenCV's `RotateFlags`.
public struct ExchangeTransform: Decodable, Sendable, Equatable {
    public static let rotate90Clockwise = 0
    public static let rotate180 = 1
    public static let rotate90CounterClockwise = 2
    /// MoviePrint's artificial "no rotation" flag.
    public static let noRotation = 3

    public var cropTop = 0
    public var cropLeft = 0
    public var cropBottom = 0
    public var cropRight = 0
    public var rotationFlag = ExchangeTransform.noRotation
    public var aspectRatioInv: Double?

    public init() {}

    public init(_ transform: MovieTransform) {
        cropTop = transform.cropTop
        cropLeft = transform.cropLeft
        cropBottom = transform.cropBottom
        cropRight = transform.cropRight
        rotationFlag = switch transform.rotation {
        case 90: Self.rotate90Clockwise
        case 180: Self.rotate180
        case 270: Self.rotate90CounterClockwise
        default: Self.noRotation
        }
        aspectRatioInv = transform.aspectRatioInv
    }

    /// The transform for a movie entry; `keepRotation` false gives 0°, as
    /// on import (§12; MoviePrint ignores the flag there too).
    public func movieTransform(keepRotation: Bool) -> MovieTransform {
        var t = MovieTransform()
        t.cropTop = cropTop
        t.cropLeft = cropLeft
        t.cropBottom = cropBottom
        t.cropRight = cropRight
        if keepRotation {
            t.rotation = switch rotationFlag {
            case Self.rotate90Clockwise: 90
            case Self.rotate180: 180
            case Self.rotate90CounterClockwise: 270
            default: 0
            }
        }
        // MoviePrint: `aspectRatioInv || null`, so 0 means none.
        t.aspectRatioInv = aspectRatioInv.flatMap { $0 > 0 ? $0 : nil }
        return t
    }

    private enum CodingKeys: String, CodingKey {
        case cropTop, cropLeft, cropBottom, cropRight, rotationFlag, aspectRatioInv
    }

    /// Missing values default as in MoviePrint's import (`|| 0`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cropTop = c.flexibleInt(.cropTop) ?? 0
        cropLeft = c.flexibleInt(.cropLeft) ?? 0
        cropBottom = c.flexibleInt(.cropBottom) ?? 0
        cropRight = c.flexibleInt(.cropRight) ?? 0
        rotationFlag = c.flexibleInt(.rotationFlag) ?? Self.noRotation
        aspectRatioInv = try? c.decodeIfPresent(Double.self, forKey: .aspectRatioInv)
    }

    /// Every key in MoviePrint's order (`TRANSFORMOBJECT_INIT`), with an
    /// explicit `null` aspect ratio.
    var jsonText: JSONText {
        .object([
            ("cropTop", .int(cropTop)), ("cropLeft", .int(cropLeft)), ("cropBottom", .int(cropBottom)),
            ("cropRight", .int(cropRight)), ("rotationFlag", .int(rotationFlag)),
            ("aspectRatioInv", aspectRatioInv.map(JSONText.number) ?? .null),
        ])
    }
}

/// One entry of MoviePrint's exported `sceneArray`.
public struct ExchangeScene: Decodable, Sendable, Equatable {
    public var start: Int
    public var length: Int
    /// The scene's thumb frame; written, not read back (import uses the
    /// middle frame like MoviePrint's `addScenesFromSceneList`).
    public var frameNumber: Int?
    /// sRGB 0–255.
    public var colorArray: [Int]?

    public init(start: Int, length: Int, frameNumber: Int? = nil, colorArray: [Int]? = nil) {
        self.start = start
        self.length = length
        self.frameNumber = frameNumber
        self.colorArray = colorArray
    }

    private enum CodingKeys: String, CodingKey {
        case start, length, frameNumber, colorArray
    }

    /// In `getSceneArrayForExport`'s order.
    var jsonText: JSONText {
        var members: [(String, JSONText)] = [("start", .int(start)), ("length", .int(length))]
        if let frameNumber { members.append(("frameNumber", .int(frameNumber))) }
        if let colorArray { members.append(("colorArray", .array(colorArray.map(JSONText.int)))) }
        return .object(members)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = c.flexibleInt(.start), let length = c.flexibleInt(.length) else {
            throw DecodingError.dataCorruptedError(
                forKey: .start, in: c, debugDescription: "A scene needs start and length")
        }
        self.start = start
        self.length = length
        frameNumber = c.flexibleInt(.frameNumber)
        // OpenCV means may be fractional.
        colorArray = (try? c.decodeIfPresent([Double].self, forKey: .colorArray))?.map { Int($0.rounded()) }
    }
}

public enum SheetExchangeError: Error, Equatable {
    /// Neither a frame list nor scenes (MoviePrint: "No fitting data found
    /// or embedded").
    case noData
    /// No movie path to create the entry from.
    case noFilePath
    case invalidJSON
}

/// The exchanged data. Nil fields were left out (embed options off, or
/// MoviePrint's "undefined" text in a PNG).
public struct SheetExchange: Sendable, Equatable {
    /// `version` chunk text: FrameSheet writes "FrameSheet <version>",
    /// MoviePrint its bare app version ("0.2.23"). Not in JSON files.
    public var version: String?
    /// The movie's plain path.
    public var filePath: String?
    public var transform: ExchangeTransform?
    public var columnCount: Int?
    /// Non-shot sheets.
    public var frameNumbers: [Int]?
    /// Shot sheets.
    public var scenes: [ExchangeScene]?

    public static let versionPrefix = "FrameSheet "
    /// MoviePrint writes absent values as the text "undefined"
    /// (`String(undefined)` in png-chunk-text).
    static let undefinedText = "undefined"

    public init(
        version: String? = nil, filePath: String? = nil, transform: ExchangeTransform? = nil,
        columnCount: Int? = nil, frameNumbers: [Int]? = nil, scenes: [ExchangeScene]? = nil
    ) {
        self.version = version
        self.filePath = filePath
        self.transform = transform
        self.columnCount = columnCount
        self.frameNumbers = frameNumbers
        self.scenes = scenes
    }

    /// The data for a sheet (`prepareDataToExportOrEmbed`): `embedFilePath`
    /// off leaves out the path, `embedFrameData` off the transform, columns
    /// and frames. Hidden thumbs (and hidden scenes) are left out unless
    /// `includeHidden`, as in the print. `version` is the app version, to
    /// which "FrameSheet " is prefixed.
    public init(
        file: MovieFile, sheet: Sheet, includeHidden: Bool, embedFilePath: Bool = true,
        embedFrameData: Bool = true, appVersion: String? = nil
    ) {
        version = appVersion.map { Self.versionPrefix + $0 }
        if embedFilePath { filePath = file.url.path }
        guard embedFrameData else { return }
        transform = ExchangeTransform(file.transform)
        columnCount = sheet.columnCount
        if sheet.type == .shot {
            let frameById = Dictionary(sheet.thumbs.map { ($0.id, $0.frameNumber) }, uniquingKeysWith: { a, _ in a })
            // A scene counts as hidden when it or its thumb is.
            scenes = SceneList.timelineScenes(of: sheet, includeHidden: includeHidden).map {
                ExchangeScene(start: $0.start, length: $0.length, frameNumber: frameById[$0.id], colorArray: $0.colorRGB)
            }
        } else {
            frameNumbers = sheet.thumbs.filter { includeHidden || !$0.hidden }.map(\.frameNumber)
        }
    }

    /// Written by FrameSheet (not MoviePrint).
    public var isFrameSheet: Bool { version?.hasPrefix(Self.versionPrefix) ?? false }

    /// Frames or scenes to build a sheet from.
    public var hasSheetData: Bool { !(frameNumbers ?? []).isEmpty || !(scenes ?? []).isEmpty }

    // MARK: PNG chunks

    /// The six chunks MoviePrint writes, in its order; left-out values are
    /// "undefined" as MoviePrint writes them, since its import expects
    /// every key.
    public func pngTextEntries() -> [(keyword: String, text: String)] {
        func json(_ value: JSONText?) -> String { value?.rendered() ?? Self.undefinedText }
        return [
            ("version", version ?? Self.undefinedText),
            ("filePath", filePath.map(Self.encodeURIComponent) ?? Self.undefinedText),
            ("transformObject", json(transform?.jsonText)),
            ("columnCount", columnCount.map(String.init) ?? Self.undefinedText),
            ("frameNumberArray", json(frameNumbers.map { .array($0.map(JSONText.int)) })),
            ("sceneArray", json(scenes.map { .array($0.map(\.jsonText)) })),
        ]
    }

    /// The PNG with the data in `tEXt` chunks before IEND.
    public func embedded(in png: Data) throws -> Data {
        try PNGText.inserting(pngTextEntries(), into: png)
    }

    /// Reads chunks written by FrameSheet or MoviePrint 0.2.x; the path is
    /// URI-decoded. Unreadable values count as left out.
    public init(pngText: [String: String]) {
        func value(_ key: String) -> String? {
            guard let text = pngText[key], text != Self.undefinedText, !text.isEmpty else { return nil }
            return text
        }
        func json<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            value(key).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
        }
        version = value("version")
        filePath = value("filePath").map { $0.removingPercentEncoding ?? $0 }
        transform = json("transformObject", as: ExchangeTransform.self)
        columnCount = value("columnCount").flatMap(Self.parseInt)
        frameNumbers = json("frameNumberArray", as: [Double].self)?.map { Int($0.rounded()) }
        scenes = json("sceneArray", as: [ExchangeScene].self)
    }

    /// Reads the embedded data of a PNG; `noData` when it has none.
    public init(png: Data) throws {
        let text = try PNGText.dictionary(in: png)
        self.init(pngText: text)
        guard hasSheetData else { throw SheetExchangeError.noData }
    }

    // MARK: JSON file

    /// `{filePath, transformObject, columnCount, frameNumberArray |
    /// sceneArray}` with the plain path; left-out values are omitted like
    /// `JSON.stringify` omits undefined.
    public func jsonData() -> Data {
        var members: [(String, JSONText)] = []
        if let filePath { members.append(("filePath", .string(filePath))) }
        if let transform { members.append(("transformObject", transform.jsonText)) }
        if let columnCount { members.append(("columnCount", .int(columnCount))) }
        if let frameNumbers { members.append(("frameNumberArray", .array(frameNumbers.map(JSONText.int)))) }
        if let scenes { members.append(("sceneArray", .array(scenes.map(\.jsonText)))) }
        return Data(JSONText.object(members).rendered(indent: "\t").utf8)
    }

    public init(json: Data) throws {
        let file: JSONFile
        do {
            file = try JSONDecoder().decode(JSONFile.self, from: json)
        } catch {
            throw SheetExchangeError.invalidJSON
        }
        self.init(
            filePath: file.filePath, transform: file.transformObject, columnCount: file.columnCount,
            frameNumbers: file.frameNumberArray, scenes: file.sceneArray)
        guard hasSheetData else { throw SheetExchangeError.noData }
    }

    /// A PNG (by its signature) or a JSON file.
    public init(fileData: Data) throws {
        if fileData.starts(with: PNGText.signature) {
            try self.init(png: fileData)
        } else {
            try self.init(json: fileData)
        }
    }

    /// `<file>-<sheet>.json`, the file name with its extension
    /// ("film.mp4-Sheet-1.json"), sanitized.
    public static func jsonFileName(movieFileName: String, sheetName: String) -> String {
        FileNaming.sanitize("\(movieFileName)-\(sheetName)") + ".json"
    }

    private struct JSONFile: Decodable {
        var filePath: String?
        var transformObject: ExchangeTransform?
        var columnCount: Int?
        var frameNumberArray: [Int]?
        var sceneArray: [ExchangeScene]?

        private enum CodingKeys: String, CodingKey {
            case filePath, transformObject, columnCount, frameNumberArray, sceneArray
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            filePath = try? c.decodeIfPresent(String.self, forKey: .filePath)
            transformObject = try? c.decodeIfPresent(ExchangeTransform.self, forKey: .transformObject)
            // MoviePrint reads `Number(columnCount)`.
            columnCount = c.flexibleInt(.columnCount)
            frameNumberArray = (try? c.decodeIfPresent([Double].self, forKey: .frameNumberArray))?
                .map { Int($0.rounded()) }
            sceneArray = try? c.decodeIfPresent([ExchangeScene].self, forKey: .sceneArray)
        }
    }

    /// JavaScript `encodeURIComponent`: UTF-8, everything but
    /// `A–Z a–z 0–9 - _ . ! ~ * ' ( )` percent-encoded.
    static func encodeURIComponent(_ string: String) -> String {
        var allowed = CharacterSet(charactersIn: "-_.!~*'()")
        allowed.formUnion(CharacterSet(charactersIn: "a"..."z"))
        allowed.formUnion(CharacterSet(charactersIn: "A"..."Z"))
        allowed.formUnion(CharacterSet(charactersIn: "0"..."9"))
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// JavaScript `Number(text)` for a whole number ("4", "4.0").
    static func parseInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let i = Int(trimmed) { return i }
        guard let d = Double(trimmed), d.isFinite else { return nil }
        return Int(d.rounded())
    }
}

/// A JSON value written with its keys in order, as `JSON.stringify`
/// writes them (JSONEncoder does not keep key order).
indirect enum JSONText {
    case int(Int)
    case number(Double)
    case string(String)
    case null
    case array([JSONText])
    case object([(String, JSONText)])

    /// Compact, or pretty with `indent` per level like
    /// `JSON.stringify(value, null, indent)`.
    func rendered(indent: String? = nil, level: Int = 0) -> String {
        switch self {
        case .int(let i): return String(i)
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
            return d.isFinite ? "\(d)" : "null"
        case .string(let s): return Self.quoted(s)
        case .null: return "null"
        case .array(let items):
            return Self.container("[", "]", items.map { $0.rendered(indent: indent, level: level + 1) }, indent, level)
        case .object(let members):
            let separator = indent == nil ? ":" : ": "
            return Self.container("{", "}", members.map {
                Self.quoted($0.0) + separator + $0.1.rendered(indent: indent, level: level + 1)
            }, indent, level)
        }
    }

    private static func container(
        _ open: String, _ close: String, _ items: [String], _ indent: String?, _ level: Int
    ) -> String {
        guard let indent, !items.isEmpty else { return open + items.joined(separator: ",") + close }
        let inner = String(repeating: indent, count: level + 1)
        let outer = String(repeating: indent, count: level)
        return open + "\n" + items.map { inner + $0 }.joined(separator: ",\n") + "\n" + outer + close
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension KeyedDecodingContainer {
    /// An integer written as a number (whole or not) or a numeric string.
    func flexibleInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int(d.rounded()) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return SheetExchange.parseInt(s) }
        return nil
    }
}

extension Library {
    /// Adds an imported sheet (§12): a new movie entry for the embedded
    /// path and a `Sheet-N` sheet, interval/grid for a frame list or
    /// shot/timeline for scenes, and makes it current. The entry is a
    /// placeholder (no duration, size or frame count) until the app probes
    /// the movie (`applyProbe`), or the owner locates a missing one. A movie
    /// already in the list still gets a new entry, as in MoviePrint.
    /// Rotation is ignored. `fileId` is the new entry's id.
    @discardableResult
    public mutating func importSheet(_ data: SheetExchange, fileId: UUID = UUID()) throws -> SheetRef {
        guard data.hasSheetData else { throw SheetExchangeError.noData }
        guard let path = data.filePath, !path.isEmpty else { throw SheetExchangeError.noFilePath }
        var file = MovieFile(
            id: fileId, url: URL(fileURLWithPath: path), duration: 0, frameCount: 0, fps: 0, width: 0,
            height: 0, size: 0, fourCC: "")
        if let transform = data.transform { file.transform = transform.movieTransform(keepRotation: false) }
        files.append(file)

        let sheet: Sheet?
        if let frames = data.frameNumbers, !frames.isEmpty {
            let thumbs = frames.enumerated().map { Thumb(frameNumber: $1, index: $0) }
            sheet = addSheet(to: file.id, type: .interval, view: .grid, thumbs: thumbs)
        } else {
            let list = data.scenes ?? []
            let thumbs = list.enumerated().map { Thumb(frameNumber: $1.start + $1.length / 2, index: $0) }
            sheet = addSheet(to: file.id, type: .shot, view: .timeline, thumbs: thumbs)
            if let sheet, let i = sheets[file.id]?.firstIndex(where: { $0.id == sheet.id }) {
                sheets[file.id]![i].scenes = zip(list, thumbs).map { scene, thumb in
                    Scene(id: thumb.id, start: scene.start, length: scene.length,
                          colorRGB: scene.colorArray ?? [128, 128, 128])
                }
            }
        }
        guard let sheet, let i = sheets[file.id]?.firstIndex(where: { $0.id == sheet.id }) else {
            throw SheetExchangeError.noData
        }
        sheets[file.id]![i].columnCount = max(1, data.columnCount ?? Defaults.columnCount)
        currentFileId = file.id
        currentSheetId = sheet.id
        return SheetRef(fileId: file.id, sheetId: sheet.id)
    }
}
