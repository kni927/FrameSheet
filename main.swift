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
    @Published var pythonPath: String = ""
    @Published var ffmpegPath: String = ""
    @Published var ffprobePath: String = ""
    @Published var vcsiPath: String = ""
    @Published var isVcsiInstalled: Bool = false
    @Published var dependencyCheckMessage: String = "Initializing..."
    @Published var isCheckingDependencies: Bool = false
    @Published var isInstallingVcsi: Bool = false
    
    // Application Running States
    @Published var isGenerating: Bool = false
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
    
    private var activeProcess: Process? = nil
    private var generateDebounceWorkItem: DispatchWorkItem? = nil

    init() {
        checkDependencies()
    }
    
    // Check system commands and Python packages
    func checkDependencies() {
        self.isCheckingDependencies = true
        self.dependencyCheckMessage = "Checking environment..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Find system commands
            let py = self.findCommandPath("python3")
            let ff = self.findCommandPath("ffmpeg")
            let probe = self.findCommandPath("ffprobe")
            let vcsi = self.findCommandPath("vcsi")
            
            let vcsiOk = !vcsi.isEmpty
            
            DispatchQueue.main.async {
                self.pythonPath = py
                self.ffmpegPath = ff
                self.ffprobePath = probe
                self.vcsiPath = vcsi
                self.isVcsiInstalled = vcsiOk
                self.isCheckingDependencies = false
                
                if py.isEmpty {
                    self.dependencyCheckMessage = "Python 3 is not found. Please install Python."
                } else if ff.isEmpty || probe.isEmpty {
                    self.dependencyCheckMessage = "FFmpeg/FFprobe not found. Please install via Homebrew: 'brew install ffmpeg'."
                } else if !vcsiOk {
                    self.dependencyCheckMessage = "vcsi command line tool is missing. Click 'Install vcsi' below."
                } else {
                    self.dependencyCheckMessage = "All dependencies are satisfied. Ready!"
                }
            }
        }
    }
    
    private func findCommandPath(_ cmd: String) -> String {
        // For vcsi, check App Bundle resources first to use the bundled standalone version
        if cmd == "vcsi" {
            if let bundlePath = Bundle.main.path(forResource: "vcsi", ofType: nil, inDirectory: "bin") {
                if FileManager.default.isExecutableFile(atPath: bundlePath) {
                    return bundlePath
                }
            }
        }
        
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
    
    // Install vcsi automatically via pip
    func installVcsi() {
        guard !pythonPath.isEmpty else {
            self.errorMessage = "Cannot install: Python3 path is empty."
            return
        }
        
        self.isInstallingVcsi = true
        self.consoleOutput += "\n>>> Running installation: \(pythonPath) -m pip install vcsi\n"
        
        let installCmd = "\(pythonPath) -m pip install vcsi"
        
        runCommandStreaming(installCmd, onStdout: { text in
            self.consoleOutput += text
        }, onStderr: { err in
            self.consoleOutput += err
        }, completion: { status in
            self.isInstallingVcsi = false
            if status == 0 {
                self.consoleOutput += "\n>>> vcsi installed successfully!\n"
                self.checkDependencies()
            } else {
                self.consoleOutput += "\n>>> Failed to install vcsi. Status code: \(status)\n"
                self.errorMessage = "Failed to install vcsi. Check console logs."
            }
        })
    }
    
    // Load Video details via ffprobe
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
            self.consoleOutput += "Successfully loaded video:\n - Codec: \(videoInfo.codec)\n - Resolution: \(videoInfo.width)x\(videoInfo.height)\n - Duration: \(videoInfo.formattedDuration)\n - Size: \(videoInfo.formattedSize)\n"
            
            // Auto generate initial contact sheet
            generateContactSheet()
            
        } catch {
            self.errorMessage = "Failed to parse metadata JSON: \(error.localizedDescription)"
            self.consoleOutput += "JSON parsing error: \(error)\n"
        }
    }
    
    // Generate the MoviePrint image
    func generateContactSheet() {
        guard let video = selectedVideo else {
            self.errorMessage = "Please select a video file first."
            return
        }
        
        guard !vcsiPath.isEmpty && isVcsiInstalled else {
            self.errorMessage = "vcsi dependency is missing. Verify environment."
            return
        }
        
        self.isGenerating = true
        self.errorMessage = nil
        self.previewImage = nil
        
        // Output file in temporary directory
        let tempDir = NSTemporaryDirectory()
        let outputFilename = "framesheet_\(Int(Date().timeIntervalSince1970)).png"
        let outputPath = (tempDir as NSString).appendingPathComponent(outputFilename)
        self.previewImagePath = outputPath
        
        // Map UI timestamp position to vcsi expected direction string
        var vcsiPosition = "se"
        switch timestampPosition {
        case "top-left": vcsiPosition = "nw"
        case "top-right": vcsiPosition = "ne"
        case "bottom-left": vcsiPosition = "sw"
        case "bottom-right": vcsiPosition = "se"
        default: vcsiPosition = "se"
        }
        
        let nfcVcsiPath = vcsiPath.precomposedStringWithCanonicalMapping
        let nfcVideoPath = video.path.precomposedStringWithCanonicalMapping
        let nfcOutputPath = outputPath.precomposedStringWithCanonicalMapping
        
        // Construct arguments
        var args = [
            "\"\(nfcVcsiPath)\"",
            "\"\(nfcVideoPath)\"",
            "-o \"\(nfcOutputPath)\"",
            "-g \(columns)x\(rows)",
            "-w \(imageWidth)",
            "--grid-spacing \(gridSpacing)",
            "--background-color \(backgroundColor.toHex())",
            "--metadata-font-color \(textColor.toHex())",
            "--timestamp-font-color \(textColor.toHex())",
            "--timestamp-position \(vcsiPosition)"
        ]
        
        // Font setup
        var fontPath = ""
        switch selectedFont {
        case "Hiragino Sans":
            let rawPath = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
            let decomposed = rawPath.decomposedStringWithCanonicalMapping
            let precomposed = rawPath.precomposedStringWithCanonicalMapping
            if FileManager.default.fileExists(atPath: decomposed) {
                fontPath = decomposed
            } else if FileManager.default.fileExists(atPath: precomposed) {
                fontPath = precomposed
            } else {
                fontPath = rawPath
            }
        case "Helvetica":
            fontPath = "/System/Library/Fonts/Helvetica.ttc"
        case "Times":
            fontPath = "/System/Library/Fonts/Times.ttc"
        case "Custom":
            fontPath = customFontPath
        default:
            break
        }
        if !fontPath.isEmpty && FileManager.default.fileExists(atPath: fontPath) {
            let nfcFontPath = fontPath.precomposedStringWithCanonicalMapping
            args.append("--timestamp-font \"\(nfcFontPath)\"")
            args.append("--metadata-font \"\(nfcFontPath)\"")
        }
        
        // Metadata header visibility / custom template
        var tempTemplatePath: String? = nil
        if showHeader {
            args.append("--metadata-position top")
            
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let tempDir = NSTemporaryDirectory()
                let templateFilename = "header_template_\(Int(Date().timeIntervalSince1970)).txt"
                let templatePath = (tempDir as NSString).appendingPathComponent(templateFilename)
                
                do {
                    try customHeaderTemplate.write(toFile: templatePath, atomically: true, encoding: .utf8)
                    tempTemplatePath = templatePath
                    let nfcTemplatePath = templatePath.precomposedStringWithCanonicalMapping
                    args.append("--template \"\(nfcTemplatePath)\"")
                } catch {
                    self.consoleOutput += "\n>>> Warning: Failed to write custom header template to temp file: \(error.localizedDescription)\n"
                }
            }
        } else {
            args.append("--metadata-position hidden")
        }
        
        // Timestamps visibility / custom timestamps
        if useCustomTimestamps && !customTimestampsText.isEmpty {
            // Clean up custom timestamps text (comma separated)
            let cleanedTimes = customTimestampsText
                .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            
            if !cleanedTimes.isEmpty {
                args.append("-t \"\(cleanedTimes)\"")
            } else if showTimestamps {
                args.append("-t")
            }
        } else if showTimestamps {
            args.append("-t")
        }
        
        // Delays
        args.append("--start-delay-percent \(Int(startDelayPercent))")
        args.append("--end-delay-percent \(Int(endDelayPercent))")
        
        // Combined command
        let fullCmd = args.joined(separator: " ")
        self.consoleOutput += "\n>>> Running command:\n\(fullCmd)\n"
        
        runCommandStreaming(fullCmd, onStdout: { text in
            self.consoleOutput += text
        }, onStderr: { err in
            self.consoleOutput += err
        }, completion: { status in
            self.isGenerating = false
            
            // Clean up temp template file if created
            if let path = tempTemplatePath {
                try? FileManager.default.removeItem(atPath: path)
            }
            
            if status == 0 {
                self.consoleOutput += "\n>>> Contact sheet generated successfully!\n"
                
                // Load preview image
                if FileManager.default.fileExists(atPath: outputPath) {
                    if let image = NSImage(contentsOfFile: outputPath) {
                        self.previewImage = image
                        self.consoleOutput += "Loaded image preview from temp folder.\n"
                        self.fitToScreen()
                    } else {
                        self.errorMessage = "Failed to load generated image."
                    }
                } else {
                    self.errorMessage = "Output file not found at: \(outputPath)"
                }
            } else {
                self.consoleOutput += "\n>>> Generation failed with status code: \(status)\n"
                self.errorMessage = "vcsi failed to generate contact sheet. See console log."
            }
        })
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
    
    // Run command in background with streaming output
    private func runCommandStreaming(
        _ command: String,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void,
        completion: @escaping (Int32) -> Void
    ) {
        // Kill existing process if any
        activeProcess?.terminate()
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        // Force include miniforge and homebrew paths
        env["PATH"] = "/Users/kni/miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + currentPath
        task.environment = env
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        
        self.activeProcess = task
        
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    onStdout(str)
                }
            }
        }
        
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    onStderr(str)
                }
            }
        }
        
        task.terminationHandler = { t in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.activeProcess = nil
                completion(t.terminationStatus)
            }
        }
        
        do {
            try task.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.activeProcess = nil
                onStderr("Execution Error: \(error.localizedDescription)\n")
                completion(-1)
            }
        }
    }
    
    func cancelGeneration() {
        if let process = activeProcess, process.isRunning {
            process.terminate()
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
                if state.isGenerating {
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
                    .disabled(state.selectedVideo == nil || !state.isVcsiInstalled)
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
                        if state.isGenerating {
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
                                    selectVideoFile()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(state.isGenerating)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
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
                
                // Missing Dependencies Overlay Card
                if !state.isVcsiInstalled {
                    Color.black.opacity(0.55)
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        
                        Text("Dependencies Missing")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        
                        Text("FrameSheet requires the 'vcsi' command-line utility to generate sheets.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            DependencyRow(title: "Python 3", path: state.pythonPath)
                            DependencyRow(title: "FFmpeg/FFprobe", path: state.ffmpegPath.isEmpty ? "Missing" : "Found")
                        }
                        .frame(width: 320)
                        
                        if !state.pythonPath.isEmpty {
                            Button(action: { state.installVcsi() }) {
                                HStack {
                                    if state.isInstallingVcsi {
                                        ProgressView().controlSize(.small).padding(.trailing, 4)
                                    }
                                    Text(state.isInstallingVcsi ? "Installing vcsi..." : "Install vcsi (pip)")
                                }
                                .frame(width: 200)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.isInstallingVcsi)
                        } else {
                            Text("Please install Python 3 or FFmpeg to continue.")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        
                        Button(action: { state.checkDependencies() }) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
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
                    .frame(maxWidth: 380)
                }
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
    
    private func selectVideoFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        openPanel.begin { response in
            if response == .OK, let fileURL = openPanel.url {
                state.loadVideo(url: fileURL)
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

// MARK: - App Entrypoint

@main
struct FrameSheetApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 950, minHeight: 650)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
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
