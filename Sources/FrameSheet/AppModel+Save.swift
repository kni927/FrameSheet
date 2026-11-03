import AppKit
import FrameSheetCore
import SwiftUI

/// Progress of a save, for the toast.
struct SaveProgress: Equatable {
    var message: String
    /// 0–1; nil shows an indeterminate bar.
    var fraction: Double?
}

struct SaveError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Save Sheet, Save thumb, individual thumbs and Export JSON (§12).
extension AppModel {
    /// The folder saved files go to for a movie (or none).
    func outputFolder(for file: MovieFile?) -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
        return PrintOutput.folder(settings: library.settings, movieURL: file?.url, desktop: desktop)
    }

    /// Opens the current movie's output folder in the Finder.
    func openOutputLocation() {
        let folder = outputFolder(for: currentFile)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            toast = "The output folder does not exist: \(folder.path)"
            return
        }
        NSWorkspace.shared.open(folder)
    }

    /// Change… in the Output section.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder for saved sheets"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder(for: currentFile)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateSettings { $0.outputFolder = url.path }
    }

    /// The layout and size a save of the current sheet would use.
    var currentSavePlan: PrintOutput.Plan? {
        guard let file = currentFile, let sheet = currentSheet else { return nil }
        return PrintOutput.Plan(file: file, sheet: sheet, settings: library.settings)
    }

    var isSaving: Bool { progress != nil }

    /// Shows a confirmation that clears itself after a few seconds.
    func showNotice(_ message: String) {
        toast = nil
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == message { notice = nil }
        }
    }

    func cancelSave() { saveJob?.cancel() }

    /// Save Sheet (key M): decodes the print's frames fresh at about twice
    /// their size in the print, in small sequential batches through the
    /// movie's backend (never in parallel; the AVFoundation backend holds the
    /// DecodeGate per batch); renders `PrintView` offscreen at the output
    /// width; encodes and writes PNG (with the embedded sheet data) or JPG
    /// off the main actor; then the individual thumbs when asked. The toast
    /// shows each stage; Cancel stops between frames and between stages.
    func saveSheet() {
        guard !isSaving else { return }
        if let id = library.currentFileId { checkMovieFile(id) }
        guard let file = currentFile, let sheet = currentSheet else { return }
        guard !missing.contains(file.id) else {
            toast = "\(file.name): the movie is missing."
            return
        }
        let settings = library.settings
        let plan = PrintOutput.Plan(file: file, sheet: sheet, settings: settings)
        guard !plan.thumbs.isEmpty else {
            toast = "\(sheet.name) has no thumbs to save."
            return
        }
        progress = SaveProgress(message: "Saving \(sheet.name)…", fraction: nil)
        saveJob = Task {
            defer {
                progress = nil
                saveJob = nil
            }
            do {
                let (url, failures, fromWindow) = try await writeSheet(
                    file: file, sheet: sheet, settings: settings, plan: plan)
                showNotice("Saved \(url.lastPathComponent)")
                if failures + fromWindow > 0, !checkMovieFile(file.id), missing.contains(file.id) {
                    toast = "\(file.name): the movie is missing."
                } else if failures + fromWindow > 0 {
                    // The window's thumbs are 640 px wide, often less than
                    // the print's, so the save says when it used them.
                    toast = "\(file.name): \(failures + fromWindow) frame(s) could not be decoded for the print"
                        + (fromWindow > 0 ? "; \(fromWindow) use the window's thumb." : ".")
                }
                if settings.openFinderAfterSaving { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch is CancellationError {
                showNotice("Saving canceled.")
            } catch {
                toast = !checkMovieFile(file.id) && missing.contains(file.id)
                    ? "\(file.name): the movie is missing."
                    : "\(sheet.name) could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Frames per decode batch of a save: small, so the toast counts frames
    /// as they arrive and Cancel takes effect soon.
    private static let saveDecodeBatch = 4

    private func writeSheet(
        file: MovieFile, sheet: Sheet, settings: FrameSheetCore.Settings, plan: PrintOutput.Plan
    ) async throws -> (url: URL, failures: Int, fromWindow: Int) {
        let backend = try await backend(for: file)
        let individual = settings.includeIndividualThumbs ? sheet.visibleThumbs : []
        let frames = Array(Set(plan.thumbs.map(\.frameNumber))).sorted()

        // 1. Frames, a few at a time, one batch after the other.
        var images: [Int: CGImage] = [:]
        // Requested → decoded frame, where the ±0.5 s retry got another one.
        var decodedFrame: [Int: Int] = [:]
        var done = 0
        progress = SaveProgress(message: "Decoding frame 1 of \(frames.count)…", fraction: 0)
        for start in stride(from: 0, to: frames.count, by: Self.saveDecodeBatch) {
            try Task.checkCancellation()
            let batch = Array(frames[start..<min(start + Self.saveDecodeBatch, frames.count)])
            for await result in backend.frames(batch, maxWidth: plan.decodeWidth) {
                if case .success(let frame) = result.result {
                    images[result.frameNumber] = frame.image
                    if frame.actualFrame != frame.requestedFrame {
                        decodedFrame[frame.requestedFrame] = frame.actualFrame
                    }
                }
                done += 1
                progress = SaveProgress(
                    message: "Decoding frame \(min(done + 1, frames.count)) of \(frames.count)…",
                    fraction: Double(done) / Double(frames.count))
            }
        }
        try Task.checkCancellation()
        // A frame that failed keeps the window's thumb, if there is one.
        var failures = 0
        var fromWindow = 0
        for frame in frames where images[frame] == nil {
            if let cached = cachedImage(file: file.id, frame: frame, width: Self.thumbWidth) {
                images[frame] = cached
                fromWindow += 1
            } else {
                failures += 1
            }
        }
        guard failures < frames.count else { throw SaveError("No frame could be decoded.") }
        // A retried thumb is labeled and placed on the timeline by the frame
        // it shows, as the window retargets it (decision 11).
        var thumbs = plan.thumbs
        for i in thumbs.indices {
            if let actual = decodedFrame[thumbs[i].frameNumber] {
                images[actual] = images[thumbs[i].frameNumber]
                thumbs[i].frameNumber = actual
            }
        }

        // 2. The print, by the view the window shows. ImageRenderer works on
        // the main actor, so the window waits for this stage.
        progress = SaveProgress(message: "Rendering \(plan.width) × \(plan.height) px…", fraction: nil)
        // Lets the toast show before the render blocks the main actor.
        try await Task.sleep(for: .milliseconds(50))
        let decoded = images
        images.removeAll()
        let content = PrintView(file: file, thumbs: thumbs, geometry: plan.geometry, settings: settings) {
            decoded[$0.frameNumber]
        }
        .frame(width: CGFloat(plan.width), height: CGFloat(plan.height), alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = settings.outputFormat == .jpg
        // Standard range, non-linear: frames with HDR or extended-range
        // content would otherwise let the renderer draw in a 16-bit float
        // buffer. `ImageEncoding` writes 8-bit sRGB in any case.
        renderer.allowedDynamicRange = .standard
        renderer.colorMode = .nonLinear
        guard let image = renderer.cgImage else {
            throw SaveError("The \(plan.width) × \(plan.height) px print could not be rendered.")
        }
        try Task.checkCancellation()

        // 3. The file, encoded and written off the main actor.
        progress = SaveProgress(
            message: "Writing \(settings.outputFormat == .png ? "PNG" : "JPG")…", fraction: nil)
        let exchange: SheetExchange? = settings.outputFormat == .png
            && (settings.embedFrameNumbers || settings.embedFilePath)
            ? SheetExchange(
                file: file, sheet: sheet, includeHidden: settings.showHiddenThumbs,
                embedFilePath: settings.embedFilePath, embedFrameData: settings.embedFrameNumbers,
                appVersion: Self.appVersion)
            : nil
        let folder = outputFolder(for: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = PrintOutput.baseName(
            template: settings.sheetNameTemplate, movieFileName: file.name, sheetName: sheet.name, fps: file.fps)
        let url = FileNaming.outputURL(
            folder: folder, baseName: baseName, fileExtension: settings.outputFormat.fileExtension,
            overwrite: settings.overwrite, exists: { FileManager.default.fileExists(atPath: $0.path) })
        try await Self.encodeAndWrite(
            image, format: settings.outputFormat, quality: settings.outputQuality, embedding: exchange, to: url)

        // 4. Individual thumbs at full size, in a folder named after the print.
        if !individual.isEmpty {
            let thumbsFolder = PrintOutput.individualThumbsFolder(printURL: url)
            try FileManager.default.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            for (i, thumb) in individual.enumerated() {
                try Task.checkCancellation()
                progress = SaveProgress(
                    message: "Saving thumb \(i + 1) of \(individual.count)…",
                    fraction: Double(i) / Double(individual.count))
                let frame = try await backend.frame(thumb.frameNumber, maxWidth: max(1, backend.info.width))
                // Named by the frame decoded, like the window's label.
                _ = try await writeThumb(
                    frame.image, frameNumber: frame.actualFrame, template: settings.individualThumbNameTemplate,
                    folder: thumbsFolder, file: file, sheet: sheet, settings: settings)
            }
        }
        return (url, failures, fromWindow)
    }

    /// Encodes an image, embeds the sheet data in a PNG when given, and
    /// writes the file, away from the main actor (a 16384 px PNG takes
    /// seconds and some hundred MB).
    @concurrent
    nonisolated private static func encodeAndWrite(
        _ image: CGImage, format: ImageFormat, quality: Int, embedding exchange: SheetExchange?, to url: URL
    ) async throws {
        var data = try ImageEncoding.data(image, format: format, quality: quality)
        if let exchange { data = try exchange.embedded(in: data) }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    /// Save thumb in the hover overlay: the frame at the movie's own size,
    /// named by the single-thumb template, in the output folder. It decodes
    /// through the movie's backend, as the window does, so with the exact-
    /// frame fallback on the saved frame is the window's.
    func saveThumb(_ thumbId: UUID) {
        guard let file = currentFile, let sheet = currentSheet,
              let thumb = sheet.thumbs.first(where: { $0.id == thumbId })
        else { return }
        let settings = library.settings
        Task {
            do {
                let backend = try await backend(for: file)
                let frame = try await backend.frame(thumb.frameNumber, maxWidth: max(1, backend.info.width))
                let folder = outputFolder(for: file)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = try await writeThumb(
                    frame.image, frameNumber: frame.actualFrame, template: settings.singleThumbNameTemplate,
                    folder: folder, file: file, sheet: sheet, settings: settings)
                showNotice("Saved \(url.lastPathComponent)")
                if settings.openFinderAfterSaving { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                toast = !checkMovieFile(file.id) && missing.contains(file.id)
                    ? "\(file.name): the movie is missing."
                    : "Frame \(thumb.frameNumber) could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Writes one thumb in the thumb format and quality; " edit N" unless
    /// overwriting.
    private func writeThumb(
        _ image: CGImage, frameNumber: Int, template: String, folder: URL, file: MovieFile, sheet: Sheet,
        settings: FrameSheetCore.Settings
    ) async throws -> URL {
        let baseName = PrintOutput.baseName(
            template: template, movieFileName: file.name, sheetName: sheet.name, frameNumber: frameNumber,
            fps: file.fps)
        let url = FileNaming.outputURL(
            folder: folder, baseName: baseName, fileExtension: settings.thumbFormat.fileExtension,
            overwrite: settings.overwrite, exists: { FileManager.default.fileExists(atPath: $0.path) })
        try await Self.encodeAndWrite(
            image, format: settings.thumbFormat, quality: settings.thumbQuality, embedding: nil, to: url)
        return url
    }

    /// Export JSON in the sheet menu: `<file>-<sheet>.json` in the output
    /// folder, " edit N" unless overwriting.
    func exportJSON(_ ref: SheetRef) {
        guard let file = library.file(ref.fileId), let sheet = library.sheet(ref.sheetId, of: ref.fileId) else {
            return
        }
        let settings = library.settings
        let name = SheetExchange.jsonFileName(movieFileName: file.name, sheetName: sheet.name)
        do {
            let folder = outputFolder(for: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = FileNaming.outputURL(
                folder: folder, baseName: String(name.dropLast(".json".count)), fileExtension: "json",
                overwrite: settings.overwrite, exists: { FileManager.default.fileExists(atPath: $0.path) })
            let data = SheetExchange(file: file, sheet: sheet, includeHidden: settings.showHiddenThumbs).jsonData()
            try data.write(to: url, options: .atomic)
            showNotice("Exported \(url.lastPathComponent)")
        } catch {
            toast = "\(name) could not be written: \(error.localizedDescription)"
        }
    }

    /// The app version for the PNG's `version` chunk.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
