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
- Compilation script that cleans the build folder, resizes the `AppIcon.png` into standard icns resolutions using `sips`, compiles `main.swift`, injects custom `Info.plist` (with NSHumanReadableCopyright metadata and version `0.2.0`), and launches the app.
- Automatically terminates (`killall`) any running instances of `FrameSheet` before building to prevent old cached processes from overriding the launch.

---

## Dev Logs & Known Behaviors

- **Monaco Tofu Text Issue (Resolved)**: Monaco was initially chosen as default but caused tofu (□) characters on Japanese titles/paths. Fixed by switching default font to `Hiragino Sans W3` (`/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc`).
- **NFD/NFC Path Normalization (Resolved)**: Standardized CLI command paths (vcsi, video file, output, and font) to precomposed Unicode (NFC) using `precomposedStringWithCanonicalMapping` to prevent file-not-found errors caused by native macOS NFD filesystem encoding.
- **Fit Screen Layout & Dynamic Padding (Resolved)**: Extracted raw pixel dimensions via `representations.first` (`aspectRatio`) to resolve scale calculation errors on Retina displays. Improved the calculation by dynamically calculating top/bottom UI offsets to eliminate excessive vertical whitespace.
- **Version Release (v0.2.0)**: Initialized Git version control inside the project directory and bumped version metadata to `0.2.0` (build 2).
