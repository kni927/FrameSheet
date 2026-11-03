# Project Specifications - FrameSheet

## Overview
FrameSheet is a macOS app that makes video contact sheets (MoviePrints). v3,
in development, rebuilds it as a reproduction of MoviePrint v0.2.23 for Apple
Silicon: a document editor with many movies, several sheets per movie
(interval, shot detection, faces), editable thumbs and scenes, and export as
PNG/JPG with embedded data, JSON and EDL. The target behavior is in
`docs/V3_SPEC.md`; the decisions behind it are 14 on in `docs/DECISIONS.md`.
v2 (a settings-to-one-image generator) stays at tag v2.3.1.

## Tech Stack
- **Platform**: macOS 27+, Apple Silicon (arm64) only, Xcode 27.
- **Language and build**: Swift 6 language mode, a Swift package at the
  repository root (`FrameSheetCore` library, `FrameSheet` app, tests);
  `build.sh` assembles and signs the `.app`.
- **UI**: SwiftUI, with AppKit where SwiftUI falls short (key handling, open
  panels).
- **Decode**: AVFoundation with VideoToolbox first; the system
  `ffmpeg`/`ffprobe` for files AVFoundation cannot decode (WebM, MKV, WMV3,
  HEVC tagged `hev1`).
- **Faces** (planned): Apple Vision face rectangles.

## Goals
- Reproduce MoviePrint 0.2.23's layout and interactions, natively on Apple
  Silicon, where MoviePrint itself no longer runs.
- Keep the editor logic (models, layout math, naming, shot detection,
  import/export) in a tested core library.
- Fast scans: one decode pass for shot detection and faces
  (`docs/v3-measurements.md`).

## Non-Goals
- Cross-platform support, Electron or Tauri.
- MoviePrint's look (Semantic UI, orange accent): v3 uses the kni Design
  System (Catppuccin Mocha), dark only.
- Guide layout (paper aspect ratios), same-person face grouping (face Lv2,
  maybe later), age and gender.
- Bundling ffmpeg or linking libav*.

## Constraints
- No Python dependency; `vcsi` stays removed.
- MoviePrint code may be ported with its MIT notice under `docs/licenses/`;
  PyMoviePrint code (no license) is never copied.
- UI text in English.

## Target Audience
Power users and content creators who catalogue or review video; ffmpeg is
needed only for formats AVFoundation cannot decode.

## Current Status (v3 skeleton, 2026-11-02)
- Swift package with the core model (library, sheets, thumbs, scenes,
  settings), interval frame lists and grid geometry ported from MoviePrint,
  JSON persistence, the decode layer with ffmpeg routing and discovery, and
  a minimal app: movie list, default interval sheet (16 thumbs, 4 columns),
  ffmpeg row in the settings sidebar.
- Next: the features in the order of `docs/V3_SPEC.md` (see
  `docs/STATUS.md`).
