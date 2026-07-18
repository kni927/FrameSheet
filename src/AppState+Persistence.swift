import SwiftUI
import Foundation
import AppKit

// UserDefaults persistence for generation settings (Phase 2). Transient
// state (zoom, console, container size) is intentionally not persisted.
extension AppState {
    private static let settingsKey = "FrameSheetSettings.v1"

    func persistSettings() {
        guard !isLoadingSettings else { return }
        var dict: [String: Any] = [
            "columns": columns,
            "rows": rows,
            "imageWidth": imageWidth,
            "gridSpacing": gridSpacing,
            "showTimestamps": showTimestamps,
            "showHeader": showHeader,
            "useCustomHeaderTemplate": useCustomHeaderTemplate,
            "customHeaderTemplate": customHeaderTemplate,
            "cornerRadius": cornerRadius,
            "selectedFont": selectedFont,
            "customFontPath": customFontPath,
            "timestampPosition": timestampPosition,
            "startDelayPercent": startDelayPercent,
            "endDelayPercent": endDelayPercent,
            "useCustomTimestamps": useCustomTimestamps,
            "customTimestampsText": customTimestampsText,
            "outputFormat": outputFormat,
            "jpegQuality": jpegQuality,
            "filenameTemplate": filenameTemplate,
            "overwriteExisting": overwriteExisting,
            "includeIndividualFrames": includeIndividualFrames,
            "nudgeStepSeconds": nudgeStepSeconds,
        ]
        dict["backgroundColor"] = Self.encodeColor(backgroundColor)
        dict["textColor"] = Self.encodeColor(textColor)
        UserDefaults.standard.set(dict, forKey: Self.settingsKey)
    }

    func loadSettings() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.settingsKey) else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        if let v = dict["columns"] as? Int { columns = v }
        if let v = dict["rows"] as? Int { rows = v }
        if let v = dict["imageWidth"] as? Int { imageWidth = v }
        if let v = dict["gridSpacing"] as? Int { gridSpacing = v }
        if let v = dict["showTimestamps"] as? Bool { showTimestamps = v }
        if let v = dict["showHeader"] as? Bool { showHeader = v }
        if let v = dict["useCustomHeaderTemplate"] as? Bool { useCustomHeaderTemplate = v }
        if let v = dict["customHeaderTemplate"] as? String { customHeaderTemplate = v }
        if let v = dict["cornerRadius"] as? Int { cornerRadius = v }
        if let v = dict["selectedFont"] as? String { selectedFont = v }
        if let v = dict["customFontPath"] as? String { customFontPath = v }
        if let v = dict["timestampPosition"] as? String { timestampPosition = v }
        if let v = dict["startDelayPercent"] as? Double { startDelayPercent = v }
        if let v = dict["endDelayPercent"] as? Double { endDelayPercent = v }
        if let v = dict["useCustomTimestamps"] as? Bool { useCustomTimestamps = v }
        if let v = dict["customTimestampsText"] as? String { customTimestampsText = v }
        if let v = dict["outputFormat"] as? String { outputFormat = v }
        if let v = dict["jpegQuality"] as? Double { jpegQuality = v }
        if let v = dict["filenameTemplate"] as? String { filenameTemplate = v }
        if let v = dict["overwriteExisting"] as? Bool { overwriteExisting = v }
        if let v = dict["includeIndividualFrames"] as? Bool { includeIndividualFrames = v }
        if let v = dict["nudgeStepSeconds"] as? Double { nudgeStepSeconds = v }
        if let v = dict["backgroundColor"] as? [Double] { backgroundColor = Self.decodeColor(v) ?? backgroundColor }
        if let v = dict["textColor"] as? [Double] { textColor = Self.decodeColor(v) ?? textColor }
    }

    // Color <-> [r, g, b, a] in sRGB
    static func encodeColor(_ color: Color) -> [Double] {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return [0, 0, 0, 1] }
        return [Double(ns.redComponent), Double(ns.greenComponent),
                Double(ns.blueComponent), Double(ns.alphaComponent)]
    }

    static func decodeColor(_ comps: [Double]) -> Color? {
        guard comps.count == 4 else { return nil }
        return Color(.sRGB, red: comps[0], green: comps[1], blue: comps[2], opacity: comps[3])
    }
}
