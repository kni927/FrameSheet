import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {
    // Load Video details via ffprobe.
    // Single entry point for every open path (menu, drag & drop, Finder/Dock,
    // Open Recent): replaces the current video, resets preview state, keeps
    // grid/style settings, and regenerates the contact sheet.
    func loadVideo(url: URL) {
        self.errorMessage = nil
        self.previewImage = nil
        self.previewImagePath = nil

        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.errorMessage = "File does not exist: \(url.path)"
            return
        }

        let probeCmd = "\"\(ffprobePath.isEmpty ? "ffprobe" : ffprobePath)\" -v error -show_format -show_streams -print_format json \"\(url.path)\""

        self.consoleOutput += "\n>>> Loading video metadata: \(url.lastPathComponent)\n"

        let result = executeShellSync(probeCmd)
        if result.status != 0 {
            self.errorMessage = "Failed to analyze video: \(result.stderr)"
            self.consoleOutput += "Error output:\n\(result.stderr)\n"
            return
        }

        guard let data = result.stdout.data(using: .utf8) else {
            self.errorMessage = "Failed to decode ffprobe output."
            return
        }

        do {
            let decoded = try JSONDecoder().decode(FFProbeResult.self, from: data)

            var videoInfo = VideoFileInfo(url: url)

            // Format details
            if let durationStr = decoded.format?.duration, let dur = Double(durationStr) {
                videoInfo.duration = dur
            }
            if let sizeStr = decoded.format?.size, let sz = Int64(sizeStr) {
                videoInfo.size = sz
            }

            // Video stream details
            if let streams = decoded.streams {
                if let videoStream = streams.first(where: { $0.codec_type == "video" }) {
                    videoInfo.width = videoStream.width ?? 0
                    videoInfo.height = videoStream.height ?? 0
                    videoInfo.codec = videoStream.codec_name ?? "Unknown"
                    videoInfo.frameRate = videoStream.r_frame_rate ?? ""

                    // Fallback duration if format lacked it
                    if videoInfo.duration == 0, let streamDurStr = videoStream.duration, let dur = Double(streamDurStr) {
                        videoInfo.duration = dur
                    }
                }
            }

            videoInfo.isLoaded = true
            self.selectedVideo = videoInfo
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.consoleOutput += "Successfully loaded video:\n - Codec: \(videoInfo.codec)\n - Resolution: \(videoInfo.width)x\(videoInfo.height)\n - Duration: \(videoInfo.formattedDuration)\n - Size: \(videoInfo.formattedSize)\n"

            guard videoInfo.duration > 0 else {
                // Metadata lacks a duration (missing, N/A, or 0 — e.g. a WebM
                // written to a non-seekable output). Estimate it from packet
                // timestamps before generating, otherwise the whole sheet
                // would sample the first fraction of a second.
                estimateDuration(for: url) { [weak self] estimated, cancelled in
                    guard let self = self, self.selectedVideo?.url == url else { return }
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

        } catch {
            self.errorMessage = "Failed to parse metadata JSON: \(error.localizedDescription)"
            self.consoleOutput += "JSON parsing error: \(error)\n"
        }
    }

    // Estimate the duration of a file whose metadata lacks it, using
    // demux-only packet scans (no decoding). Attempt 1 seeks to an
    // unreachably late timestamp and reads the trailing packets — instant
    // for indexed containers; for a cues-less WebM the demuxer falls back
    // to a linear scan, which is still IO-bound only. Attempt 2 is an
    // explicit full scan taking the max pts_time. Cancellable via
    // cancelGeneration(). completion(duration, wasCancelled) runs on main.
    func estimateDuration(for url: URL, completion: @escaping (Double?, Bool) -> Void) {
        isEstimatingDuration = true
        consoleOutput += ">>> Duration missing from metadata; estimating via packet scan...\n"
        processLock.lock()
        estimationCancelled = false
        processLock.unlock()

        let probe = ffprobePath.isEmpty ? "ffprobe" : ffprobePath
        let nfcPath = url.path.precomposedStringWithCanonicalMapping
        let baseArgs = ["-v", "error", "-select_streams", "v:0",
                        "-show_entries", "packet=pts_time", "-of", "csv=p=0"]

        DispatchQueue.global(qos: .userInitiated).async {
            // Attempt 1: seek to the end and read the last packets.
            var result = self.maxPTS(fromProbe: probe, args: baseArgs + ["-read_intervals", "9999999", nfcPath])

            // Attempt 2: full demux scan of every packet's pts_time.
            if result == nil && !self.isEstimationCancelled() {
                result = self.maxPTS(fromProbe: probe, args: baseArgs + [nfcPath])
            }

            let wasCancelled = self.isEstimationCancelled()
            DispatchQueue.main.async {
                self.isEstimatingDuration = false
                completion(result, wasCancelled)
            }
        }
    }

    func isEstimationCancelled() -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return estimationCancelled
    }

    // Run one ffprobe packet listing and return the maximum pts_time,
    // or nil on failure/cancellation/empty output. Blocking; call off-main.
    func maxPTS(fromProbe probe: String, args: [String]) -> Double? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: probe)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice

        processLock.lock()
        if estimationCancelled {
            processLock.unlock()
            return nil
        }
        estimationProcess = task
        processLock.unlock()

        defer {
            processLock.lock()
            if estimationProcess === task { estimationProcess = nil }
            processLock.unlock()
        }

        do {
            try task.run()
        } catch {
            return nil
        }
        // Read before waiting so a large packet list can't fill the pipe
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        let maxSeen = text.split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .max()
        guard let m = maxSeen, m > 0, m.isFinite else { return nil }
        return m
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
