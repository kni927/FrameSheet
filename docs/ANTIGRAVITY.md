# Antigravity Context (antigravity.md)

This file contains crucial instructions, project overview, and development logs for the Antigravity AI agent. Do not delete or rename this file.

## Project Overview

- **Name**: FrameSheet (previously MoviePrint wrapper)
- **Role**: A premium macOS native SwiftUI wrapper for `vcsi` (Video Contact Sheet Creator).
- **Directory**: `/Users/kni/.gemini/antigravity/scratch/MoviePrintWrapper`
- **Output Bundle**: `/Users/kni/.gemini/antigravity/scratch/MoviePrintWrapper/build/FrameSheet.app`

## Technical Stack & Constraints

- **Language**: Swift 5.0+ (packaged as a macOS native App via AppKit/SwiftUI)
- **UI Language**: English (as per user instruction)
- **AI Output Language**: Japanese (logs, thoughts, plans, and explanations to the user must be in Japanese)
- **Compilation**: Single-file swiftc compiler setup via `build.sh`.
- **Dependencies**:
  - `vcsi` (typically installed at `/Users/kni/miniforge3/bin/vcsi` or on the PATH)
  - `ffmpeg` and `ffprobe` (checked at launch)

---

## Code Structure & Key Implementations

### `main.swift`
- **AppState**: Holds the application state, grid configuration, custom style options, and active process reference.
- **FontPanelBridge**: Bridges macOS standard `NSFontPanel` with SwiftUI to let users select any installed system font, resolving the selected font to its physical `.ttf`/`.ttc` file path.
- **NSImage Extension**: Defines `pixelSize` and `aspectRatio` calculated directly from `representations.first` to avoid Retina/DPI scaling issues during preview rendering.
- **Segmented Picker Icon-Only Style**: Renders clean SF Symbols in the Segmented Picker tabs with tooltips, bypassing macOS SwiftUI segmented cell limitations.

### `build.sh`
- Compilation script that cleans the build folder, resizes the `AppIcon.png` into standard icns resolutions using `sips`, compiles `main.swift`, injects custom `Info.plist` (with NSHumanReadableCopyright metadata and version `0.2.1`), and launches the app.
- Automatically terminates (`killall`) any running instances of `FrameSheet` before building to prevent old cached processes from overriding the launch.

---

## Dev Logs & Known Behaviors

- **Monaco Tofu Text Issue (Resolved)**: Monaco was initially chosen as default but caused tofu (□) characters on Japanese titles/paths. Fixed by switching default font to `Hiragino Sans W3` (`/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc`).
- **NFD/NFC Path Normalization (Resolved)**: Standardized CLI command paths (vcsi, video file, output, and font) to precomposed Unicode (NFC) using `precomposedStringWithCanonicalMapping` to prevent file-not-found errors caused by native macOS NFD filesystem encoding.
- **Fit Screen Layout & Dynamic Padding (Resolved)**: Extracted raw pixel dimensions via `representations.first` (`aspectRatio`) to resolve scale calculation errors on Retina displays. Improved the calculation by dynamically calculating top/bottom UI offsets to eliminate excessive vertical whitespace. Added image view padding and a safety margin (60px width, 90px height total offset) to completely eliminate minor vertical scrollbars.
- **Dakuten / Diacritic Rendering Issue (Resolved in v0.2.1)**: Solved a bug where diacritics in Japanese filenames (NFD) were rendered separately (e.g., 「か」+「゛」) in Pillow. Patched the core dependency (`vcsi.py`) to normalize metadata text template outputs to NFC using Python's `unicodedata.normalize('NFC', ...)`.
- **Large Tab Icons (Resolved in v0.2.1)**: Replaced standard segmented picker with custom button components to bypass macOS segmented size restrictions, enlarging tab icons to 22pt with modern selection highlights.
- **Output Image Dimension Sliders (Resolved in v0.2.1)**: Replaced static height preview with dual-linked `Image Width` and `Image Height` sliders. Changing one slider automatically calculates and updates the other based on the video's aspect ratio.
- **Smart Toggle Generate Button (Resolved in v0.2.1)**: Unified the Generate and Cancel buttons into a single button. The label changes to "Generate" or "Cancel" (in warning red) depending on execution state, resolving button text truncation.
- **Custom Movie Info Header (Resolved in v0.2.1)**: Added `Customize Header Text` options in Style tab. It supports custom templates using Jinja2 variables (e.g. `{{filename}}`, `{{size}}`, `{{duration}}`) that dynamically resolve and generate metadata layout via `vcsi`. It also updates image height prediction dynamically based on custom template line breaks.
- **Unified Zoom Control Sizing (Resolved in v0.2.1)**: Enlarged `minus`/`plus` button icons and the zoom percent label inside `TopBarView` to visually align with `100%` and `Fit` buttons.
- **Relocated Custom Timestamps (Resolved in v0.2.1)**: Moved custom timestamps configurations from FramesTab to StyleTab, nesting them under "Show Timestamp overlays" as "Customize Timestamps" to consolidate all visual overlays.
- **Version Release (v0.2.1)**: Bumped version metadata to `0.2.1` (build 3) and committed modifications.
