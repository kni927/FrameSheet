import Foundation

// Export EDL for shot sheets (§12), CMX3600 style. Ported from MoviePrint
// v0.2.23: `getEDLscenes` and `frameCountToTimeCode` (app/utils/utils.js)
// and the EDL branch of `onExportSheetClick` (app/containers/App.js)
// (MIT, docs/licenses/MoviePrint-LICENSE). As there, the reel alternates
// 000/001, the record timecodes repeat the source ones, and the frame
// count is non-drop at the movie's own fps. Unlike MoviePrint, whose
// `join` leaves the last event without one, every event gets its
// `* FROM CLIP NAME:` line, and the text ends with a newline.

public enum EDLExport {
    /// The EDL of a sheet's visible scenes (hidden scenes, or scenes whose
    /// thumb is hidden, are left out); nil for a sheet that is not a shot
    /// sheet. `fps` must be above 0.
    public static func text(file: MovieFile, sheet: Sheet) -> String? {
        guard sheet.type == .shot else { return nil }
        let scenes = SceneList.timelineScenes(of: sheet, includeHidden: false)
        return text(clipName: file.name, scenes: scenes.map { (start: $0.start, length: $0.length) }, fps: file.fps)
    }

    /// `TITLE:`, `FCM: NON-DROP FRAME`, then one event per scene, numbered
    /// from 1, each followed by `* FROM CLIP NAME:` and a blank line
    /// between events.
    public static func text(clipName: String, scenes: [(start: Int, length: Int)], fps: Double) -> String {
        let events = scenes.enumerated().map { index, scene in
            let source = timecode(scene.start, fps: fps) + " " + timecode(scene.start + scene.length, fps: fps)
            return "\(pad(index + 1, 3))  \(pad(index % 2, 3))       V     C        \(source) \(source)\n"
                + "* FROM CLIP NAME: \(clipName)\n"
        }
        return "TITLE: \(clipName)\nFCM: NON-DROP FRAME\n\n" + events.joined(separator: "\n")
    }

    /// `HH:MM:SS:FF` as MoviePrint's `frameCountToTimeCode`: seconds =
    /// frames / fps, each part floored, the frame part `frames % fps`
    /// (fractional for 29.97 and floored), two digits at least.
    public static func timecode(_ frames: Int, fps: Double) -> String {
        let f = Double(frames)
        let seconds = f / fps
        func padded(_ value: Double) -> String {
            let i = Int(value.rounded(.down))
            return i < 10 ? "0\(i)" : String(i)
        }
        return [
            padded(seconds / 3600),
            padded(seconds.truncatingRemainder(dividingBy: 3600) / 60),
            padded(seconds.truncatingRemainder(dividingBy: 60)),
            padded(f.truncatingRemainder(dividingBy: fps)),
        ].joined(separator: ":")
    }

    /// `<file>-<sheet>.edl`, the file name with its extension
    /// ("film.mp4-Sheet-1.edl"), sanitized.
    public static func fileName(movieFileName: String, sheetName: String) -> String {
        FileNaming.sanitize("\(movieFileName)-\(sheetName)") + ".edl"
    }

    /// MoviePrint's `pad`: zero-filled to `size` digits at least.
    private static func pad(_ number: Int, _ size: Int) -> String {
        let s = String(number)
        return s.count < size ? String(repeating: "0", count: size - s.count) + s : s
    }
}
