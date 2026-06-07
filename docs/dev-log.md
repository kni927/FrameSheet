# Development Log - FrameSheet

This log details the features, design changes, and bug fixes implemented during the development of FrameSheet.

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
