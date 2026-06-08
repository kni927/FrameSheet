# Design Decisions - FrameSheet

This document outlines key technical trade-offs and structural architectural choices made during the development of FrameSheet.

## Summary of Decisions

### 1. FFmpeg is not bundled

#### Context
`vcsi` depends on `ffmpeg` and `ffprobe` to scan video frames and extract thumbnails.

#### Decision
We explicitly chose **not** to bundle FFmpeg binaries inside the `FrameSheet.app` package. Instead, the application relies on the system PATH to discover `ffmpeg`/`ffprobe` or searches common installation prefixes (e.g., Homebrew, Miniforge).

#### Rationale
- **Distribution Size**: Bundling FFmpeg binaries would increase the app package size by ~80-100MB, whereas the core app is less than 15MB.
- **Licensing Considerations**: FFmpeg has complex GPL/LGPL configurations. Requiring external installation mitigates license redistribution liabilities.
- **Ease of Installation**: Target power users typically already have Homebrew (`brew install ffmpeg`) or have standard media tools installed on their Macs.

---

### 2. vcsi is bundled

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
