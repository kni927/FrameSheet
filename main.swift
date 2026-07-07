import SwiftUI
import Foundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Models

struct VideoFileInfo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var duration: Double = 0
    var size: Int64 = 0
    var width: Int = 0
    var height: Int = 0
    var codec: String = ""
    var frameRate: String = ""
    var isLoaded: Bool = false
    
    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

struct FFProbeResult: Codable {
    struct Format: Codable {
        let duration: String?
        let size: String?
        let format_name: String?
        let format_long_name: String?
    }
    
    struct Stream: Codable {
        let codec_type: String
        let codec_name: String?
        let width: Int?
        let height: Int?
        let r_frame_rate: String?
        let duration: String?
    }
    
    let format: Format?
    let streams: [Stream]?
}

// MARK: - App State

class AppState: ObservableObject {
    // Media State
    @Published var selectedVideo: VideoFileInfo? = nil
    
    // Layout Options
    @Published var columns: Int = 4
    @Published var rows: Int = 4
    @Published var imageWidth: Int = 1200
    @Published var gridSpacing: Int = 10
    
    // Style Options
    @Published var showTimestamps: Bool = true
    @Published var showHeader: Bool = true
    @Published var useCustomHeaderTemplate: Bool = false
    @Published var customHeaderTemplate: String = """
{{filename}}
File size: {{size}}
Duration: {{duration}}
Dimensions: {{sample_width}}x{{sample_height}}
"""
    @Published var backgroundColor: Color = .black
    @Published var textColor: Color = .white
    
    // Font & Position Options
    @Published var selectedFont: String = "Hiragino Sans" // Hiragino Sans, Helvetica, Times, Custom
    @Published var customFontPath: String = ""
    @Published var timestampPosition: String = "bottom-right" // top-left, top-right, bottom-left, bottom-right
    
    // Range & Custom Frames
    @Published var startDelayPercent: Double = 5
    @Published var endDelayPercent: Double = 5
    @Published var useCustomTimestamps: Bool = false
    @Published var customTimestampsText: String = ""
    
    // Dependencies Status
    @Published var ffmpegPath: String = ""
    @Published var ffprobePath: String = ""
    @Published var isFFmpegInstalled: Bool = false
    @Published var dependencyCheckMessage: String = "Initializing..."
    @Published var isCheckingDependencies: Bool = false
    
    // Application Running States
    @Published var isGenerating: Bool = false
    @Published var isEstimatingDuration: Bool = false
    @Published var previewImage: NSImage? = nil
    @Published var previewImagePath: String? = nil
    @Published var consoleOutput: String = ""
    @Published var errorMessage: String? = nil
    
    // UI Helpers
    @Published var activeTab: String = "layout" // layout, style, frames
    @Published var showConsole: Bool = false // Default OFF
    @Published var zoomScale: CGFloat = 1.0
    @Published var containerWidth: CGFloat = 800.0
    @Published var containerHeight: CGFloat = 600.0
    
    private var generateDebounceWorkItem: DispatchWorkItem? = nil
    // Incremented per generation; a superseded run (e.g. replaced by a new
    // video load while extraction was in flight) must not touch shared state.
    private var generationID = 0
    // Parallel extraction bookkeeping (guarded by processLock)
    private let processLock = NSLock()
    private var parallelProcesses: [Process] = []
    private var parallelCancelled = false
    // Duration-estimation bookkeeping (guarded by processLock)
    private var estimationProcess: Process? = nil
    private var estimationCancelled = false

    init() {
        checkDependencies()
    }
    
    // Check system commands and Python packages
    func checkDependencies() {
        self.isCheckingDependencies = true
        self.dependencyCheckMessage = "Checking environment..."

        DispatchQueue.global(qos: .userInitiated).async {
            let ff = self.findCommandPath("ffmpeg")
            let probe = self.findCommandPath("ffprobe")
            let ok = !ff.isEmpty && !probe.isEmpty

            DispatchQueue.main.async {
                self.ffmpegPath = ff
                self.ffprobePath = probe
                self.isFFmpegInstalled = ok
                self.isCheckingDependencies = false

                if ff.isEmpty || probe.isEmpty {
                    self.dependencyCheckMessage = "FFmpeg/FFprobe not found. Install via Homebrew: 'brew install ffmpeg'."
                } else {
                    self.dependencyCheckMessage = "FFmpeg \(ff) — Ready!"
                }

                // A Finder/Dock open may have arrived while the check was
                // still running (cold start); process it now that the
                // ffmpeg/ffprobe paths are settled. Flushed even if the
                // check failed so the user still gets a clear error.
                if let url = self.pendingOpenURL {
                    self.pendingOpenURL = nil
                    self.loadVideo(url: url)
                }
            }
        }
    }

