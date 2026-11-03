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

/// Save MoviePrint, Save thumb, individual thumbs and Export JSON (§12).
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
        panel.message = "Choose the folder for saved MoviePrints"
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

    /// Save MoviePrint (key M): decodes the print's frames fresh at about
    /// twice their size in the print, one gated batch through the movie's
    /// backend; renders `PrintView` offscreen at the output width; writes
    /// PNG (with the embedded sheet data) or JPG; then the individual thumbs
    /// when asked.
    func saveMoviePrint() {
        guard !isSaving, let file = currentFile, let sheet = currentSheet else { return }
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
                let (url, failures) = try await writeMoviePrint(
                    file: file, sheet: sheet, settings: settings, plan: plan)
                showNotice("Saved \(url.lastPathComponent)")
                if failures > 0 {
                    toast = "\(file.name): \(failures) frame(s) could not be decoded for the print."
                }
                if settings.openFinderAfterSaving { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch is CancellationError {
                showNotice("Saving cancelled.")
            } catch {
                toast = "\(sheet.name) could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func writeMoviePrint(
        file: MovieFile, sheet: Sheet, settings: FrameSheetCore.Settings, plan: PrintOutput.Plan
    ) async throws -> (url: URL, failures: Int) {
        let backend = try await backend(for: file)
        let individual = settings.includeIndividualThumbs ? sheet.visibleThumbs : []
        let frames = Array(Set(plan.thumbs.map(\.frameNumber))).sorted()
        // Decoding the print, rendering it, then each individual thumb.
        let steps = Double(frames.count + 1 + individual.count)
        var done = 0.0

        // 1. Frames, as one batch: the AVFoundation backend holds the
        // DecodeGate for it, so a large save is one decoder session.
        var images: [Int: CGImage] = [:]
        progress = SaveProgress(message: "Decoding frames…", fraction: 0)
        for await result in backend.frames(frames, maxWidth: plan.decodeWidth) {
            if case .success(let frame) = result.result { images[result.frameNumber] = frame.image }
            done += 1
            progress = SaveProgress(
                message: "Decoding frame \(Int(done)) of \(frames.count)…", fraction: done / steps)
        }
        try Task.checkCancellation()
        // A frame that failed keeps the window's thumb, if there is one.
        var failures = 0
        for frame in frames where images[frame] == nil {
            if let cached = cachedImage(file: file.id, frame: frame, width: Self.thumbWidth) {
                images[frame] = cached
            } else {
                failures += 1
            }
        }
        guard failures < frames.count else { throw SaveError("No frame could be decoded.") }

        // 2. The print, by the view the window shows.
        progress = SaveProgress(message: "Rendering \(plan.width) × \(plan.height) px…", fraction: done / steps)
        // Lets the toast show before the render blocks the main actor.
        try await Task.sleep(for: .milliseconds(50))
        let decoded = images
        images.removeAll()
        let content = PrintView(file: file, thumbs: plan.thumbs, geometry: plan.geometry, settings: settings) {
            decoded[$0.frameNumber]
        }
        .frame(width: CGFloat(plan.width), height: CGFloat(plan.height), alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = settings.outputFormat == .jpg
        guard let image = renderer.cgImage else {
            throw SaveError("The \(plan.width) × \(plan.height) px print could not be rendered.")
        }
        var data = try ImageEncoding.data(image, format: settings.outputFormat, quality: settings.outputQuality)
        if settings.outputFormat == .png, settings.embedFrameNumbers || settings.embedFilePath {
            let exchange = SheetExchange(
                file: file, sheet: sheet, includeHidden: settings.showHiddenThumbs,
                embedFilePath: settings.embedFilePath, embedFrameData: settings.embedFrameNumbers,
                appVersion: Self.appVersion)
            data = try exchange.embedded(in: data)
        }
        done += 1

        // 3. The file.
        try Task.checkCancellation()
        let folder = outputFolder(for: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = PrintOutput.baseName(
            template: settings.sheetNameTemplate, movieFileName: file.name, sheetName: sheet.name, fps: file.fps)
        let url = FileNaming.outputURL(
            folder: folder, baseName: baseName, fileExtension: settings.outputFormat.fileExtension,
            overwrite: settings.overwrite, exists: { FileManager.default.fileExists(atPath: $0.path) })
        try data.write(to: url, options: .atomic)

        // 4. Individual thumbs at full size, in a folder named after the print.
        if !individual.isEmpty {
            let thumbsFolder = PrintOutput.individualThumbsFolder(printURL: url)
            try FileManager.default.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            for (i, thumb) in individual.enumerated() {
                try Task.checkCancellation()
                progress = SaveProgress(
                    message: "Saving thumb \(i + 1) of \(individual.count)…", fraction: done / steps)
                let frame = try await backend.frame(thumb.frameNumber, maxWidth: max(1, backend.info.width))
                _ = try writeThumb(
                    frame.image, frameNumber: thumb.frameNumber, template: settings.individualThumbNameTemplate,
                    folder: thumbsFolder, file: file, sheet: sheet, settings: settings)
                done += 1
            }
        }
        return (url, failures)
    }

    /// Save thumb in the hover overlay: the frame at the movie's own size,
    /// named by the single-thumb template, in the output folder.
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
                let url = try writeThumb(
                    frame.image, frameNumber: thumb.frameNumber, template: settings.singleThumbNameTemplate,
                    folder: folder, file: file, sheet: sheet, settings: settings)
                showNotice("Saved \(url.lastPathComponent)")
                if settings.openFinderAfterSaving { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                toast = "Frame \(thumb.frameNumber) could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Writes one thumb in the thumb format and quality; " edit N" unless
    /// overwriting.
    private func writeThumb(
        _ image: CGImage, frameNumber: Int, template: String, folder: URL, file: MovieFile, sheet: Sheet,
        settings: FrameSheetCore.Settings
    ) throws -> URL {
        let data = try ImageEncoding.data(image, format: settings.thumbFormat, quality: settings.thumbQuality)
        let baseName = PrintOutput.baseName(
            template: template, movieFileName: file.name, sheetName: sheet.name, frameNumber: frameNumber,
            fps: file.fps)
        let url = FileNaming.outputURL(
            folder: folder, baseName: baseName, fileExtension: settings.thumbFormat.fileExtension,
            overwrite: settings.overwrite, exists: { FileManager.default.fileExists(atPath: $0.path) })
        try data.write(to: url, options: .atomic)
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
