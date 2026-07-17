# TASK: Phase 2 — Settings-Panel Parity (Additive, Single-Video)

## Context

Follow-up to `docs/UI_AUDIT.md` §5 Phase 2, building on the landed
Phase 1 refactor (`ContactSheetRenderer`, `Thumbnail` array,
single-scroll-column sidebar). Everything here is additive UI +
render-parameter work: **no new interaction model, no per-thumbnail
features (Phase 3a), no multi-movie work (pending)**. The app remains
a single-video contact sheet generator.

## New sidebar section order

Insert a new **Output** section after Auto Sampling Range:

Grid Dimensions → Output Options → Font → Colors → Visual Elements →
Auto Sampling Range → **Output**

(Existing "Output Options" — image width/height/spacing — keeps its
place; consider renaming it "Size & Spacing" to avoid confusion with
the new Output section. Renderer/param names may stay as-is.)

## Features

### 1. Rounded corners (Visual Elements)

- Corner Radius slider, 0–30px (step 1), default 0.
- Applied per-thumbnail in the renderer draw loop (clip path per cell).

### 2. Arbitrary colors + alpha (Colors)

- Add a native SwiftUI `ColorPicker` next to each `ColorPresetSelector`
  (presets stay as one-click shortcuts; picker allows any color).
- Background color picker supports opacity (`supportsOpacity: true`).
  Text color stays opaque.
- Preview: when background alpha < 1.0, render the preview over a
  checkerboard pattern so transparency is visible.

### 3. Output format (Output section)

- Format dropdown: PNG (default) / JPEG.
- JPEG quality slider (50–100, default 90), visible only when JPEG.
- Guard: JPEG cannot encode alpha — if format is JPEG and background
  alpha < 1.0, show an inline warning in the Output section and
  composite over opaque background on export. Do not silently drop
  alpha without the warning.

### 4. Output size presets (Output section)

- Preset dropdown that drives the existing Image Width parameter:
  1200 / 1600 / 2048 / 3200 px / Custom. Selecting a preset sets the
  width slider; moving the slider flips the dropdown to Custom.
  (Reuses existing width→height solving; no new render math.)

### 5. Output filename templating (Output section)

- Template text field, default: `{{filename}}_sheet`.
- Reuse the existing `{{placeholder}}` engine from the header renderer;
  supported tokens at minimum: `{{filename}}` (basename, no extension),
  `{{width}}`, `{{height}}`, `{{columns}}`, `{{rows}}`, `{{date}}`
  (YYYY-MM-DD). Extension is appended from the format setting.
- "Save Image As" pre-fills the save panel filename from the template.

### 6. Quick Save + overwrite (Output section + export bar)

- "Save to Movie Folder" button in the export action bar next to
  "Save Image As": saves directly to the source video's folder using
  the template, no dialog.
- "Overwrite existing" toggle in the Output section (default off).
  When off and the target exists, auto-suffix `_2`, `_3`, ….

### 7. Save individual frames (Output section)

- "Include individual frames" toggle (default off). When on, both save
  paths also write each thumbnail (from the Phase 1 `Thumbnail` array's
  cached frames) into a `<template>_frames/` subfolder, named
  `<template>_{{index}}` (zero-padded), same format setting.

## Persistence

Persist all new settings (and existing generation settings if not
already persisted) via `UserDefaults` so they survive relaunch.
Transient state (zoom, console) stays unpersisted.

## Verification

- `./build.sh` succeeds; debug install to `~/Applications`.
- Each new control demonstrably changes the output (corner radius
  visible, alpha PNG verified by inspecting pixel alpha, JPEG quality
  affects file size, presets set width, template renders tokens).
- JPEG+alpha guard: warning shows, export is opaque, no crash.
- Overwrite off → `_2` suffix confirmed; on → file replaced.
- Individual frames: count equals grid cell count, naming/format correct.
- Settings survive app relaunch.
- Existing Phase 1 behavior unchanged (spot-check with the byte-diff
  harness where settings are at defaults).

## Wrap-up

- `docs/DEV_LOG.md` entry; new decisions (Output section, templating
  tokens, JPEG-alpha policy) to `docs/DECISIONS.md`.
- Archive this task to `docs/tasks/` per `docs/task-workflow.md`.

## Constraints

- Single video only; no per-thumbnail interactivity; no movie-list
  panel; no canvas toolbar; no shot detection.
- Follow `AGENTS.md` / `CLAUDE.md`. Branch off current `main`.

## Implementation Result

**Status:**
- Completed

### Changes

- **New files**: `AppState+Persistence.swift` (UserDefaults
  round-trip for every generation/output setting, colors stored as
  sRGB [r,g,b,a]; transient zoom/console excluded),
  `AppState+Export.swift` (template resolution, PNG/JPEG encoding,
  JPEG-alpha opaque compositing, quick save, `_2`/`_3` suffixing,
  individual-frames export), `Views/Tabs/OutputSection.swift`,
  `Views/Components/CheckerboardBackground.swift`.
- **Modified**: `AppState.swift` (new @Published settings with
  `didSet` persistence, `backgroundAlpha`, `currentFramesDir`),
  `ContactSheetRenderer.swift` (`cornerRadius` param + per-cell
  rounded clip), `AppState+Generation.swift` (cornerRadius pass-
  through; frame temp dir retained after render — replaced on next
  generation — so individual-frame export can read the `Thumbnail`
  paths; old `saveImageAs` moved to Export), `LayoutTab.swift`
  ("Size & Spacing" rename + size-preset dropdown),
  `StyleTab.swift` (ColorPickers incl. bg opacity; Corner Radius
  slider), `SidebarView.swift` (Output section appended),
  `CanvasView.swift` (checkerboard under translucent previews;
  "Save to Movie Folder" button).
- All seven TASK features implemented; section order is Grid
  Dimensions → Size & Spacing → Font → Colors → Visual Elements →
  Auto Sampling Range → Output as specified.

### Verification

- Build: passed (`./build.sh`; only the two pre-existing `onChange`
  deprecation warnings). Installed to `~/Applications`.
- Automated verification: 24-check CLI harness compiled against the
  real repo sources — all pass. Covers: default-settings render
  byte-identical to the Phase 1 baseline (T1); corner-radius clip
  verified per-pixel with solid-white thumbnails (T2); PNG background
  alpha ≈ 0.5 at a background pixel (T3); JPEG q50 < q100 file size
  (T4); JPEG+alpha exports opaque, composited over the background
  color, not black (T5); template tokens, path-separator stripping,
  `{{height}}` = `estimatedHeight` (T6); suffix behavior `_2`/`_3`
  and overwrite-on bypass (T7); end-to-end quick save with 8/8
  zero-padded individual frames + second-save `_2` (T8); settings
  persistence round-trip incl. color alpha (T9).
- Manual verification (computer-use GUI): all new controls render in
  the correct order; Corner Radius 20px live-regenerated visibly
  rounded thumbnails; "Save to Movie Folder" wrote
  `test_video_sheet.png` then `test_video_sheet_2.png` next to the
  source; Corner Radius survived an app relaunch (also confirmed via
  `defaults read`). Test artifacts and test-written defaults were
  cleaned up afterward.
- Not verified: JPEG-alpha inline warning visibility in the GUI
  (logic is a one-line conditional; compositing behavior itself is
  covered by T5).

### Remaining Issues

- None

### Follow-up Suggestions

- Phase 3a (per-thumbnail interactivity) can now also surface the
  retained frame files directly.
- The Output section's live filename preview could additionally show
  the resolved quick-save destination folder.
