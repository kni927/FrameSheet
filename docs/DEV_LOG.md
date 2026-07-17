# Development Log - FrameSheet

This log details the features, design changes, and bug fixes implemented during the development of FrameSheet.

---

## [Unreleased] — UI Audit - 2026-07-18

### Docs
- **MoviePrint gap analysis** (`docs/UI_AUDIT.md`): Audit-only comparison of FrameSheet's current SwiftUI UI against MoviePrint (`fakob/MoviePrint_v004`), the visual reference this app should converge toward. Covers a full FrameSheet view/settings/state inventory, a MoviePrint inventory from reference screenshots and its README, a 6-area gap table with effort estimates, a refactoring-readiness assessment (main.swift split plan, renderer separability, the state-model change needed for per-thumbnail live preview), and a phased Phase 1/2/3 recommendation. No UI or application code changed.

---

## [Unreleased] — Housekeeping - 2026-07-18

### Repo
- **Migrated to repo-template conventions**: Added `AGENTS.md` as the generic, tool-agnostic ruleset (copied from `kni927/repo-template`); `CLAUDE.md` now imports it via `@AGENTS.md` and keeps only FrameSheet-specific guidance (build command, ffmpeg invocation conventions). Renamed the docs previously moved under `docs/` in Phase 2 from lowercase-hyphen to the template's uppercase-underscore convention (`docs/DEV_LOG.md`, `docs/KNOWN_ISSUES.md`, `docs/DECISIONS.md`, `docs/ARCHITECTURE.md`, `docs/PROJECT.md`, `docs/ANTIGRAVITY.md`) via `git mv`, preserving history. Added `docs/task-workflow.md` (task completion/archiving procedure) and adopted its `docs/tasks/YYYY-MM-DD-NN-description.md` archive naming going forward; the existing `docs/tasks/2026-07-phase-*.md` archives predate this convention and were left as historical records. Archived the completed Phase 4 task to `docs/tasks/2026-07-07-01-duration-fallback.md`. Updated remaining cross-references (`docs/KNOWN_ISSUES.md`) to the renamed paths. No application code changed.

---

## [Unreleased] — Phase 4 - 2026-07-07

### Added
- **Duration Fallback via Packet Scan** (`estimateDuration`): When ffprobe's format/stream duration is missing, `N/A`, or 0 (e.g. a WebM written to a non-seekable output, which also lacks cues), the app now estimates duration from packet timestamps before generating — attempt 1 seeks to an unreachably late timestamp and reads the trailing packets' `pts_time` (instant on indexed containers; a demux-only linear scan on cues-less WebM); attempt 2 falls back to a full `-show_entries packet=pts_time` scan taking the max. The canvas shows an "Estimating duration…" state with a Cancel button (also wired to the sidebar Cancel), and if estimation still fails the app surfaces a clear error instead of silently producing a sheet of near-identical frames from the first 0.1 s.
  - Verified: normal .mp4 and a 2h15m VP9 .webm with duration metadata generate immediately (no regression); a synthesized cues-less/duration-less WebM now produces a correct evenly-spaced sheet (estimated 29.967 s) instead of 16 copies of frame 0.

### Repo
- Archived Phase 2/3 task lists to `docs/tasks/`.

---

## [Unreleased] — Phase 3 - 2026-07-07

