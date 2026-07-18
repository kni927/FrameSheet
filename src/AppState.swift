import SwiftUI
import Foundation
import AppKit

// MARK: - App State

class AppState: ObservableObject {
    // Media State
    @Published var selectedVideo: VideoFileInfo? = nil

    // Layout Options
    @Published var columns: Int = 4 { didSet { persistSettings() } }
    @Published var rows: Int = 4 { didSet { persistSettings() } }
    @Published var imageWidth: Int = 1200 { didSet { persistSettings() } }
    @Published var gridSpacing: Int = 10 { didSet { persistSettings() } }

    // Style Options
    @Published var showTimestamps: Bool = true { didSet { persistSettings() } }
    @Published var showHeader: Bool = true { didSet { persistSettings() } }
    @Published var useCustomHeaderTemplate: Bool = false { didSet { persistSettings() } }
    @Published var customHeaderTemplate: String = """
{{filename}}
File size: {{size}}
Duration: {{duration}}
Dimensions: {{sample_width}}x{{sample_height}}
""" { didSet { persistSettings() } }
    @Published var backgroundColor: Color = .black { didSet { persistSettings() } }
    @Published var textColor: Color = .white { didSet { persistSettings() } }
    @Published var cornerRadius: Int = 0 { didSet { persistSettings() } }

    // Font & Position Options
    @Published var selectedFont: String = "Hiragino Sans" { didSet { persistSettings() } } // Hiragino Sans, Helvetica, Times, Custom
    @Published var customFontPath: String = "" { didSet { persistSettings() } }
    @Published var timestampPosition: String = "bottom-right" { didSet { persistSettings() } } // top-left, top-right, bottom-left, bottom-right

    // Range & Custom Frames
    @Published var startDelayPercent: Double = 5 { didSet { persistSettings() } }
    @Published var endDelayPercent: Double = 5 { didSet { persistSettings() } }
    @Published var useCustomTimestamps: Bool = false { didSet { persistSettings() } }
    @Published var customTimestampsText: String = "" { didSet { persistSettings() } }

    // Output Options (Phase 2)
    @Published var outputFormat: String = "png" { didSet { persistSettings() } } // png, jpeg
    @Published var jpegQuality: Double = 90 { didSet { persistSettings() } } // 50-100
    @Published var filenameTemplate: String = "{{filename}}_sheet" { didSet { persistSettings() } }
    @Published var overwriteExisting: Bool = false { didSet { persistSettings() } }
    @Published var includeIndividualFrames: Bool = false { didSet { persistSettings() } }

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
    // populates this; the canvas shows one addressable cell per element
    // (Phase 3a) and the renderer flattens the same array for export.
    @Published var thumbnails: [Thumbnail] = []
    // Per-cell display images + header strip, rendered alongside the export
    // composite from the same drawCell code path. Keyed by Thumbnail.id.
    @Published var cellImages: [UUID: NSImage] = [:]
    @Published var headerImage: NSImage? = nil
    // Params snapshot the current cellImages were rendered with — the grid
    // lays out from this, not live settings, so an in-flight settings change
    // can't shear the display before regeneration completes.
    @Published var displayParams: GenerationParams? = nil

    // UI Helpers (transient — not persisted)
    @Published var showConsole: Bool = false // Default OFF
    @Published var zoomScale: CGFloat = 1.0
    @Published var containerWidth: CGFloat = 800.0
    @Published var containerHeight: CGFloat = 600.0

    var generateDebounceWorkItem: DispatchWorkItem? = nil
    // Incremented per generation; a superseded run (e.g. replaced by a new
    // video load while extraction was in flight) must not touch shared state.
    var generationID = 0
    // Frames backing the current `thumbnails` array. Retained after render
    // (individual-frame export reads from here); replaced on the next
    // generation. Lives under NSTemporaryDirectory, so the OS reclaims it
    // eventually regardless.
    var currentFramesDir: String? = nil
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
    // Suppresses persistSettings() while init loads stored values, so the
    // load itself doesn't write defaults back.
    var isLoadingSettings = false

    // Alpha component of the contact-sheet background (1.0 = opaque)
    var backgroundAlpha: CGFloat {
        NSColor(backgroundColor).usingColorSpace(.sRGB)?.alphaComponent ?? 1.0
    }

    init() {
        loadSettings()
        checkDependencies()
    }
}
