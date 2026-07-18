import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {
    // Load video metadata through the active decode backend.
    // Single entry point for every open path (menu, drag & drop, Finder/Dock,
    // Open Recent): replaces the current video, resets preview state, keeps
    // grid/style settings, and regenerates the contact sheet.
    func loadVideo(url: URL) {
        self.errorMessage = nil
        self.previewImage = nil
        self.previewImagePath = nil
        self.thumbnails = []
        self.cellImages = [:]
        self.headerImage = nil
        self.displayParams = nil

        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.errorMessage = "File does not exist: \(url.path)"
            return
        }

        self.consoleOutput += "\n>>> Loading video metadata: \(url.lastPathComponent)\n"

        guard let backend = selectBackend(for: url) else {
            // selectBackend already surfaced the user-facing error
            return
        }

        switch backend.open(url: url) {
        case .failure(let error):
            self.errorMessage = error.message
            self.consoleOutput += "Error output:\n\(error.message)\n"
            self.activeBackend?.close()
            self.activeBackend = nil
            return

        case .success(let videoInfo):
            self.activeBackend?.close()
            self.activeBackend = backend
            backend.logSink = { [weak self] message in
                self?.consoleOutput += message
            }
            self.consoleOutput += ">>> Decode backend: \(backend.name)\n"

            self.selectedVideo = videoInfo
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.consoleOutput += "Successfully loaded video:\n - Codec: \(videoInfo.codec)\n - Resolution: \(videoInfo.width)x\(videoInfo.height)\n - Duration: \(videoInfo.formattedDuration)\n - Size: \(videoInfo.formattedSize)\n"

            guard videoInfo.duration > 0 else {
                // Metadata lacks a duration (missing, N/A, or 0 — e.g. a WebM
                // written to a non-seekable output). Estimate it before
                // generating, otherwise the whole sheet would sample the
                // first fraction of a second.
                isEstimatingDuration = true
                backend.estimateDuration(url: url) { [weak self] estimated, cancelled in
                    guard let self = self else { return }
                    self.isEstimatingDuration = false
                    guard self.selectedVideo?.url == url else { return }
                    if cancelled {
                        self.consoleOutput += ">>> Duration estimation cancelled.\n"
                        return
                    }
                    guard let dur = estimated, dur > 0 else {
                        self.errorMessage = "Could not determine the video's duration (no metadata, and the packet scan failed). The file may be corrupted or unsupported."
                        self.consoleOutput += ">>> Duration estimation failed; not generating.\n"
                        return
                    }
                    self.selectedVideo?.duration = dur
                    self.consoleOutput += ">>> Estimated duration from packet scan: \(String(format: "%.3f", dur))s\n"
                    self.generateContactSheet()
                }
                return
            }

            // Auto generate initial contact sheet
            generateContactSheet()
        }
    }

    // Backend routing (Stage A: ffmpeg only; Stage B adds AVFoundation-first).
    // Returns nil after surfacing a user-facing error.
    func selectBackend(for url: URL) -> DecodeBackend? {
        guard isFFmpegInstalled else {
            self.errorMessage = "FFmpeg not found. Install via Homebrew: 'brew install ffmpeg'."
            return nil
        }
        return FFmpegBackend(ffmpegPath: ffmpegPath, ffprobePath: ffprobePath)
    }

    // Present the system open panel and load the chosen video.
    // Shared by File > Open (⌘O) and the canvas "Choose Video File" button.
    // Loading replaces the current video; grid/style settings persist.
    func openVideoPanel() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.movie]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        openPanel.begin { response in
            if response == .OK, let fileURL = openPanel.url {
                DispatchQueue.main.async {
                    self.loadVideo(url: fileURL)
                }
            }
        }
    }
}
