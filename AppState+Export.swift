import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

// Export pipeline (Phase 2): filename templating, PNG/JPEG encoding,
// save-panel export, quick save to the movie folder, and optional
// individual-frame export.
extension AppState {

    var outputFileExtension: String { outputFormat == "jpeg" ? "jpg" : "png" }

    // Resolve the output filename template. Tokens: {{filename}} (video
    // basename without extension), {{width}}, {{height}}, {{columns}},
    // {{rows}}, {{date}} (YYYY-MM-DD). No extension is appended here.
    func resolveFilenameTemplate(_ template: String? = nil) -> String {
        var t = template ?? filenameTemplate
        if t.trimmingCharacters(in: .whitespaces).isEmpty { t = "{{filename}}_sheet" }
        let base = selectedVideo.map { $0.url.deletingPathExtension().lastPathComponent } ?? "framesheet"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        t = t.replacingOccurrences(of: "{{filename}}", with: base)
        t = t.replacingOccurrences(of: "{{width}}",    with: "\(imageWidth)")
        t = t.replacingOccurrences(of: "{{height}}",   with: "\(estimatedHeight)")
        t = t.replacingOccurrences(of: "{{columns}}",  with: "\(columns)")
        t = t.replacingOccurrences(of: "{{rows}}",     with: "\(rows)")
        t = t.replacingOccurrences(of: "{{date}}",     with: formatter.string(from: Date()))
        // Strip path separators so a template can't escape the target folder
        return t.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
    }

    // Encode an image per the current format setting. JPEG cannot carry
    // alpha: when the background has transparency, composite over the
    // opaque background color first (the UI shows a warning for this case;
    // see OutputSection).
    func encodeImage(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        if outputFormat == "jpeg" {
            let source = backgroundAlpha < 1.0 ? Self.compositeOverOpaque(image, background: backgroundColor) : image
            guard let t = source.tiffRepresentation,
                  let r = NSBitmapImageRep(data: t) else { return nil }
            return r.representation(using: .jpeg,
                                    properties: [.compressionFactor: jpegQuality / 100.0])
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func compositeOverOpaque(_ image: NSImage, background: Color) -> NSImage {
        let size = image.pixelSize
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let opaque = NSColor(background).usingColorSpace(.sRGB)?.withAlphaComponent(1.0) ?? .black
        opaque.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return image }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    // Return `base.ext` in `folder`, auto-suffixing `_2`, `_3`, … when
    // "Overwrite existing" is off and the target already exists.
    func uniqueTargetURL(folder: URL, base: String, ext: String) -> URL {
        let direct = folder.appendingPathComponent("\(base).\(ext)")
        if overwriteExisting || !FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base)_\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // Save generated image to a user-chosen location (save panel prefilled
    // from the filename template).
    func saveImageAs() {
        guard let image = previewImage else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = outputFormat == "jpeg" ? [.jpeg] : [.png]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "\(resolveFilenameTemplate()).\(outputFileExtension)"

        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                self.writeSheet(image, to: targetURL, framesFolder: targetURL.deletingLastPathComponent())
            }
        }
    }

    // Save directly into the source video's folder using the template —
    // no dialog.
    func quickSaveToMovieFolder() {
        guard let image = previewImage, let video = selectedVideo else { return }
        let folder = video.url.deletingLastPathComponent()
        let target = uniqueTargetURL(folder: folder,
                                     base: resolveFilenameTemplate(),
                                     ext: outputFileExtension)
        writeSheet(image, to: target, framesFolder: folder)
    }

    // Encode + write the sheet (and individual frames when enabled).
    private func writeSheet(_ image: NSImage, to targetURL: URL, framesFolder: URL) {
        guard let data = encodeImage(image) else {
            self.errorMessage = "Failed to encode image."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try data.write(to: targetURL)
            self.consoleOutput += "Saved image to: \(targetURL.path)\n"
        } catch {
            self.errorMessage = "Failed to save file: \(error.localizedDescription)"
            return
        }
        if includeIndividualFrames {
            saveIndividualFrames(baseName: targetURL.deletingPathExtension().lastPathComponent,
                                 in: framesFolder)
        }
    }

    // Write each thumbnail frame into a `<base>_frames/` subfolder as
    // `<base>_NN.<ext>` (zero-padded), honoring the format setting.
    private func saveIndividualFrames(baseName: String, in folder: URL) {
        guard !thumbnails.isEmpty else { return }
        let framesDir = folder.appendingPathComponent("\(baseName)_frames", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        } catch {
            self.errorMessage = "Failed to create frames folder: \(error.localizedDescription)"
            return
        }
        let pad = max(2, String(thumbnails.count).count)
        var written = 0
        for (i, thumb) in thumbnails.enumerated() {
            guard let img = NSImage(contentsOfFile: thumb.imagePath),
                  let data = encodeImage(img) else { continue }
            let name = String(format: "%@_%0*d.%@", baseName, pad, i + 1, outputFileExtension)
            let url = framesDir.appendingPathComponent(name)
            if (try? data.write(to: url)) != nil { written += 1 }
        }
        self.consoleOutput += "Saved \(written)/\(thumbnails.count) individual frames to: \(framesDir.path)\n"
        if written < thumbnails.count {
            self.errorMessage = "Some individual frames could not be saved (\(written)/\(thumbnails.count)). The source frames may have been cleaned up — regenerate and try again."
        }
    }
}
