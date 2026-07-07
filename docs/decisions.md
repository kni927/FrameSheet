# Design Decisions - FrameSheet

This document outlines key technical trade-offs and structural architectural choices made during the development of FrameSheet.

## Summary of Decisions

### 1. FFmpeg is not bundled

#### Context
FrameSheet's native ffmpeg engine depends on `ffmpeg` and `ffprobe` to probe video metadata and extract thumbnail frames.

#### Decision
We explicitly chose **not** to bundle FFmpeg binaries inside the `FrameSheet.app` package. Instead, the application relies on the system PATH to discover `ffmpeg`/`ffprobe` or searches common installation prefixes (e.g., Homebrew, Miniforge).

#### Rationale
- **Distribution Size**: Bundling FFmpeg binaries would increase the app package size by ~80-100MB, whereas the core app is less than 15MB.
- **Licensing Considerations**: FFmpeg has complex GPL/LGPL configurations. Requiring external installation mitigates license redistribution liabilities.
- **Ease of Installation**: Target power users typically already have Homebrew (`brew install ffmpeg`) or have standard media tools installed on their Macs.

---

### 2. vcsi removed in favor of a native ffmpeg + CoreGraphics engine (v2.0.0)

> **Note**: This decision reverses the original "vcsi is bundled" decision below it was superseded by, which is retained for historical context.

#### Context
`vcsi` (Video Contact Sheet Generator) was a Python-based utility, originally bundled as a standalone PyInstaller binary (see superseded decision below). Its per-frame random-seek extraction made HEVC/4K contact sheets very slow (1m52s–6m42s for a 4×4 grid), and its Pillow-based text rendering did not support system font fallback.

#### Decision
We removed `vcsi` and all Python dependencies entirely. Contact sheets are now generated via a native `ffmpeg` extraction pass (`-hwaccel videotoolbox`, plus `fps=1/interval` for Normal Mode or `-skip_frame nokey` for Fast Mode, writing JPEG `-q:v 3` temporaries) and composited in Swift using CoreGraphics/AppKit (`renderContactSheet`, `NSAttributedString`).

#### Rationale
- **Performance**: Sequential single-pass decoding (Normal Mode, ~2.5–4 min) and especially keyframe-only Fast Mode (<1 second on a 4K60 60s clip) are dramatically faster than vcsi's per-frame seeking.
- **No Python Runtime Anywhere**: Removes the PyInstaller-frozen `vcsi` binary, its packaging step in `build.sh`, and all Python dependencies — simplifying the build and reducing app size.
- **Native Text Rendering**: CoreGraphics/`NSAttributedString` rendering uses system font fallback, addressing limitations of Pillow-based text rendering.
- **Maintainability**: A single ffmpeg invocation plus Swift-side compositing is easier to reason about and debug than shelling out to a frozen third-party Python CLI.

---

### 2a. (Superseded) vcsi was bundled

> **Superseded by Decision 2 above (v2.0.0).** Retained for historical context per project policy.

#### Context
`vcsi` (Video Contact Sheet Generator) is a Python-based utility. Running it natively requires a Python environment, Python packages (`pillow`, `jinja2`, etc.), and proper CLI bindings.

#### Decision
We compile the `vcsi` Python CLI into a standalone, single-executable binary using PyInstaller and place it directly into the application's bundle resources under `Contents/Resources/bin/vcsi`.

#### Rationale
- **No Python Runtime Requirement**: Eliminates the need for end-users to install Python, configure virtualenvs, or manage `pip` dependencies.
- **Simplified Setup**: Out-of-the-box operation. The app works instantly after drag-and-drop once FFmpeg is present.
- **Guaranteed Compatibility**: Freezing `vcsi` locks the internal engine version (v7.0.3), preventing compatibility breakages from upstream package updates.

---

### 3. Monolithic SwiftUI Layout (`main.swift`)

#### Context
Modular Swift projects usually separate views, models, and utility files.

#### Decision
We maintain the frontend codebase inside a single `main.swift` file.

#### Rationale
- **Lightweight Compiler Footprint**: Keeps the project easy to compile on any macOS system using a single `swiftc` call without requiring complex Xcode project wrappers.
- **Portable Script-Like Workflow**: Allows easy automation, rapid updates via LLM/agent setups, and simple build scripts (`build.sh`).

---

### 4. Fast Mode (keyframes only) is enabled by default (v2.0.0)

#### Context
Even with the v2.0.0 ffmpeg single-pass engine, Normal Mode's `fps=1/interval` filter requires decoding every frame in the sampled range, which remains slow for long and/or high-fps HEVC sources (~2.5–4 min for a typical 4K clip, several minutes for 240fps slow-motion footage). Loading a video and immediately triggering this full decode made the first preview feel sluggish.

#### Decision
`fastModeKeyframesOnly` defaults to `true`. The initial preview after loading a video uses `-skip_frame nokey -vsync vfr` to extract only keyframes, composited into the requested grid (even-sampling down, or shrinking the row count if fewer keyframes than `rows × columns` exist). A `Fast mode: X of Y keyframes` indicator reports the actual vs. extracted counts. Users can toggle Fast Mode off in the Layout tab to fall back to Normal Mode for an exact, evenly-spaced grid.

#### Rationale
- **Instant First Impression**: A 4K60 60s clip produces a Fast Mode preview in well under a second, versus ~25 seconds in Normal Mode.
- **Opt-in Precision**: Users who need exact, evenly-spaced timestamps or custom timestamps (disabled in Fast Mode) can explicitly switch to Normal Mode.
- **Transparent Trade-offs**: The keyframe-count indicator and UI copy make it clear when the thumbnail count or timestamps are approximate, avoiding silent surprises.
