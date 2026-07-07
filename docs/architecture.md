# Architecture - FrameSheet

## System Overview

FrameSheet follows a lightweight, single-binary Swift frontend model coordinating with the system's `ffmpeg`/`ffprobe` and a native CoreGraphics compositor. As of v2.0.0, there are no bundled binaries or Python dependencies.

```mermaid
graph TD
    A[SwiftUI Frontend] -->|Config & Actions| B[AppState Coordinator]
    B -->|ffprobe metadata| D[System FFmpeg/FFprobe]
    B -->|"Fast Mode: -skip_frame nokey<br/>Normal Mode: fps=1/interval<br/>(+ -hwaccel videotoolbox)"| D
    D -->|Extracts| E[Temporary Keyframe/Sampled JPEGs]
    E -->|Input Thumbnails| G[renderContactSheet<br/>CoreGraphics/AppKit Composite]
    G -->|Renders| H[Contact Sheet NSImage]
    B -->|Reads Preview| H
    B -->|Exports Image| F[User Selected Destination]
```

## Folder Structure & Components

```
FrameSheet
├── SwiftUI Frontend (main.swift)
│   ├── MainView (App Container & Drag-and-Drop)
│   ├── SidebarView (Control Panel)
│   │   ├── LayoutTab (Columns, Rows, Grid Spacing, Fast Mode toggle)
│   │   ├── StyleTab (Colors, Fonts, Timestamps, Custom Headers)
│   │   └── FramesTab (Auto Sampling Range: Start/End Delay, custom timestamp text)
│   ├── CanvasView (Zoomable Render Preview Area, Fast Mode keyframe-count indicator)
│   ├── TopBarView (Zoom Controls, Cancel / Generate Toggle)
│   └── ConsoleView (Process Output Stream Panel)
│
├── Services (AppState Coordinator Logic)
│   ├── FFmpegEngine (`generateContactSheet`): Builds and runs a single ffmpeg
│   │     invocation — Fast Mode (`-hwaccel videotoolbox -skip_frame nokey
│   │     -vsync vfr`) or Normal Mode (`-hwaccel videotoolbox -ss/-to
│   │     -vf fps=1/interval`) — writing temporary JPEG thumbnails
│   │     (`-q:v 3`), then streams logs to `ConsoleView`.
│   ├── ContactSheetRenderer (`renderContactSheet`): Composites the extracted
│   │     JPEG thumbnails into the final image using CoreGraphics/AppKit
│   │     (`NSAttributedString` for header/timestamp text). In Fast Mode,
│   │     also reconciles the actual keyframe count against the requested
│   │     `rows × columns` grid (even-sampling down, or shrinking row count
│   │     if fewer keyframes were extracted).
│   ├── FFmpegService (`loadVideoMetadata`): Uses `ffprobe -v error
│   │     -show_entries ... -of json` to extract stream duration, dimensions,
│   │     and format details to generate accurate scale previews.
│   └── ExportService (`savePreviewImage`): Handles UI file export workflows
│         using `NSSavePanel`, resolving dynamic naming patterns like
│         `[filename]_sheet.png` and managing destination writes.
│
└── Resources
    └── (none bundled — ffmpeg/ffprobe are resolved from the system PATH)
```

### Component Details

#### 1. SwiftUI Frontend
- **MainView**: The core window coordinator. Manages file drop handlers (`onDragOver` / `performDrop`) and links state variables.
- **SidebarView**: Configures layout, style, and frames using a segmented picker interface. The Layout tab includes the "Fast mode: keyframes only" toggle (enabled by default).
- **CanvasView**: A dynamic, aspect-ratio-locked preview layer that renders generated contact sheets with mouse-wheel zoom capabilities. Displays the `Fast mode: X of Y keyframes` indicator next to "Show in Finder" when Fast Mode is active.
- **TopBarView**: Provides responsive zoom triggers and unified `Generate/Cancel` functionality.
- **ConsoleView**: Outputs stdout/stderr streams from the ffmpeg child process to aid user troubleshooting.

#### 2. Services (Logical Architecture inside `AppState`)
- **FFmpegEngine (`generateContactSheet`)**: Computes sampling parameters (columns, rows, spacing, start/end delay, custom timestamps) and builds one of three ffmpeg command variants — Fast Mode (keyframes only), Custom Timestamps (`select` filter), or Normal Mode (`fps=1/interval`) — all using `-hwaccel videotoolbox` and JPEG (`-q:v 3`) temporary output. Runs the command asynchronously via `Process` and streams logs to `ConsoleView`.
- **ContactSheetRenderer (`renderContactSheet`)**: Composites the extracted JPEG thumbnails and overlays (header, timestamps) into the final `NSImage` using CoreGraphics bitmap contexts and `NSAttributedString`. In Fast Mode, reconciles the actual extracted keyframe count (`jpgCount`) against the requested `rows × columns`: even-samples down if more keyframes were extracted than requested, or shrinks the row count to fit if fewer were extracted.
- **FFmpegService (`loadVideoMetadata`)**: Uses `ffprobe -v error -show_entries ... -of json` to extract stream duration, dimensions, and format details to generate accurate scale previews.
- **ExportService (`savePreviewImage`)**: Handles UI file export workflows using `NSSavePanel`, resolving dynamic naming patterns like `[filename]_sheet.png` and managing destination writes.

#### 3. Resources
- No bundled binaries. `ffmpeg`/`ffprobe` are resolved from the system PATH (e.g. Homebrew install) and checked on launch via the dependency overlay.
