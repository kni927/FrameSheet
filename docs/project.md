# Project Specifications - FrameSheet

## Overview
FrameSheet is a macOS native app designed to serve as a premium alternative to MoviePrint. Its core purpose is to generate highly customizable video contact sheets (MoviePrints) using a native ffmpeg single-pass extraction engine and a Swift/CoreGraphics compositor (v2.0.0; `vcsi`/Python have been removed entirely).

## Tech Stack
- **GUI Frontend**: Swift / SwiftUI (Targeting macOS 11.0+)
- **Processing Engine**: Native `ffmpeg` frame extraction (one input-seeking invocation per frame, `-ss <t> -i <file> -frames:v 1`, 5-way parallel) + Swift/CoreGraphics & AppKit compositing
- **Media Parser**: FFmpeg / FFprobe (System dependency)

## Goals
- **Apple Silicon Native**: Deliver a high-performance experience optimized for Apple Silicon (M1/M2/M3) and modern macOS.
- **Drag & Drop Integration**: Allow users to drag video files directly into the canvas for immediate generation.
- **Native macOS Workflows**: Support system open panels (`Menu > File > Open...`) and native save sheets.
- **High-Quality Export**: Support exporting contact sheets in PNG and JPEG formats.
- **Instant Previews**: Parallel per-frame input seeking keeps generation in the seconds range even for hour-long sources (Fast Mode was removed in Phase 3 once this was achieved).
- **Portability**: No bundled runtime dependencies; the app is a single lightweight Swift binary that only requires `ffmpeg`/`ffprobe` on the system.

## Non-Goals
- **Cross-Platform Compatibility**: No plans to support Windows or Linux; targeting macOS exclusively.
- **Video Editing**: The app focuses purely on contact sheet generation; video cutting, joining, or filter editing are out of scope.
- **iCloud Synchronization**: State is kept locally; no cloud sync for preferences or generated sheets.

## Constraints
- **Platform**: macOS only.
- **Architecture**: Apple Silicon first.
- **Framework**: SwiftUI preferred over AppKit.
- **Technology Stack**: No Electron or Tauri framework.
- **End-User Runtime**: No Python runtime requirement for end-users (no Python dependency exists at all as of v2.0.0).

## Target Audience
- **Current Distribution Target**: Power users and content creators.
- **Technical Assumption**: Not intended for completely non-technical users (requires FFmpeg setup on system).

## Current Status (v2.0.0)
- **Core Features**: Completed (drag and drop, basic customization, layout constraints, custom header template, localized diacritics fixes, native ffmpeg parallel per-frame extraction + CoreGraphics engine, debounced grid steppers; the keyframe-only Fast Mode was removed in Phase 3).
- **In Progress**: UI refinements, micro-interactions, and visual polishing.

## Important Notes
- **FFmpeg Handling**: FFmpeg and FFprobe binaries are **not bundled** within the application to avoid bloating the distribution size and respect licensing constraints. The app expects these tools to be installed on the user's system (e.g., via Homebrew) and will check their presence on startup. The app does not perform silent or automatic system-level installations of FFmpeg.
- **vcsi Removed**: As of v2.0.0, the `vcsi` binary and all Python dependencies have been removed entirely. Contact sheets are generated via a native `ffmpeg` extraction pass and composited in Swift using CoreGraphics/AppKit. There is no bundled binary inside `FrameSheet.app/Contents/Resources`.
