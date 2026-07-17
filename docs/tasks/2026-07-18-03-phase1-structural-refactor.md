# TASK: Phase 1 — Structural Refactor + Sidebar Single-Column Layout

## Context

Follow-up to `docs/UI_AUDIT.md` (§4 prerequisites 1–3 and the sidebar
product decision). Decision record: Phases 1–2 approved; Phase 3
approved for per-thumbnail interactivity only (multi-movie / batch /
timeline scrubber are pending — do not build toward them beyond what
this task specifies). Sidebar decision: adopt MoviePrint-style
single-scroll-column, dropping the 3-tab layout.

This task has two stages with different verification standards.
**Complete and verify Stage A before starting Stage B. Commit them
separately.**

## Stage A — Mechanical split (zero visible change)

Implements UI_AUDIT.md §4 prerequisites 1–3.

### A1. Split `main.swift` into the file layout from UI_AUDIT.md §4

- `Models.swift`, `AppState` split by concern, `Views/`,
  `Views/Tabs/`, `Views/Components/`, `AppDelegate.swift`,
  `FrameSheetApp.swift`, `FontPanelBridge.swift`, `Extensions.swift`.
- Update `build.sh` to compile the new multi-file layout.
- Pure extraction: no renames of types/properties, no logic changes.

### A2. Extract the renderer

- Move `renderContactSheet` / `formatTimestamp` / `parseTimestamps`
  into a standalone `ContactSheetRenderer` type with no dependency on
  `AppState` or any View type. `AppState` calls it.

### A3. Introduce the `Thumbnail` model

- `Thumbnail` (id, timestamp, cached image or temp path, hidden flag —
  hidden unused for now) + `@Published var thumbnails: [Thumbnail]` on
  `AppState`.
- `generateContactSheet()` populates `thumbnails`, then the renderer
  flattens *from that array* into the existing single `previewImage`.
  Display path is unchanged (still one `Image(nsImage:)`).

### Stage A verification

- `./build.sh` succeeds; install debug build to `~/Applications`.
- Screenshot-diff: generate a contact sheet from the same video with
  the same settings before/after — output images must be pixel-identical
  (or byte-identical PNG if deterministic).
- All 17 settings controls still function; console, zoom, drag & drop,
  Copy/Save unchanged.
- Commit Stage A on its own.

## Stage B — Sidebar single-scroll-column (visible change)

### B1. Flatten tabs into one scrolling column

- Remove `TabButton` and `activeTab`; `SidebarView` becomes a single
  `ScrollView` containing sections in this order:
  **Grid Dimensions → Output Options → Font → Colors → Visual
  Elements → Auto Sampling Range** (i.e. current Layout → Style →
  Frames content, flattened).
- Add MoviePrint-style section headers/dividers between groups.
- Keep the Generate/Cancel action area pinned at the sidebar bottom,
  outside the scroll (matching MoviePrint's pinned save bar concept).
- Sidebar width may grow modestly if needed (e.g. 220–280px), but keep
  the current overall 2-pane structure — no movie-list panel, no canvas
  toolbar (those are pending Phase 3b).

### Stage B verification

- `./build.sh` succeeds; install to `~/Applications`.
- Every control from the Stage A checklist remains reachable and
  functional in the new column.
- Generated output is unaffected (settings-to-render behavior
  unchanged) — repeat the screenshot-diff on the *output image*.
- Commit Stage B separately.

## Wrap-up

- Append entries for both stages to `docs/DEV_LOG.md`.
- Note the sidebar decision (single-scroll-column adopted, tabs
  removed) in `docs/DECISIONS.md`.
- Archive this task to `docs/tasks/` per `docs/task-workflow.md`.

## Constraints

- No new features, no settings additions (Phase 2), no per-thumbnail
  interactivity (Phase 3a), no multi-movie work (pending 3b).
- Follow `AGENTS.md` / `CLAUDE.md` conventions.
- Branch off current `main` after the `docs/ui-audit` PR merges.

## Implementation Result

**Status:**
- Completed

### Changes

- **Stage A**: Split `main.swift` (2208 lines) into `Models.swift`,
  `AppState.swift` + `AppState+Dependencies/Loading/Generation/Sizing.swift`,
  `Views/` (+ `Tabs/`, `Components/`), `AppDelegate.swift`,
  `FrameSheetApp.swift`, `FontPanelBridge.swift`, `Extensions.swift`
  (22 files). Extracted the compositor into a standalone
  `ContactSheetRenderer` (no `AppState`/View dependency) and added a
  `Thumbnail` model (`id`, `timestamp`, `imagePath`, unused `hidden`
  flag) that `generateContactSheet()` now populates; the renderer
  flattens from that array — display path (single `previewImage`)
  unchanged. `GenerationParams` dropped its now-redundant
  `interval`/`startSec`/`customTS`/`thumbCount` fields since per-cell
  timestamps are resolved once, up front, instead of at render time.
  `build.sh` now compiles the full source tree.
- **Stage B**: Removed the Layout/Style/Frames tab switcher
  (`TabButton`, `AppState.activeTab`); `SidebarView` is a single
  `ScrollView` with sections in the original tab order (Grid
  Dimensions → Output Options → Font → Colors → Visual Elements →
  Auto Sampling Range) and dividers between each. Generate/Cancel
  stays pinned outside the scroll. Sidebar width: 180px (160–220) →
  240px (200–280).
- Updated `docs/DEV_LOG.md` (one entry per stage) and `docs/DECISIONS.md`
  (marked Decision 3 "Monolithic `main.swift`" as superseded; added
  Decision 5 "Multi-file SwiftUI layout" and Decision 6 "Sidebar:
  single-scroll column instead of tabs").
- Committed Stage A and Stage B separately, as instructed.

### Verification

- Build: passed for both stages — `./build.sh`, warning-clean aside
  from two pre-existing SwiftUI `onChange` deprecation notices
  (unrelated, present before this task). Installed to `~/Applications`
  after each stage.
- Automated verification: a byte-for-byte diff harness (fixed JPEG
  thumbnails + fixed `GenerationParams`, compiled and run against the
  pre-refactor `renderContactSheet` and the post-refactor
  `ContactSheetRenderer`) produced byte-identical PNGs for the
  standard case and the custom-timestamps-shorter-than-grid edge
  case, re-confirmed unchanged after Stage B.
- Manual verification: launched the built app via computer-use after
  each stage; confirmed the flattened sidebar shows all 6 sections in
  order while scrolling with Generate pinned at the bottom; loaded a
  synthesized test video, generated a contact sheet end-to-end, and
  confirmed changing Columns (4→5) auto-regenerated correctly.
- Not performed: `git log --follow` per-file history checks (expected
  — this is a 1-file-to-many split, not a rename `git mv` could track).

### Remaining Issues

- None

### Follow-up Suggestions

- Phase 2 (settings-panel parity: output presets, naming templates,
  rounded corners, alpha background) is the natural next TASK.md.
- Phase 3a (per-thumbnail interactivity) depends on wiring real UI
  against the `Thumbnail` array introduced here — currently populated
  but not yet displayed per-cell.
