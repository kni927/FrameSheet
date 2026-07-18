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

        guard let (backend, videoInfo) = routeAndOpen(url: url) else {
            // routeAndOpen already surfaced the user-facing error
            return
        }

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

    // Backend routing (Stage B): probe with AVFoundation first; fall back
    // to ffmpeg only when the asset has no decodable video track. When the
    // fallback is needed but ffmpeg is not installed, fail with a clear
    // user-facing message naming the format — not a crash, not a hang.
    // Returns nil after surfacing that error.
    private func routeAndOpen(url: URL) -> (DecodeBackend, VideoFileInfo)? {
        let avf = AVFoundationBackend()
        switch avf.open(url: url) {
        case .success(let info):
            return (avf, info)
        case .failure(let avfError):
            self.consoleOutput += ">>> AVFoundation cannot open this file (\(avfError.message)) — falling back to ffmpeg.\n"
        }

        let ext = url.pathExtension.isEmpty ? "unknown format" : ".\(url.pathExtension.lowercased())"
        guard isFFmpegInstalled else {
            self.errorMessage = "\(url.lastPathComponent) (\(ext)) is not supported by macOS's native decoder, and ffmpeg was not found. Install it via Homebrew: 'brew install ffmpeg'."
            return nil
        }

        let ff = FFmpegBackend(ffmpegPath: ffmpegPath, ffprobePath: ffprobePath)
        switch ff.open(url: url) {
        case .success(let info):
            return (ff, info)
        case .failure(let error):
            self.errorMessage = error.message
            self.consoleOutput += "Error output:\n\(error.message)\n"
            return nil
        }
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
