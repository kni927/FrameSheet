import SwiftUI
import Foundation
import AppKit

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
    // Backing data for the currently-displayed grid. `generateContactSheet()`
    // populates this and the renderer flattens from it; the display path is
    // still a single composited `previewImage` for now (Phase 3a wires up
    // per-thumbnail UI against this array).
    @Published var thumbnails: [Thumbnail] = []

    // UI Helpers
    @Published var showConsole: Bool = false // Default OFF
    @Published var zoomScale: CGFloat = 1.0
    @Published var containerWidth: CGFloat = 800.0
    @Published var containerHeight: CGFloat = 600.0

    var generateDebounceWorkItem: DispatchWorkItem? = nil
    // Incremented per generation; a superseded run (e.g. replaced by a new
    // video load while extraction was in flight) must not touch shared state.
    var generationID = 0
    // Parallel extraction bookkeeping (guarded by processLock)
    let processLock = NSLock()
    var parallelProcesses: [Process] = []
    var parallelCancelled = false
    // Duration-estimation bookkeeping (guarded by processLock)
    var estimationProcess: Process? = nil
    var estimationCancelled = false
    // Entry point for Finder/Dock open events. Defers the load while the
    // async ffmpeg dependency check is still running, so the initial
    // auto-generation doesn't race a not-yet-set ffmpeg path.
    var pendingOpenURL: URL? = nil

    init() {
        checkDependencies()
    }
}
