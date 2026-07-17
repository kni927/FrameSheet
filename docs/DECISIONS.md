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

### 3. (Superseded) Monolithic SwiftUI Layout (`main.swift`)

> **Superseded in Phase 1, Stage A (2026-07-18).** The single file grew to 2208 lines and became a bottleneck for the MoviePrint-convergence work in `docs/UI_AUDIT.md`; see Decision 5 below. Retained for historical context per project policy.

#### Context
Modular Swift projects usually separate views, models, and utility files.

#### Decision
We maintain the frontend codebase inside a single `main.swift` file.

#### Rationale
- **Lightweight Compiler Footprint**: Keeps the project easy to compile on any macOS system using a single `swiftc` call without requiring complex Xcode project wrappers.
- **Portable Script-Like Workflow**: Allows easy automation, rapid updates via LLM/agent setups, and simple build scripts (`build.sh`).

---

### 4. (Superseded) Fast Mode (keyframes only) was enabled by default (v2.0.0)

> **Superseded in Phase 3 (2026-07-07).** Fast Mode was removed entirely: the Phase 2 per-frame input-seeking engine made the standard path fast enough (60-min H.264 in ~1 s) that a keyframe-only preview no longer paid for its complexity, and its `-skip_frame nokey` single pass hung on WebM sources lacking cues. Retained for historical context per project policy.

#### Context
Even with the v2.0.0 ffmpeg single-pass engine, Normal Mode's `fps=1/interval` filter requires decoding every frame in the sampled range, which remains slow for long and/or high-fps HEVC sources (~2.5–4 min for a typical 4K clip, several minutes for 240fps slow-motion footage). Loading a video and immediately triggering this full decode made the first preview feel sluggish.

#### Decision
`fastModeKeyframesOnly` defaults to `true`. The initial preview after loading a video uses `-skip_frame nokey -vsync vfr` to extract only keyframes, composited into the requested grid (even-sampling down, or shrinking the row count if fewer keyframes than `rows × columns` exist). A `Fast mode: X of Y keyframes` indicator reports the actual vs. extracted counts. Users can toggle Fast Mode off in the Layout tab to fall back to Normal Mode for an exact, evenly-spaced grid.

#### Rationale
- **Instant First Impression**: A 4K60 60s clip produces a Fast Mode preview in well under a second, versus ~25 seconds in Normal Mode.
- **Opt-in Precision**: Users who need exact, evenly-spaced timestamps or custom timestamps (disabled in Fast Mode) can explicitly switch to Normal Mode.
- **Transparent Trade-offs**: The keyframe-count indicator and UI copy make it clear when the thumbnail count or timestamps are approximate, avoiding silent surprises.

---

### 5. Multi-file SwiftUI layout, split by concern (Phase 1, Stage A — 2026-07-18)

#### Context
`docs/UI_AUDIT.md` identified the single `main.swift` (2208 lines) as the main obstacle to absorbing a MoviePrint-style layout: no per-thumbnail interactivity is feasible while the render pipeline, all app state, and every view live in one file with no separable renderer.

#### Decision
Split into `Models.swift`; `AppState.swift` plus `AppState+Dependencies/Loading/Generation/Sizing.swift` extensions; `Views/` (+ `Tabs/` and `Components/` subdirectories); `AppDelegate.swift`, `FrameSheetApp.swift`, `FontPanelBridge.swift`; `Extensions.swift`; and a standalone `ContactSheetRenderer.swift` with no dependency on `AppState` or any View type. `build.sh` now compiles the full source tree (`find … -name "*.swift"`) instead of naming one entrypoint. This supersedes Decision 3 above.

#### Rationale
- **Unblocks Phase 2/3**: A separable renderer and a per-thumbnail `Thumbnail` model (also introduced in this stage) are prerequisites for any per-thumbnail interactivity or settings growth planned in `docs/UI_AUDIT.md`.
- **No behavior change, provably**: Verified with a byte-for-byte diff harness (fixed thumbnails + fixed params, run against the pre- and post-split renderer) rather than relying on visual inspection alone.
- **Keeps the `swiftc`-only build**: `build.sh` still does a single `swiftc` invocation over multiple files — no Xcode project wrapper introduced, preserving Decision 3's original build-simplicity rationale even though the single-file layout itself is gone.

---

### 6. Sidebar settings panel: single-scroll column instead of tabs (Phase 1, Stage B — 2026-07-18)

#### Context
`docs/UI_AUDIT.md` flagged the Layout/Style/Frames tab switcher as a layout decision that would need to be made before growing the settings panel toward MoviePrint parity (Output/Naming/Experimental sections): MoviePrint's own settings panel is one continuously scrolling column with section dividers, not tabs.

#### Decision
Adopted MoviePrint's single-scroll-column layout. Removed the tab switcher (`TabButton`, `AppState.activeTab`) and concatenated the three former tabs' content directly, in the same order they previously appeared: Grid Dimensions → Output Options → Font → Colors → Visual Elements → Auto Sampling Range, with dividers between each. The Generate/Cancel action area stays pinned outside the `ScrollView`. Sidebar width grew from 180px (160–220 range) to 240px (200–280 range) to fit the denser column.

#### Rationale
- **Matches the convergence target**: Keeps the settings panel structurally aligned with MoviePrint ahead of Phase 2's planned Output/Naming/Experimental additions, which would have needed a 4th tab or this same flattening later anyway.
- **No content reordering**: Preserves the exact Layout → Style → Frames content order, minimizing the chance of behavior or muscle-memory regressions for existing users.
- **No rendering impact**: Confirmed via the same byte-for-byte diff harness from Decision 5 (unaffected, as expected — no rendering code was touched) plus interactive verification of every control.
