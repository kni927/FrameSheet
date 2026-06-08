# Project Specifications - FrameSheet

## Overview
FrameSheet is a macOS native wrapper for `vcsi` designed to serve as a premium alternative to MoviePrint. Its core purpose is to generate highly customizable video contact sheets (MoviePrints) by invoking `vcsi` internally.

## Tech Stack
- **GUI Frontend**: Swift / SwiftUI (Targeting macOS 11.0+)
- **Processing Engine**: Python 3.9+ & `vcsi`
- **Media Parser**: FFmpeg / FFprobe (System dependency)

## Goals
- **Apple Silicon Native**: Deliver a high-performance experience optimized for Apple Silicon (M1/M2/M3) and modern macOS.
- **Drag & Drop Integration**: Allow users to drag video files directly into the canvas for immediate generation.
- **Native macOS Workflows**: Support system open panels (`Menu > File > Open...`) and native save sheets.
- **High-Quality Export**: Support exporting contact sheets in PNG and JPEG formats.
- **Portability**: Bundle all core Python and `vcsi` dependencies directly inside the App Bundle to eliminate Python setup for end-users.

## Non-Goals
- **Cross-Platform Compatibility**: No plans to support Windows or Linux; targeting macOS exclusively.
- **Video Editing**: The app focuses purely on contact sheet generation; video cutting, joining, or filter editing are out of scope.
- **iCloud Synchronization**: State is kept locally; no cloud sync for preferences or generated sheets.

## Constraints
- **Platform**: macOS only.
- **Architecture**: Apple Silicon first.
- **Framework**: SwiftUI preferred over AppKit.
- **Technology Stack**: No Electron or Tauri framework.
- **End-User Runtime**: No Python runtime requirement for end-users.

## Target Audience
- **Current Distribution Target**: Power users and content creators.
- **Technical Assumption**: Not intended for completely non-technical users (requires FFmpeg setup on system).

## Current Status (v0.2.1)
- **Core Features**: Completed (drag and drop, basic customization, layout constraints, custom header template, localized diacritics fixes, standalone vcsi bundling).
- **In Progress**: UI refinements, micro-interactions, and visual polishing.

## Important Notes
- **FFmpeg Handling**: FFmpeg and FFprobe binaries are **not bundled** within the application to avoid bloating the distribution size and respect licensing constraints. The app expects these tools to be installed on the user's system (e.g., via Homebrew) and will check their presence on startup. The app does not perform silent or automatic system-level installations of FFmpeg.
- **VCSI Bundling**: The core `vcsi` command-line engine is compiled into a standalone binary using PyInstaller and bundled directly inside `FrameSheet.app/Contents/Resources/bin/vcsi`. This ensures that users do not need to install Python, pip, or vcsi manually to run the app.