### Removed
- **Fast Mode (keyframes only)**: Deleted the fast-mode extraction path (`-skip_frame nokey` single pass), its Layout-tab toggle, the `Fast mode: X of Y keyframes` indicator, and the related state (`fastModeKeyframesOnly`, `fastModeThumbnailSummary`, `GenerationParams.fastMode`/`effectiveDur`, the renderer's keyframe reconciliation, and the now-unused `runCommandStreaming`/`activeProcess` plumbing). The per-frame input-seeking engine (5-way parallel) is now the only generation path, and Custom Timestamps are always available.
  - **Rationale**: (1) Since Phase 2, the standard path extracts a 4×4 grid from a 60-min H.264 source in ~1 s, so a lossy keyframe-only preview no longer buys anything. (2) Fast mode hung on WebM sources lacking cues: `-skip_frame nokey` with an input seek forced a linear scan through the un-indexed container, appearing as a permanent hang in the UI.

---

## [Unreleased] — Phase 2 - 2026-07-07

### Changed
- **Normal Mode: Parallel Per-Frame Input Seeking**: Replaced the Normal Mode single-pass `fps=1/interval` filter (which sequentially decoded every frame in the sampled range) with one input-seeking invocation per frame (`ffmpeg -ss <t> -i <file> -frames:v 1`, frame-accurate in modern ffmpeg), run 5-concurrent via `runParallelFrameExtraction()`. Custom Timestamps use the same path (previously a full-decode `select` filter with no seeking at all). Hardware decoding (`-hwaccel videotoolbox`) was intentionally dropped for these single-frame invocations: decoding one GOP in software is cheap and decoder init overhead would dominate. Fast Mode is unchanged (single-pass `-skip_frame nokey`).
  - **Benchmark** (60-min 1280x720 30fps H.264 synthetic source, 4×4 grid, width 1200, 5%/95% range, Apple Silicon):
    - Before (single-pass `fps=1/interval` + videotoolbox): **220 s** for 16 frames
    - After (per-frame input seek × 5 parallel, software decode): **1 s** for 16 frames (~220×)
- **Cancel Support for Parallel Extraction**: `cancelGeneration()` now terminates all in-flight per-frame ffmpeg processes and stops the dispatch loop from launching new ones.

### Fixed
- **App Icon**: `docs/AppIcon.png` was JPEG data with a `.png` extension. Converted to a real PNG and moved to `assets/AppIcon.png`; `build.sh` now generates the iconset/icns from it.

### Repo
- Docs reorganized under `docs/` (lowercase names); completed task lists are archived under `docs/tasks/`.

---

## [2.0.0] - 2026-06-11

### Added
- **ffmpeg Single-Pass Engine (v2)**: Removed `vcsi` and all Python dependencies. Contact sheets are now generated via a single `ffmpeg` pass (`-ss`/`-to` + `fps=1/interval` filter for sequential decoding) and composited natively in Swift using CoreGraphics/AppKit (`renderContactSheet()`, `formatTimestamp()`, `parseTimestamps()`). Dependency checks now require only `ffmpeg`/`ffprobe`, and the missing-dependency overlay was updated accordingly.
- **Debounced Grid Stepper Updates**: Rapid clicks on the Grid Dimensions (`+`/`-`) steppers are now coalesced into a single regeneration via a 300ms `DispatchWorkItem` debounce in `autoGenerateIfNeeded()`. If a generation is already in-flight when the timer fires, it is rescheduled so the latest settings are rendered once the current run completes.
- **Fast Mode (keyframes only)**: New "Fast mode: keyframes only" toggle in the Layout tab. Uses `-hwaccel videotoolbox -skip_frame nokey -vsync vfr` to extract only the video's keyframes, producing near-instant previews even for 4K HEVC. **Enabled by default** so the initial preview after loading a video is fast rather than triggering a full Normal Mode pass. The grid's row count automatically shrinks to fit the actual number of extracted keyframes when fewer than `rows × columns` are available, and timestamps are approximated via interpolation across the sampled range. "Customize Timestamps" is disabled while Fast Mode is active.
- **Fast Mode Keyframe Count Indicator**: When Fast Mode is active, the toolbar (next to "Show in Finder") displays `Fast mode: X of Y keyframes`, where `X` is the number of keyframes actually used in the contact sheet and `Y` is the total number of keyframes extracted. Hidden in Normal Mode and reset at the start of each generation.

### Changed
- **VideoToolbox Hardware Decoding & JPEG Temporary Thumbnails**: Both Fast Mode and Normal Mode ffmpeg invocations now use `-hwaccel videotoolbox` and write temporary thumbnails as JPEG (`-q:v 3`, previously PNG) to reduce I/O overhead.

---

## [0.2.1] - 2026-06-08

### Added
- **Dakuten Rendering Fix**: Applied an internal patch to the dependency `vcsi.py` to normalize rendered text metadata into NFC format using `unicodedata.normalize('NFC', ...)`. This fixes diacritic separation (e.g. 「が」 rendered as 「か」 + 「゛」) on macOS when video file names contain Japanese characters.
- **Linked Image Dimension Sliders**: Replaced static height preview with dual-linked `Image Width` and `Image Height` sliders. Changing one slider automatically calculates and updates the other based on the video's aspect ratio.
- **Smart Toggle Generate Button**: Unified the Generate and Cancel buttons into a single button. The label changes to "Generate" or "Cancel" (in warning red) depending on execution state, resolving label truncating.
- **Custom Tab Buttons (22pt Icons)**: Bypassed macOS native segmented picker icon restrictions by implementing a custom button-based tab selector. Enlarged the sidebar icons from `13pt` to `22pt` for enhanced visibility and touch presence.
- **Custom Movie Info Header**: Added `Customize Header Text` options in Style tab. It supports custom templates using Jinja2 variables (e.g. `{{filename}}`, `{{size}}`, `{{duration}}`) that dynamically resolve and generate metadata layout via `vcsi`. It also updates image height prediction dynamically based on custom template line breaks.
- **Relocated Custom Timestamps**: Moved the manual custom timestamps editor from the Frames tab to the Style tab, nesting it directly under the "Show Timestamp overlays" option as "Customize Timestamps" to group all diacritic/text layouts together.

### Changed
- **Sleeker Layout Fitting**: Adjusted the auto-zoom algorithm (`fitToScreen`) in `main.swift` by taking the `Image` view's `padding(20)` (adds 40px width & height) and an extra safety margin of 20px into account. This eliminates the slight vertical scrollbar when scaling to fit the screen.
- **Unified Zoom Control Sizing**: Enlarged `minus`/`plus` button icons and the zoom percent label inside `TopBarView` to visually align with `100%` and `Fit` buttons.

---

## [0.2.0] - 2026-06-08

### Added
- **App Renaming**: Rebranded the app from "MoviePrint SwiftUI Wrapper" to **FrameSheet**.
- **NSFontPanel Integration**: Added a macOS native font selection dialog using `FontPanelBridge`. When the user selects a font, the app dynamically resolves its PostScript name (e.g. `HiraginoSans-W3`) to its raw file path (e.g. `.ttc` or `.ttf`) using `CTFontCopyAttribute` and passes it to the `vcsi` engine.
- **Icon-Only Segmented Tabs**: Replaced the custom text tab buttons with a sleek, native icon-only Segmented Picker (`Layout`, `Style`, `Frames`) with descriptive tooltips for a cleaner sidebar design.
- **App Metadata & Copyright**: Injected `NSHumanReadableCopyright` into `Info.plist` ("Copyright © 2026 kni. All rights reserved.") and created project `LICENSE` (MIT) and `README.md` files.

### Changed
- **Sleeker Sidebar**: Thinned the configuration sidebar from 260px to 180px to maximize the preview canvas area.
- **Custom Steppers**: Replaced the grid presets and slider controls for Columns and Rows with compact `-` and `+` steppers.
- **Color Presets**: Replaced the native color picker with circular color preset buttons for faster background and text color choices.
- **Zoom Header Integration**: Removed the floating ZStack zoom panel on the bottom-right and integrated unified zoom controls (`-`, `+`, `100%`, `Fit`) into the top bar header.
- **Default Font**: Changed the default contact sheet rendering font to **Hiragino Sans W3** to resolve diacritic issues and character corruption.
- **Real-time Previews**: Configured automatic generation triggers to redraw the contact sheet on grid, color, style, or font updates.

### Fixed
- **Japanese Path & Normalization Bug**: Solved an issue where Hiragino Sans would not load due to Unicode NFD/NFC path mismatches in `FileManager.default.fileExists`. The app now normalizes path strings to check both decomposed and precomposed forms.
- **NFC Path Normalization for Command Invocation**: Standardized all CLI argument paths (vcsi, video file, font, and output) to precomposed Unicode (NFC) form to resolve native NFD path bugs on macOS.
- **Font Fallback Picker Bug**: Corrected a layout selection bug in `StyleTab` where Monaco remained active instead of Hiragino Sans due to a mismatch between `AppState` properties and `Picker` tag bindings.
- **Fit Screen Scale Calculation**: Fixed a bug where Retina/High-DPI displays caused `NSImage.size` to return points instead of pixels, throwing off aspect ratios. We now extract raw pixel dimensions using `representations.first` (`NSImage.aspectRatio`) to compute accurate fit dimensions.
- **Scrollbar Duplication & Vertical Offsets**: Fixed a layout bug where the vertical scrollbar triggered an unnecessary horizontal scrollbar. Increased the width padding to 55px and dynamically calculated vertical UI card offsets to eliminate excessive padding.
- **Segmented Picker Icon Size**: Increased Segmented Picker tab icons to 13pt to improve usability.
- **Cached Process Overlay**: Added a pre-build `killall` command in `build.sh` to ensure macOS terminates running instances and launches the newly compiled binary.
