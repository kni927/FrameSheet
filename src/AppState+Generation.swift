import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {
    // Generate contact sheet — v2 ffmpeg single-pass engine
    func generateContactSheet() {
        guard let video = selectedVideo else {
            self.errorMessage = "Please select a video file first."
            return
        }
        guard let backend = activeBackend else {
            self.errorMessage = "No decode backend available for this video. Reload the file."
            return
        }

        isGenerating = true
        errorMessage = nil
        previewImage = nil
        cellImages = [:]
        headerImage = nil
        displayParams = nil
        selectedThumbnailID = nil
        generationID += 1
        let runID = generationID

        // ---- Sampling math ----
        let cols       = self.columns
        let rowsCount  = self.rows
        let thumbCount = cols * rowsCount
        let totalDuration = max(0.1, video.duration)
        let startSec   = totalDuration * startDelayPercent / 100.0
        let endSec     = totalDuration * (1.0 - endDelayPercent / 100.0)
        let effectiveDur = max(0.5, endSec - startSec)
        let interval   = effectiveDur / Double(thumbCount)

        // Thumbnail pixel width (even number required by some codecs)
        let spacing    = self.gridSpacing
        let totalW     = self.imageWidth
        let thumbW     = max(10, (totalW - (cols - 1) * spacing) / cols)
        let thumbWEven = thumbW % 2 == 0 ? thumbW : thumbW - 1

        // Create temp directory
        let tempBase   = NSTemporaryDirectory()
        let tempDirName = "framesheet_\(Int(Date().timeIntervalSince1970))"
        let tempDir    = (tempBase as NSString).appendingPathComponent(tempDirName)
        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            isGenerating = false
            errorMessage = "Failed to create temp dir: \(error.localizedDescription)"
            return
        }

        // Custom timestamps
        var customTS: [Double]? = nil
        if useCustomTimestamps && !customTimestampsText.isEmpty {
            let parsed = ContactSheetRenderer.parseTimestamps(customTimestampsText)
            if !parsed.isEmpty { customTS = parsed }
        }

        // Capture settings for background thread
        let cap = GenerationParams(
            cols: cols, rows: rowsCount,
            imageWidth: totalW, spacing: spacing,
            video: video,
            showHeader: showHeader, showTimestamps: showTimestamps,
            useCustomHeader: useCustomHeaderTemplate,
            customHeaderTemplate: customHeaderTemplate,
            bgColor: backgroundColor, textColor: textColor,
            fontName: selectedFont, customFontPath: customFontPath,
            tsPosition: timestampPosition,
            cornerRadius: cornerRadius
        )

        let timestamps = customTS ?? (0..<thumbCount).map { startSec + Double($0) * interval }
        consoleOutput += "\n>>> [v2] Extracting \(timestamps.count) thumbnails via \(backend.name)...\n"

        // Per-cell timestamps for the grid — mirrors the extraction/render
        // tolerance that existed when this lookup lived inside the renderer:
        // custom timestamps short of `thumbCount` fall back to the regular
        // interval formula for the remaining cells.
        let cellTimestamps: [Double] = (0..<thumbCount).map { i in
            if let cTS = customTS, i < cTS.count { return cTS[i] }
            return startSec + Double(i) * interval
        }
        let newThumbnails: [Thumbnail] = cellTimestamps.enumerated().map { i, ts in
            Thumbnail(timestamp: ts, imagePath: String(format: "\(tempDir)/thumb_%04d.jpg", i + 1))
        }

        backend.extractFrames(
            url: video.url,
            timestamps: timestamps,
            scaleWidth: thumbWEven,
            tempDir: tempDir
        ) { [weak self] extracted, cancelled in
            guard let self = self else { return }
            guard runID == self.generationID, !cancelled else {
                if cancelled && runID == self.generationID {
                    self.isGenerating = false
                }
                try? FileManager.default.removeItem(atPath: tempDir)
                return
            }
            guard extracted > 0 else {
                self.consoleOutput += "\n>>> \(backend.name) extracted no frames.\n"
                self.errorMessage = "Frame extraction failed (\(backend.name)). See console log."
                self.isGenerating = false
                try? FileManager.default.removeItem(atPath: tempDir)
                return
            }
            self.consoleOutput += ">>> Extracted \(extracted)/\(timestamps.count) frames. Composing contact sheet in Swift...\n"
            self.thumbnails = newThumbnails
            self.renderAndPresent(tempDir: tempDir, thumbnails: newThumbnails, params: cap, runID: runID)
        }
    }

    // Composite the extracted thumbnails on a background queue and publish
    // the resulting image. The frame temp dir is retained (not deleted) so
    // individual-frame export can read from the `thumbnails` array's paths;
    // it is replaced on the next generation.
    func renderAndPresent(tempDir: String, thumbnails: [Thumbnail], params cap: GenerationParams, runID: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = ContactSheetRenderer.render(thumbnails: thumbnails, params: cap)

            // Per-cell display images + header strip for the addressable
            // grid, rendered from the same drawCell path as the sheet.
            var newCellImages: [UUID: NSImage] = [:]
            for thumb in thumbnails {
                if let cell = ContactSheetRenderer.renderCellImage(thumb, params: cap) {
                    newCellImages[thumb.id] = cell
                }
            }
            let newHeader = ContactSheetRenderer.renderHeaderImage(params: cap)

            DispatchQueue.main.async {
                guard runID == self.generationID else {
                    try? FileManager.default.removeItem(atPath: tempDir)
                    return
                }
                if let old = self.currentFramesDir, old != tempDir {
                    try? FileManager.default.removeItem(atPath: old)
                }
                self.currentFramesDir = tempDir
                self.isGenerating = false
                if let img = image {
                    let outPath = (NSTemporaryDirectory() as NSString)
                        .appendingPathComponent("framesheet_\(Int(Date().timeIntervalSince1970)).png")
                    if let tiff = img.tiffRepresentation,
                       let rep  = NSBitmapImageRep(data: tiff),
                       let png  = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: outPath))
                        self.previewImagePath = outPath
                    }
                    self.previewImage = img
                    self.cellImages = newCellImages
                    self.headerImage = newHeader
                    self.displayParams = cap
                    self.fitToScreen()
                    self.consoleOutput += ">>> Contact sheet generated successfully!\n"
                } else {
                    self.errorMessage = "Failed to compose contact sheet."
                    self.consoleOutput += ">>> Composition failed.\n"
                }
            }
        }
    }

    // Auto generate contact sheet on UI updates if already loaded.
    // Debounced so rapid stepper clicks coalesce into a single generation request
    // instead of repeatedly terminating and restarting the vcsi process.
    func autoGenerateIfNeeded() {
        guard selectedVideo != nil && previewImagePath != nil else { return }

        generateDebounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.selectedVideo != nil, self.previewImagePath != nil else { return }
            if self.isGenerating {
                // A previous request is still running (e.g. it started before this
                // batch of changes settled). Re-arm the debounce so the latest
                // values get rendered once that request completes, instead of
                // leaving the preview stuck on stale settings.
                self.autoGenerateIfNeeded()
            } else {
                self.generateContactSheet()
            }
        }
        generateDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func cancelGeneration() {
        // Stop the batch extraction and/or the duration estimation if
        // running — the active backend owns the in-flight work.
        let didCancel = activeBackend?.cancelAll() ?? false
        if didCancel {
            self.consoleOutput += "\n>>> Command execution cancelled by user.\n"
            self.isGenerating = false
        }
    }

    // Copy image from temp path to clipboard
    func copyToClipboard() {
        guard let image = previewImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        self.consoleOutput += "Copied preview image to clipboard.\n"
    }

}