    // Entry point for Finder/Dock open events. Defers the load while the
    // async ffmpeg dependency check is still running, so the initial
    // auto-generation doesn't race a not-yet-set ffmpeg path.
    func handleOpenURL(_ url: URL) {
        if isCheckingDependencies {
            pendingOpenURL = url
        } else {
            loadVideo(url: url)
        }
    }
    private var pendingOpenURL: URL? = nil
    
    private func findCommandPath(_ cmd: String) -> String {
        // Search in common PATHs first to override shell environment limits
        let searchPaths = [
            "/Users/kni/miniforge3/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        
        for dir in searchPaths {
            let fullPath = (dir as NSString).appendingPathComponent(cmd)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        
        // Fallback to "which"
        let res = executeShellSync("which \(cmd)")
        if res.status == 0 {
            return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return ""
    }
    
    // Direct synchronous command execution for checkups
    private func executeShellSync(_ command: String) -> (stdout: String, stderr: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        
        // Provide rich PATH variables
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/Users/kni/miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + currentPath
        task.environment = env
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            
            return (outStr, errStr, task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
    
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
    private func estimateDuration(for url: URL, completion: @escaping (Double?, Bool) -> Void) {
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

    private func isEstimationCancelled() -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return estimationCancelled
    }

    // Run one ffprobe packet listing and return the maximum pts_time,
    // or nil on failure/cancellation/empty output. Blocking; call off-main.
    private func maxPTS(fromProbe probe: String, args: [String]) -> Double? {
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
            let parsed = parseTimestamps(customTimestampsText)
            if !parsed.isEmpty { customTS = parsed }
        }

        // Capture settings for background thread
        let cap = GenerationParams(
            cols: cols, rows: rowsCount, thumbCount: thumbCount,
            imageWidth: totalW, spacing: spacing,
            interval: interval, startSec: startSec,
            customTS: customTS,
            video: video,
            showHeader: showHeader, showTimestamps: showTimestamps,
            useCustomHeader: useCustomHeaderTemplate,
            customHeaderTemplate: customHeaderTemplate,
            bgColor: backgroundColor, textColor: textColor,
            fontName: selectedFont, customFontPath: customFontPath,
            tsPosition: timestampPosition
        )

        // One input-seeking ffmpeg invocation per frame (-ss before -i only
        // decodes from the nearest keyframe, frame-accurate in modern
        // ffmpeg), run in parallel. Software decode: a single GOP per
        // invocation is cheap, and videotoolbox init overhead would
        // dominate here.
        let timestamps = customTS ?? (0..<thumbCount).map { startSec + Double($0) * interval }
        consoleOutput += "\n>>> [v2] Extracting \(timestamps.count) thumbnails (parallel per-frame input seek)...\n"

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
            self.renderAndPresent(tempDir: tempDir, params: cap, runID: runID)
        }
    }

    // Composite the extracted thumbnails on a background queue and publish
    // the resulting image.
    private func renderAndPresent(tempDir: String, params cap: GenerationParams, runID: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.renderContactSheet(tempDir: tempDir, params: cap)
            try? FileManager.default.removeItem(atPath: tempDir)

            DispatchQueue.main.async {
                guard runID == self.generationID else { return }
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
    private func runParallelFrameExtraction(
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

    // Parameter bundle for background renderer
    private struct GenerationParams {
        let cols: Int, rows: Int, thumbCount: Int
        let imageWidth: Int, spacing: Int
        let interval: Double, startSec: Double
        let customTS: [Double]?
        let video: VideoFileInfo
        let showHeader: Bool, showTimestamps: Bool
        let useCustomHeader: Bool, customHeaderTemplate: String
        let bgColor: Color, textColor: Color
        let fontName: String, customFontPath: String
        let tsPosition: String
    }

    // CoreGraphics / AppKit composite renderer
    private func renderContactSheet(tempDir: String, params p: GenerationParams) -> NSImage? {
        let cols    = p.cols
        let spacing = p.spacing
        let cellW   = max(10, (p.imageWidth - (cols - 1) * spacing) / cols)
        let ar      = p.video.width > 0 ? Double(p.video.height) / Double(p.video.width) : 9.0 / 16.0
        let cellH   = max(1, Int(Double(cellW) * ar))

        let rows = p.rows
        let thumbCount = p.thumbCount

        // Header lines
        let fontSize: CGFloat   = 14
        let headerMargin: CGFloat = 10
        var headerLines: [String] = []
        if p.showHeader {
            if p.useCustomHeader && !p.customHeaderTemplate.isEmpty {
                var t = p.customHeaderTemplate
                t = t.replacingOccurrences(of: "{{filename}}",     with: p.video.name)
                t = t.replacingOccurrences(of: "{{size}}",         with: p.video.formattedSize)
                t = t.replacingOccurrences(of: "{{duration}}",     with: p.video.formattedDuration)
                t = t.replacingOccurrences(of: "{{sample_width}}", with: "\(p.imageWidth)")
                t = t.replacingOccurrences(of: "{{sample_height}}",with: "\(rows * cellH + max(0, rows - 1) * spacing)")
                t = t.replacingOccurrences(of: "{{video_codec}}",  with: p.video.codec)
                t = t.replacingOccurrences(of: "{{frame_rate}}",   with: p.video.frameRate)
                headerLines = t.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            } else {
                headerLines = [
                    p.video.name,
                    "File size: \(p.video.formattedSize)",
                    "Duration: \(p.video.formattedDuration)",
                    "Dimensions: \(p.video.width)x\(p.video.height)"
                ]
            }
        }
        let lineH: CGFloat = fontSize * 1.45
        let headerH = headerLines.isEmpty ? 0 : Int(2 * headerMargin + CGFloat(headerLines.count) * lineH)

        let totalW = p.imageWidth
        let totalH = headerH + rows * cellH + max(0, rows - 1) * spacing
        guard totalW > 0 && totalH > 0 else { return nil }

        // Create bitmap CGContext
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: totalW, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Wrap in NSGraphicsContext so AppKit drawing works (origin = bottom-left)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // Background fill
        NSColor(p.bgColor).setFill()
        NSRect(x: 0, y: 0, width: totalW, height: totalH).fill()

        // Resolve font
        let psName: String
        switch p.fontName {
        case "Helvetica": psName = "Helvetica"
        case "Times":     psName = "TimesNewRomanPSMT"
        default:          psName = "HiraginoSans-W3"
        }
        let nsFont = NSFont(name: psName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let textNS = NSColor(p.textColor)

        // Draw header
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: nsFont, .foregroundColor: textNS]
        for (i, line) in headerLines.enumerated() {
            let y = CGFloat(totalH) - headerMargin - CGFloat(i + 1) * lineH
            NSAttributedString(string: line, attributes: headerAttrs).draw(at: CGPoint(x: headerMargin, y: y))
        }

        // Timestamp style
        let tsFontSize: CGFloat = max(8, CGFloat(cellW) * 0.065)
        let tsFont = NSFont(name: psName, size: tsFontSize) ?? NSFont.systemFont(ofSize: tsFontSize)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        let tsAttrs: [NSAttributedString.Key: Any] = [.font: tsFont, .foregroundColor: textNS, .shadow: shadow]

        // Draw thumbnails + timestamps
        for i in 0..<min(thumbCount, rows * cols) {
            let col = i % cols
            let row = i / cols
            let x   = col * (cellW + spacing)
            // Y from bottom-left origin: top row is highest Y
            let y   = totalH - headerH - (row + 1) * cellH - row * spacing
            let destRect = NSRect(x: x, y: y, width: cellW, height: cellH)

            let thumbPath = String(format: "\(tempDir)/thumb_%04d.jpg", i + 1)
            if let img = NSImage(contentsOfFile: thumbPath) {
                img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                NSColor(white: 0.12, alpha: 1).setFill()
                destRect.fill()
            }

            if p.showTimestamps {
                let ts: Double = {
                    if let cTS = p.customTS, i < cTS.count { return cTS[i] }
                    return p.startSec + Double(i) * p.interval
                }()
                let attrTS  = NSAttributedString(string: formatTimestamp(ts), attributes: tsAttrs)
                let tsSize  = attrTS.size()
                let pad: CGFloat = 4
                let tsX: CGFloat
                let tsY: CGFloat
                switch p.tsPosition {
                case "top-left":
                    tsX = CGFloat(x) + pad;          tsY = CGFloat(y + cellH) - tsSize.height - pad
                case "top-right":
                    tsX = CGFloat(x + cellW) - tsSize.width - pad; tsY = CGFloat(y + cellH) - tsSize.height - pad
                case "bottom-left":
                    tsX = CGFloat(x) + pad;          tsY = CGFloat(y) + pad
                default: // bottom-right
                    tsX = CGFloat(x + cellW) - tsSize.width - pad; tsY = CGFloat(y) + pad
                }
                attrTS.draw(at: CGPoint(x: tsX, y: tsY))
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: totalW, height: totalH))
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let s   = max(0, seconds)
        let h   = Int(s) / 3600
        let m   = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    private func parseTimestamps(_ text: String) -> [Double] {
        text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
            .compactMap { part -> Double? in
                let s = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { return nil }
                let c = s.components(separatedBy: ":")
                switch c.count {
                case 2:
                    if let min = Double(c[0]), let sec = Double(c[1]) { return min * 60 + sec }
                case 3:
                    if let h = Double(c[0]), let min = Double(c[1]), let sec = Double(c[2]) { return h * 3600 + min * 60 + sec }
                default: break
                }
                return Double(s)
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
    
    // Fit zoom scale to container size (both width and height) to fit screen
    func fitToScreen() {
        guard let img = previewImage else { return }
        
        // Image has padding(20) in CanvasView, which adds 40px to both width and height.
        // Also add a safety margin of 20px to avoid scrollbars triggering due to rounding or minor layouts.
        let containerW = containerWidth - 60
        
        // Calculate vertical offset dynamically depending on visible UI elements
        var offsetH: CGFloat = 30 + 40 + 20 // Base padding + Image padding(40) + Safety margin(20)
        if selectedVideo != nil {
            offsetH += 45 // Video info card height
        }
        if previewImage != nil && !isGenerating {
            offsetH += 45 // Copy/Save action bar height
        }
        
        let containerH = containerHeight - offsetH
        let imgW = CGFloat(imageWidth)
        let imgH = imgW * img.aspectRatio
        
        let scaleW = containerW / imgW
        let scaleH = containerH / imgH
        
        zoomScale = min(1.0, max(0.1, min(scaleW, scaleH)))
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
    
    // Save generated image to custom location
    func saveImageAs() {
        guard let tempPath = previewImagePath, FileManager.default.fileExists(atPath: tempPath) else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg]
        savePanel.canCreateDirectories = true
        
        if let video = selectedVideo {
            let originalName = video.url.deletingPathExtension().lastPathComponent
            savePanel.nameFieldStringValue = "\(originalName)_sheet.png"
        } else {
            savePanel.nameFieldStringValue = "framesheet.png"
        }
        
        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                do {
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: tempPath), to: targetURL)
                    self.consoleOutput += "Saved image to: \(targetURL.path)\n"
                } catch {
                    self.errorMessage = "Failed to save file: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // Calculated height of the generated contact sheet image
    var estimatedHeight: Int {
        guard let video = selectedVideo, video.width > 0, video.height > 0 else { return 0 }
        
        let colCount = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let totalWidth = CGFloat(imageWidth)
        let spacing = CGFloat(gridSpacing)
        
        let desiredFrameWidth = (totalWidth - (colCount - 1) * spacing) / colCount
        let aspectRatio = CGFloat(video.height) / CGFloat(video.width)
        let desiredFrameHeight = desiredFrameWidth * aspectRatio
        
        let gridHeight = rowCount * (desiredFrameHeight + spacing) - spacing
        
        var headerHeight: CGFloat = 0
        if showHeader {
            let lineSpacingCoefficient: CGFloat = 1.2
            let fontSize: CGFloat = 16
            let margin: CGFloat = 10
            let headerLineHeight = CGFloat(Int(fontSize * lineSpacingCoefficient))
            
            var estimatedLines: CGFloat = 4
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let lines = customHeaderTemplate.components(separatedBy: .newlines)
                estimatedLines = CGFloat(max(1, lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
            }
            
            headerHeight = 2 * margin + estimatedLines * headerLineHeight
        }
        
        return Int(gridHeight + headerHeight)
    }
    
    // Min and Max height bounds for the height slider
    var minHeight: Double {
        calculateHeightForWidth(600)
    }
    
    var maxHeight: Double {
        calculateHeightForWidth(3200)
    }
    
    private func calculateHeightForWidth(_ w: Int) -> Double {
        guard let video = selectedVideo, video.width > 0, video.height > 0 else { return 800 }
        
        let colCount = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let totalWidth = CGFloat(w)
        let spacing = CGFloat(gridSpacing)
        
        let desiredFrameWidth = (totalWidth - (colCount - 1) * spacing) / colCount
        let aspectRatio = CGFloat(video.height) / CGFloat(video.width)
        let desiredFrameHeight = desiredFrameWidth * aspectRatio
        
        let gridHeight = rowCount * (desiredFrameHeight + spacing) - spacing
        
        var headerHeight: CGFloat = 0
        if showHeader {
            let lineSpacingCoefficient: CGFloat = 1.2
            let fontSize: CGFloat = 16
            let margin: CGFloat = 10
            let headerLineHeight = CGFloat(Int(fontSize * lineSpacingCoefficient))
            
            var estimatedLines: CGFloat = 4
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let lines = customHeaderTemplate.components(separatedBy: .newlines)
                estimatedLines = CGFloat(max(1, lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
            }
            
            headerHeight = 2 * margin + estimatedLines * headerLineHeight
        }
        
        return Double(gridHeight + headerHeight)
    }
    
    // Reverse calculates and updates imageWidth from a target totalHeight
    func updateWidthFromHeight(_ targetHeight: Int) {
        guard let video = selectedVideo, video.width > 0, video.height > 0 else { return }
        
        let colCount = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let spacing = CGFloat(gridSpacing)
        let aspectRatio = CGFloat(video.height) / CGFloat(video.width)
        
        var headerHeight: CGFloat = 0
        if showHeader {
            let lineSpacingCoefficient: CGFloat = 1.2
            let fontSize: CGFloat = 16
            let margin: CGFloat = 10
            let headerLineHeight = CGFloat(Int(fontSize * lineSpacingCoefficient))
            
            var estimatedLines: CGFloat = 4
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let lines = customHeaderTemplate.components(separatedBy: .newlines)
                estimatedLines = CGFloat(max(1, lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
            }
            
            headerHeight = 2 * margin + estimatedLines * headerLineHeight
        }
        
        let targetGridHeight = CGFloat(targetHeight) - headerHeight
        let h_f = (targetGridHeight + spacing) / rowCount - spacing
        let w_f = h_f / aspectRatio
        let targetWidth = colCount * w_f + (colCount - 1) * spacing
        
        let finalWidth = max(600, min(3200, Int(round(targetWidth))))
        
        if self.imageWidth != finalWidth {
            self.imageWidth = finalWidth
        }
    }
}

// MARK: - Color Conversion Extension

extension Color {
    func toHex() -> String {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else {
            return "000000"
        }
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Views

struct MainView: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            TopBarView()
            
            // Middle Content Split View
            HSplitView {
                // Sidebar controls (Thinned to 180)
                SidebarView()
                    .frame(width: 180)
                    .frame(minWidth: 160, maxWidth: 220)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
                
                // Canvas preview
                CanvasView()
                    .frame(minWidth: 500)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.11))
            }
            
            // Collapsible Console
            if state.showConsole {
                ConsoleView()
                    .frame(height: 180)
                    .transition(.move(edge: .bottom))
            }
        }
        .monoFont() // Set SF Mono globally
        .alert(item: Binding<AlertError?>(
            get: { state.errorMessage.map { AlertError(message: $0) } },
            set: { _ in state.errorMessage = nil }
        )) { err in
            Alert(
                title: Text("Error"),
                message: Text(err.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct AlertError: Identifiable {
    let id = UUID()
    let message: String
}

// MARK: - Subviews

struct TopBarView: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        HStack {
            Image(systemName: "photo.stack")
                .font(.title3)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("FrameSheet")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                if let video = state.selectedVideo {
                    Text(video.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                } else {
                    Text("No video selected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            // Zoom Controls
            if state.previewImage != nil {
                HStack(spacing: 6) {
                    Button(action: { state.zoomScale = max(0.1, state.zoomScale - 0.1) }) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Text("\(Int(state.zoomScale * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 42)
                        .multilineTextAlignment(.center)
                    
                    Button(action: { state.zoomScale = min(3.0, state.zoomScale + 0.1) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("100%") {
                        state.zoomScale = 1.0
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("Fit") {
                        state.fitToScreen()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.trailing, 10)
            }
            
            // Console toggle
            Button(action: { withAnimation { state.showConsole.toggle() } }) {
                Image(systemName: "terminal")
                    .foregroundColor(state.showConsole ? .accentColor : .gray)
            }
            .buttonStyle(.plain)
            .help("Toggle console output")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            VStack {
                Spacer()
                Divider()
            }
        )
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Segmented Picker for Tab Selectors
            HStack(spacing: 4) {
                TabButton(iconName: "square.grid.3x3", isSelected: state.activeTab == "layout", helpText: "Layout Settings") {
                    state.activeTab = "layout"
                }
                TabButton(iconName: "paintbrush", isSelected: state.activeTab == "style", helpText: "Style Settings") {
                    state.activeTab = "style"
                }
                TabButton(iconName: "clock", isSelected: state.activeTab == "frames", helpText: "Frame Settings") {
                    state.activeTab = "frames"
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Tab Contents
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.activeTab == "layout" {
                        LayoutTab()
                    } else if state.activeTab == "style" {
                        StyleTab()
                    } else if state.activeTab == "frames" {
                        FramesTab()
                    }
                }
                .padding(12)
            }
            
            Spacer()
            
            Divider()
            
            // Bottom Action Area in Sidebar
            VStack(spacing: 8) {
                if state.isGenerating || state.isEstimatingDuration {
                    Button(action: {
                        state.cancelGeneration()
                    }) {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("Cancel")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                } else {
                    Button(action: {
                        state.generateContactSheet()
                    }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Generate")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.selectedVideo == nil || !state.isFFmpegInstalled)
                }
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Tab Panels

struct LayoutTab: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grid Dimensions")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)
            
            VStack(spacing: 8) {
                HStack {
                    Text("Columns")
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: {
                            if state.columns > 1 {
                                state.columns -= 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Text("\(state.columns)")
                            .frame(width: 22, alignment: .center)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                        
                        Button(action: {
                            if state.columns < 50 {
                                state.columns += 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
                HStack {
                    Text("Rows")
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: {
                            if state.rows > 1 {
                                state.rows -= 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Text("\(state.rows)")
                            .frame(width: 22, alignment: .center)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                        
                        Button(action: {
                            if state.rows < 50 {
                                state.rows += 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            Divider()
            
            Text("Output Options")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Image Width")
                    Spacer()
                    Text("\(state.imageWidth) px")
                }
                Slider(value: Binding(
                    get: { Double(state.imageWidth) },
                    set: { state.imageWidth = Int($0) }
                ), in: 600...3200, step: 50.0)
                
                if state.selectedVideo != nil {
                    HStack {
                        Text("Image Height")
                        Spacer()
                        Text("\(state.estimatedHeight) px")
                    }
                    Slider(value: Binding(
                        get: { Double(state.estimatedHeight) },
                        set: { state.updateWidthFromHeight(Int($0)) }
                    ), in: state.minHeight...state.maxHeight, step: 10.0)
                }
                
                HStack {
                    Text("Grid Spacing")
                    Spacer()
                    Text("\(state.gridSpacing) px")
                }
                Slider(value: Binding(
                    get: { Double(state.gridSpacing) },
                    set: { state.gridSpacing = Int($0) }
                ), in: 0...50, step: 1.0)
            }
        }
        .monoFont()
    }
}



struct StyleTab: View {
    @EnvironmentObject var state: AppState
    
    // Preset Colors
    let bgPresets: [Color] = [.black, Color(red: 0.1, green: 0.1, blue: 0.1), Color(red: 0.8, green: 0.8, blue: 0.8), .white]
    let fgPresets: [Color] = [.white, Color(red: 0.7, green: 0.7, blue: 0.7), .yellow, .black]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Font settings
            Text("Font Settings")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Font Family")
                    .font(.caption)
                Picker("", selection: Binding(
                    get: { state.selectedFont },
                    set: {
                        state.selectedFont = $0
                        state.autoGenerateIfNeeded()
                    }
                )) {
                    Text("Hiragino Sans (Default)").tag("Hiragino Sans")
                    Text("Helvetica").tag("Helvetica")
                    Text("Times New Roman").tag("Times")
                    Text("Custom...").tag("Custom")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                if state.selectedFont == "Custom" {
                    HStack(spacing: 8) {
                        Text(state.customFontPath.isEmpty ? "No font selected" : URL(fileURLWithPath: state.customFontPath).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.gray)
                            .font(.system(size: 10, design: .monospaced))
                        
                        Button("Browse") {
                            selectCustomFontFile()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.bottom, 6)
            
            Divider()
            
            // Color presets
            Text("Colors")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)
            
            ColorPresetSelector(title: "Background Color", selectedColor: Binding(
                get: { state.backgroundColor },
                set: {
                    state.backgroundColor = $0
                    state.autoGenerateIfNeeded()
                }
            ), presets: bgPresets)
            
            ColorPresetSelector(title: "Text/Font Color", selectedColor: Binding(
                get: { state.textColor },
                set: {
                    state.textColor = $0
                    state.autoGenerateIfNeeded()
                }
            ), presets: fgPresets)
            
            Divider()
            
            // Layout & Options
            Text("Visual Elements")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)
            
            Toggle("Show Movie Info Header", isOn: Binding(
                get: { state.showHeader },
                set: {
                    state.showHeader = $0
                    state.autoGenerateIfNeeded()
                }
            ))
            .toggleStyle(.checkbox)
            
            if state.showHeader {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Customize Header Text", isOn: Binding(
                        get: { state.useCustomHeaderTemplate },
                        set: {
                            state.useCustomHeaderTemplate = $0
                            state.autoGenerateIfNeeded()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    
                    if state.useCustomHeaderTemplate {
                        TextEditor(text: Binding(
                            get: { state.customHeaderTemplate },
                            set: {
                                state.customHeaderTemplate = $0
                            }
                        ))
                        .font(.system(size: 9, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.gray.opacity(0.3))
                        .cornerRadius(4)
                        
                        Text("Placeholders: {{filename}}, {{size}}, {{duration}}, {{sample_width}}x{{sample_height}}, {{video_codec}}, {{frame_rate}}")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 4)
            }
            
            Toggle("Show Timestamp overlays", isOn: Binding(
                get: { state.showTimestamps },
                set: {
                    state.showTimestamps = $0
                    state.autoGenerateIfNeeded()
                }
            ))
            .toggleStyle(.checkbox)
            
            if state.showTimestamps {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timestamp Position")
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { state.timestampPosition },
                            set: {
                                state.timestampPosition = $0
                                state.autoGenerateIfNeeded()
                            }
                        )) {
                            Text("Top-Left").tag("top-left")
                            Text("Top-Right").tag("top-right")
                            Text("Bottom-Left").tag("bottom-left")
                            Text("Bottom-Right").tag("bottom-right")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(.bottom, 4)
                    
                    Toggle("Customize Timestamps", isOn: Binding(
                        get: { state.useCustomTimestamps },
                        set: {
                            state.useCustomTimestamps = $0
                            state.autoGenerateIfNeeded()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    if state.useCustomTimestamps {
                        TextEditor(text: Binding(
                            get: { state.customTimestampsText },
                            set: {
                                state.customTimestampsText = $0
                            }
                        ))
                        .font(.system(size: 9, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.gray.opacity(0.3))
                        .cornerRadius(4)
                        
                        Text("Enter comma-separated timestamps (format: h:mm:ss.mmmm or mm:ss)\nExample: 0:01:15, 0:03:45.500")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 4)
            }
        }
        .monoFont()
    }
    
    private func selectCustomFontFile() {
        FontPanelBridge.shared.showFontPanel(currentFontName: state.selectedFont) { fontName in
            if let font = NSFont(name: fontName, size: 12.0) {
                let ctFont = font as CTFont
                if let url = CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL {
                    DispatchQueue.main.async {
                        state.selectedFont = "Custom"
                        state.customFontPath = url.path
                        state.autoGenerateIfNeeded()
                    }
                }
            }
        }
    }
}

struct ColorPresetSelector: View {
    let title: String
    @Binding var selectedColor: Color
    let presets: [Color]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: selectedColor == color ? 2 : 0)
                                .padding(-3)
                        )
                        .onTapGesture {
                            selectedColor = color
                        }
                }
            }
        }
    }
}

struct FramesTab: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto Sampling Range")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Start Delay")
                    Spacer()
                    Text("\(Int(state.startDelayPercent))%")
                }
                Slider(value: $state.startDelayPercent, in: 0...30, step: 1.0)
                Text("Ignores opening titles and credits.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.bottom, 4)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("End Delay")
                    Spacer()
                    Text("\(Int(state.endDelayPercent))%")
                }
                Slider(value: $state.endDelayPercent, in: 0...30, step: 1.0)
                Text("Ignores end credits and black screens.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .monoFont()
    }
}

// MARK: - Canvas Preview

struct CanvasView: View {
    @EnvironmentObject var state: AppState
    @State private var isTargeted = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    if let video = state.selectedVideo {
                        // Toolbar actions for loaded video
                        HStack {
                            // Video Info Card
                            HStack(spacing: 10) {
                                Image(systemName: "video.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(video.name)
                                            .fontWeight(.bold)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(video.formattedSize)
                                            .foregroundColor(.gray)
                                    }
                                    Text("Resolution: \(video.width)x\(video.height) | Duration: \(video.formattedDuration) | Codec: \(video.codec)")
                                        .foregroundColor(.gray)
                                }
                                .font(.system(size: 10, design: .monospaced))
                            }
                            
                            Spacer()

                            // Reveal file button
                            Button(action: {
                                NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: "")
                            }) {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                        .overlay(
                            VStack {
                                Spacer()
                                Divider()
                            }
                        )
                    }
                    
                    // Image Preview Area
                    ZStack {
                        if state.isEstimatingDuration {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Estimating duration…")
                                    .foregroundColor(.gray)
                                Text("This file's metadata has no duration; scanning packets.")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Button("Cancel") {
                                    state.cancelGeneration()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .monoFont()
                        } else if state.isGenerating {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Extracting frames and generating contact sheet...")
                                    .foregroundColor(.gray)
                            }
                            .monoFont()
                        } else if let image = state.previewImage {
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(
                                        width: CGFloat(state.imageWidth) * state.zoomScale,
                                        height: CGFloat(state.imageWidth) * image.aspectRatio * state.zoomScale
                                    )
                                    .padding(20)
                            }
                        } else {
                            // Drag & drop placeholder
                            VStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 40))
                                    .foregroundColor(isTargeted ? .accentColor : .secondary)
                                    .scaleEffect(isTargeted ? 1.05 : 1.0)
                                    .animation(.spring(), value: isTargeted)
                                
                                Text("Drag & Drop Video File Here")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                
                                Text("Or click below to browse")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                Button("Choose Video File") {
                                    state.openVideoPanel()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(state.isGenerating)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Export / Clipboard action bar
                    if state.previewImage != nil && !state.isGenerating {
                        Divider()
                        HStack(spacing: 12) {
                            Button(action: { state.copyToClipboard() }) {
                                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .keyboardShortcut("c", modifiers: .command)
                            
                            Button(action: { state.saveImageAs() }) {
                                Label("Save Image As...", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut("s", modifiers: .command)
                        }
                        .padding(10)
                        .background(Color(NSColor.windowBackgroundColor))
                    }
                }
                
                // FFmpeg missing overlay
                if !state.isFFmpegInstalled {
                    Color.black.opacity(0.55)
                        .edgesIgnoringSafeArea(.all)

                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)

                        Text("FFmpeg Not Found")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)

                        Text("FrameSheet v2 requires FFmpeg for frame extraction.\nInstall via Homebrew:")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)

                        Text("brew install ffmpeg")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)

                        VStack(alignment: .leading, spacing: 6) {
                            DependencyRow(title: "ffmpeg", path: state.ffmpegPath.isEmpty ? "Missing" : state.ffmpegPath)
                            DependencyRow(title: "ffprobe", path: state.ffprobePath.isEmpty ? "Missing" : state.ffprobePath)
                        }
                        .frame(width: 320)

                        Button(action: { state.checkDependencies() }) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(state.isCheckingDependencies)
                    }
                    .padding(24)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(radius: 12)
                    .frame(maxWidth: 400)
                }

                // Drop-target highlight when dragging over a loaded video
                if isTargeted && state.selectedVideo != nil {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            // Accept drops in every state: dropping a new file replaces the
            // currently loaded video (same path as File > Open).
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        DispatchQueue.main.async {
                            state.loadVideo(url: url)
                        }
                    }
                }
                return true
            }
            .onAppear {
                state.containerWidth = geometry.size.width
                state.containerHeight = geometry.size.height
            }
            .onChange(of: geometry.size.width) { newWidth in
                state.containerWidth = newWidth
            }
            .onChange(of: geometry.size.height) { newHeight in
                state.containerHeight = newHeight
            }
        }
    }
}

struct DependencyRow: View {
    let title: String
    let path: String
    
    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.bold)
            Spacer()
            Text(path)
                .foregroundColor(path == "Missing" || path.isEmpty ? .red : .gray)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.vertical, 3)
    }
}

// MARK: - Console Log Monitor

struct ConsoleView: View {
    @EnvironmentObject var state: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            // Console Header
            HStack {
                Label("Console Log Monitor", systemImage: "terminal.fill")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Copy All") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(state.consoleOutput, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                
                Divider()
                    .frame(height: 12)
                
                Button("Export Log") {
                    exportLogToFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                
                Divider()
                    .frame(height: 12)
                
                Button("Clear Logs") {
                    state.consoleOutput = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                
                Divider()
                    .frame(height: 12)
                
                Button(action: { withAnimation { state.showConsole = false } }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Output text area
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.consoleOutput.isEmpty ? "No log output yet." : state.consoleOutput)
                        .textSelection(.enabled) // Enable drag-selection and copy
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(state.consoleOutput.isEmpty ? .gray : Color(NSColor.textColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("bottom_anchor")
                }
                .background(Color(NSColor.controlBackgroundColor))
                .onChange(of: state.consoleOutput) {
                    // Automatically scroll to bottom on logs
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
        }
    }
    
    private func exportLogToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "framesheet_console_log.txt"
        
        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                do {
                    try state.consoleOutput.write(to: targetURL, atomically: true, encoding: .utf8)
                } catch {
                    state.errorMessage = "Failed to export log: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Font Modifiers

struct MonoFontModifier: ViewModifier {
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    func monoFont(size: CGFloat = 11, weight: Font.Weight = .regular) -> some View {
        self.modifier(MonoFontModifier(size: size, weight: weight))
    }
}

// MARK: - App Delegate (Finder / Dock file opens)

class AppDelegate: NSObject, NSApplicationDelegate {
    // Routes Finder/Dock file-open events into AppState.loadVideo(url:).
    // Set once the SwiftUI hierarchy is up; a URL arriving earlier (e.g.
    // app launched by double-clicking a movie) is stashed and delivered
    // as soon as the handler is assigned.
    static var openHandler: ((URL) -> Void)? {
        didSet {
            if let handler = openHandler, let url = pendingURL {
                pendingURL = nil
                handler(url)
            }
        }
    }
    private static var pendingURL: URL? = nil

    func application(_ application: NSApplication, open urls: [URL]) {
        // Single-file policy: the app holds at most one video at a time.
        guard let url = urls.first else { return }
        if let handler = AppDelegate.openHandler {
            handler(url)
        } else {
            AppDelegate.pendingURL = url
        }
    }
}

// MARK: - App Entrypoint

@main
struct FrameSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 950, minHeight: 650)
                .preferredColorScheme(.dark)
                .onAppear {
                    AppDelegate.openHandler = { url in
                        appState.handleOpenURL(url)
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    appState.openVideoPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

// MARK: - Font Panel Bridge

class FontPanelBridge: NSObject {
    static let shared = FontPanelBridge()
    var onFontChange: ((String) -> Void)?
    
    func showFontPanel(currentFontName: String, onFontChange: @escaping (String) -> Void) {
        self.onFontChange = onFontChange
        
        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.action = #selector(changeFont(_:))
        
        let fontPanel = fontManager.fontPanel(true)
        fontPanel?.makeKeyAndOrderFront(nil)
        
        if let currentFont = NSFont(name: currentFontName, size: 12.0) {
            fontManager.setSelectedFont(currentFont, isMultiple: false)
        }
    }
    
    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }
        let dummyFont = NSFont.systemFont(ofSize: 12)
        let selectedFont = fontManager.convert(dummyFont)
        let fontName = selectedFont.fontName
        onFontChange?(fontName)
    }
}

// MARK: - NSImage Extension

extension NSImage {
    var pixelSize: NSSize {
        if let representation = representations.first {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }
    
    var aspectRatio: CGFloat {
        let pSize = pixelSize
        guard pSize.width > 0 else { return 1.0 }
        return pSize.height / pSize.width
    }
}

// MARK: - Custom Tab Button Component

struct TabButton: View {
    let iconName: String
    let isSelected: Bool
    let helpText: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .regular)) // Adjusted to 22pt
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(isSelected ? Color(NSColor.selectedContentBackgroundColor).opacity(0.25) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
