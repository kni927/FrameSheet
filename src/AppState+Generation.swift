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
        guard isFFmpegInstalled else {
            self.errorMessage = "FFmpeg not found. Install via Homebrew: 'brew install ffmpeg'."
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

        let nfcVideo = video.path.precomposedStringWithCanonicalMapping

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

        // One input-seeking ffmpeg invocation per frame (-ss before -i only
        // decodes from the nearest keyframe, frame-accurate in modern
        // ffmpeg), run in parallel. Software decode: a single GOP per
        // invocation is cheap, and videotoolbox init overhead would
        // dominate here.
        let timestamps = customTS ?? (0..<thumbCount).map { startSec + Double($0) * interval }
        consoleOutput += "\n>>> [v2] Extracting \(timestamps.count) thumbnails (parallel per-frame input seek)...\n"

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

        runParallelFrameExtraction(
            timestamps: timestamps,
            videoPath: nfcVideo,
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
                self.consoleOutput += "\n>>> ffmpeg extracted no frames.\n"
                self.errorMessage = "ffmpeg failed. See console log."
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

    // Extract one frame per timestamp with parallel ffmpeg input seeks
    // (5 concurrent). completion(extractedCount, wasCancelled) is called on
    // the main queue after all invocations finish.
    func runParallelFrameExtraction(
        timestamps: [Double],
        videoPath: String,
        scaleWidth: Int,
        tempDir: String,
        completion: @escaping (Int, Bool) -> Void
    ) {
        let ff = ffmpegPath
        processLock.lock()
        parallelCancelled = false
        parallelProcesses.removeAll()
        processLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let semaphore = DispatchSemaphore(value: 5)
            let group = DispatchGroup()
            let countLock = NSLock()
            var extracted = 0

            for (i, t) in timestamps.enumerated() {
                semaphore.wait()
                self.processLock.lock()
                let cancelled = self.parallelCancelled
                self.processLock.unlock()
                if cancelled {
                    semaphore.signal()
                    break
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    let outPath = String(format: "%@/thumb_%04d.jpg", tempDir, i + 1)
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: ff)
                    task.arguments = [
                        "-hide_banner", "-loglevel", "error",
                        "-ss", String(format: "%.3f", t),
                        "-i", videoPath,
                        "-frames:v", "1",
                        "-vf", "scale=\(scaleWidth):-2",
                        "-q:v", "3",
                        "-y", outPath
                    ]
                    task.standardOutput = FileHandle.nullDevice
                    let errPipe = Pipe()
                    task.standardError = errPipe

                    self.processLock.lock()
                    if self.parallelCancelled {
                        self.processLock.unlock()
                        return
                    }
                    self.parallelProcesses.append(task)
                    self.processLock.unlock()

                    var launched = false
                    do {
                        try task.run()
                        launched = true
                        task.waitUntilExit()
                    } catch {
                        DispatchQueue.main.async {
                            self.consoleOutput += "Frame \(i + 1): failed to launch ffmpeg: \(error.localizedDescription)\n"
                        }
                    }

                    self.processLock.lock()
                    if let idx = self.parallelProcesses.firstIndex(where: { $0 === task }) {
                        self.parallelProcesses.remove(at: idx)
                    }
                    self.processLock.unlock()

                    // Drain stderr even on success so the pipe can't fill up
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if launched && task.terminationStatus == 0
                        && FileManager.default.fileExists(atPath: outPath) {
                        countLock.lock()
                        extracted += 1
                        countLock.unlock()
                    } else if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
                        DispatchQueue.main.async {
                            self.consoleOutput += "Frame \(i + 1) (t=\(String(format: "%.1f", t))s): \(err)"
                        }
                    }
                }
            }

            group.wait()
            self.processLock.lock()
            let wasCancelled = self.parallelCancelled
            self.processLock.unlock()
            countLock.lock()
            let total = extracted
            countLock.unlock()
            DispatchQueue.main.async {
                completion(total, wasCancelled)
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
        // Stop the parallel per-frame extraction and/or the duration
        // estimation scan if running
        processLock.lock()
        parallelCancelled = true
        estimationCancelled = true
        let procs = parallelProcesses
        let estimation = estimationProcess
        processLock.unlock()

        var didCancel = false
        for p in procs where p.isRunning {
            p.terminate()
            didCancel = true
        }
        if let est = estimation, est.isRunning {
            est.terminate()
            didCancel = true
        }
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
