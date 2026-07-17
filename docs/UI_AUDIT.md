# UI Audit: FrameSheet vs. MoviePrint

**Audit-only.** No UI or application code was changed to produce this
document. Source: `main.swift` (static read, 2208 lines, single file)
and five reference screenshots of MoviePrint in `docs/reference/`
(`01.png`–`05.png`), cross-checked against the `fakob/MoviePrint_v004`
README on GitHub for features not visible in the static screenshots
(shot detection, batch create, timeline view, embed data). No
MoviePrint code was read or ported.

## 1. FrameSheet current UI inventory

### View hierarchy

```
FrameSheetApp (@main)
├─ AppDelegate (NSApplicationDelegate — Finder/Dock open events)
└─ MainView
   ├─ TopBarView — app title, current filename, zoom controls (-, %, +, 100%, Fit), console toggle
   ├─ HSplitView
   │  ├─ SidebarView (180–220px)
   │  │  ├─ TabButton × 3 — custom icon-only segmented picker (Layout / Style / Frames)
   │  │  ├─ ScrollView → LayoutTab | StyleTab | FramesTab (one visible at a time)
   │  │  └─ bottom action area — Generate / Cancel button (state-dependent)
   │  └─ CanvasView (GeometryReader, min 500px)
   │     ├─ video info card + "Show in Finder" (when a video is loaded)
   │     ├─ preview area (ZStack): estimating-duration state | generating state |
   │     │  image preview (ScrollView, pan/zoom) | drag-and-drop empty state
   │     ├─ export action bar — Copy to Clipboard, Save Image As (when image ready)
   │     ├─ FFmpeg-missing overlay (blocking card)
   │     └─ drop-target highlight border
   └─ ConsoleView (collapsible, 180px, toggled from TopBarView)

LayoutTab   → Grid Dimensions (Columns/Rows steppers), Output Options
              (Image Width slider, derived Image Height slider, Grid Spacing slider)
StyleTab    → Font Settings (family picker + NSFontPanel custom-font browse),
              Colors (ColorPresetSelector × 2: background/text, 4 swatches each),
              Visual Elements (Show Header toggle → nested custom-header TextEditor;
              Show Timestamps toggle → nested position picker + custom-timestamps TextEditor)
FramesTab   → Auto Sampling Range (Start Delay slider, End Delay slider)

Helpers: ColorPresetSelector, DependencyRow, TabButton, MonoFontModifier
```

### User-facing settings/controls

| Control | Type | Range | Default | Location |
|---|---|---|---|---|
| Columns | stepper | 1–50 | 4 | LayoutTab |
| Rows | stepper | 1–50 | 4 | LayoutTab |
| Image Width | slider | 600–3200px (step 50) | 1200 | LayoutTab |
| Image Height | slider (derived, reverse-solves width) | dynamic, from `minHeight`/`maxHeight` | computed | LayoutTab, only when a video is loaded |
| Grid Spacing | slider | 0–50px (step 1) | 10 | LayoutTab |
| Font Family | picker | Hiragino Sans / Helvetica / Times / Custom | Hiragino Sans | StyleTab |
| Custom Font | NSFontPanel file browse | — | none | StyleTab, when Font = Custom |
| Background Color | 4-swatch preset picker | black / dark gray / light gray / white | black | StyleTab |
| Text Color | 4-swatch preset picker | white / gray / yellow / black | white | StyleTab |
| Show Movie Info Header | toggle | — | on | StyleTab |
| Customize Header Text | toggle + `{{placeholder}}` TextEditor | — | off | StyleTab, nested |
| Show Timestamp overlays | toggle | — | on | StyleTab |
| Timestamp Position | picker | 4 corners | bottom-right | StyleTab, nested |
| Customize Timestamps | toggle + free-text TextEditor | — | off | StyleTab, nested |
| Start Delay | slider | 0–30% (step 1) | 5% | FramesTab |
| End Delay | slider | 0–30% (step 1) | 5% | FramesTab |
| Zoom | buttons (−/+/100%/Fit) | 0.1×–3.0× | fit-to-screen | TopBarView (transient, not a generation setting) |
| Show Console | toggle button | — | off | TopBarView |

### State management and ffmpeg invocation

A single `ObservableObject` (`AppState`) holds every piece of state —
media, layout, style, font, range, dependency status, running states,
and UI helpers (`activeTab`, `showConsole`, `zoomScale`,
`containerWidth/Height`) — as `@Published` properties. Views hold
essentially no local `@State` (`CanvasView.isTargeted` for drag-hover
is the only exception); everything else flows through
`@EnvironmentObject`. There is no separate settings-model /
session-state split, and no view-model layer between UI and process
execution: `AppState` is simultaneously the SwiftUI observable object,
the ffmpeg process orchestrator, and the CoreGraphics compositor
(`renderContactSheet`).

Every settings control calls `state.autoGenerateIfNeeded()` directly
from its `Binding`'s `set:` closure (e.g. every toggle/picker in
`StyleTab`) rather than `AppState` reacting to its own property
changes via `didSet`/Combine — the View layer decides when to
regenerate. A 300ms debounce (`generateDebounceWorkItem`) coalesces
rapid changes (e.g. stepper clicks) into one regeneration, re-arming
itself if a generation is already in flight. `generateContactSheet()`
extracts frames via `runParallelFrameExtraction()` (5-way concurrent
per-frame `ffmpeg -ss -i -frames:v 1` input seeks), then composites
them off-main in `renderContactSheet()` using CoreGraphics/AppKit and
publishes the result as a single flattened `NSImage`.

## 2. MoviePrint UI inventory

*(from `docs/reference/01–05.png` and the `fakob/MoviePrint_v004`
README; MoviePrint is Electron/React and no longer under active
development per its README)*

### Overall layout

Three-pane layout: a left movie/print list panel (~460px), a center
canvas (contact-sheet preview, with a dedicated toolbar row above it),
and a right settings sidebar (~430px, single continuously-scrolling
column — not tabbed). A persistent app-level top bar holds "Add
Movies", an overflow menu, "Check for updates", and "Contact us". A
"Save MoviePrint" button with a dropdown (for export variants) is
pinned to the bottom-right corner, independent of sidebar scroll
position.

The canvas toolbar (above the preview) holds roughly a dozen icon
buttons: add row/column, duplicate, pattern, a movie/camera view
toggle, sort, zoom, visibility, grid, frame-numbering, and fullscreen
— a distinct control surface FrameSheet has no equivalent for (its
TopBarView only holds zoom and console toggle).

### Settings taxonomy

Observed across the sidebar's full scroll range:

- **Grid**: Columns slider (1–20) / Rows slider (1–20) with a live
  "N COLUMNS × N ROWS = N COUNT" readout; a "Change thumb count"
  checkbox gates an explicit **Apply** button — grid-count changes are
  *not* applied live by default, unlike every other FrameSheet control.
- **Preview**: "Show paper preview" checkbox.
- **Layout**: a paper-size preset dropdown (e.g. "A0–A5 (Landscape)")
  — MoviePrint targets print output sizes; FrameSheet has no
  equivalent concept.
- **Margin**: slider (0–20).
- **Options**: Show header / Show file path / Show file details / Show
  timeline / Rounded corners / Show hidden thumbs (checkboxes).
- **Info display mode**: radio group — Show frames / Show timecode /
  Hide info (mutually exclusive).
- **Timecode styling**: font color swatch, background color swatch,
  position dropdown, size slider (1–100), margin slider (0–50) — the
  timecode label has its own background chip and independently
  configurable size.
- **Output**: output path (Change… / "Same as movie file" checkbox),
  output-size dropdown (explicit pixel presets, e.g. "4096px
  (×3243px)"), output-format dropdown (PNG, etc.), background color
  with an alpha/transparency checkerboard swatch.
- **Save options**: Overwrite existing / Include individual thumbs /
  Embed frameNumbers (PNG) / Embed filePath (PNG) / Open File Explorer
  after saving.
- **Naming schemes**: three separate filename templates (MoviePrint
  file, single-thumb file, individual-thumbs-when-included) built from
  attribute chips (`[MN]` Movie name, `[ME]` Movie extension, `[MPN]`
  MoviePrint name, `[FN]` Frame number).
- **Experimental**: "Show detection chart" button, "Automatic detection
  of In and Outpoint" checkbox, "Show input field instead of slider"
  (Expert) checkbox, shot-detection-method dropdown ("Mean average"),
  max-cached-frame-size dropdown, "Update frame cache" button.

### Interaction model

- **Movie list**: each entry shows a thumbnail, filename (non-ASCII
  titles render fine), source folder, frame-accurate duration
  (`H:MM:SS:FF`), resolution, and file size, plus a nested
  "MoviePrint-N · interval based" row — implying multiple named
  MoviePrint configs per movie, and that the sampling method
  ("interval based" vs. shot-detection) is per-print, not global.
  Multiple movies queue for **batch creation** (README).
- **Per-thumbnail actions**: hovering a cell reveals EXPAND / HIDE /
  SAVE buttons plus IN/OUT markers with a resize handle for per-thumbnail
  range editing. "Show hidden thumbs" confirms hidden cells persist
  (excluded, not deleted).
- **Drag & drop**: reorders/inserts individual thumbnails within the
  grid, in addition to dropping a video file onto the app (which
  FrameSheet also supports).
- **In/out points**: both per-movie (global trim) and per-thumbnail
  (individual frame re-pick via scrub) — FrameSheet only has global
  Start/End Delay percentages.
- **Shot detection**: an alternative to fixed-interval sampling that
  scans for cuts to place thumbnails at shot boundaries (README:
  "SHOT DETECTION").
- **Timeline view**: an alternate render mode where thumbnail width is
  proportional to shot duration, instead of a uniform grid (README).
- **Embed MoviePrint data**: exported PNGs can embed frame
  numbers/paths so the print can be re-edited later (README).
- **Appearance**: MoviePrint's own chrome is a fixed dark theme (like
  FrameSheet's forced `.preferredColorScheme(.dark)`); contact-sheet
  background/text color is separately configurable per-output, with
  alpha support FrameSheet's opaque-only presets lack.

## 3. Gap analysis

| Area | MoviePrint | FrameSheet current | Gap | Effort | Notes |
|---|---|---|---|---|---|
| Layout structure | 3-pane (movie list + canvas + settings) with a canvas toolbar row and a pinned save/export bar | 2-pane (180–220px sidebar + canvas), single video, no canvas toolbar, no timeline scrubber | Missing: movie-list pane, canvas toolbar, timeline scrubber, pinned export bar | L | The movie-list pane implies a multi-video data model (`selectedVideo: VideoFileInfo?` → an array), not just a layout addition — the largest structural gap. |
| Settings panel | ~25 controls across Grid/Preview/Layout/Margin/Options/Info-mode/Timecode-style/Output/Naming/Experimental, Apply-gated grid changes, paper-size presets | ~14 controls across 3 tabs, everything auto-regenerates | Missing: output-size/format/path/naming-scheme controls, save-options (overwrite/individual-thumbs/embed-metadata), rounded corners, hidden-thumbs, Apply-gated grid changes, arbitrary color picker (only 4 presets each) | M | FrameSheet's Layout/Style/Frames tabs can absorb most of these as new controls; Output/Naming likely wants its own tab or section. |
| Preview grid | Per-thumbnail hover overlay (expand/hide/save, in/out drag), drag-to-reorder, frame-accurate per-cell timecode badge | Static grid, uniform cells from global math only, no interactivity | Missing entirely: any per-thumbnail interaction | L | Biggest behavioral gap. Thumbnails today are ephemeral temp JPEGs composited into one flattened `NSImage`, not addressable UI elements — needs per-cell SwiftUI views instead of a single CoreGraphics-rendered bitmap. |
| Header/metadata rendering | Dense single-line metadata (path\|fps\|res\|size\|codec) + horizontal timeline scrubber with tick marks; 3 output-filename naming templates | 2–4 line header block; `{{placeholder}}` template for on-image header text only (no filename templating) | Missing: timeline scrubber, output-filename templating, denser single-line metadata option | M | The `{{placeholder}}` engine already exists in `renderContactSheet`; extending it to filenames is straightforward. The scrubber is new render work. |
| Appearance/theming | Fixed dark chrome; alpha/transparent PNG background; rounded corners; per-field color pickers | Fixed dark chrome (`preferredColorScheme(.dark)`); opaque-only 4-preset colors; no rounded corners | Missing: transparent background output, rounded corners, arbitrary color picker | S | Additive: swap/augment `ColorPresetSelector` with a `ColorPicker`, add alpha support to the PNG export path, add a corner-radius parameter to the thumbnail draw loop. |
| Live preview behavior | Grid-dimension changes are Apply-gated; most other settings apply live | Every change (including grid steppers) regenerates via a 300ms debounce | Behavioral difference, not a strict gap | S | FrameSheet's already-fast per-frame-seek pipeline makes live-apply reasonable; revisit only if larger grids/multi-movie make auto-regen noticeably slower. |

## 4. Refactoring readiness assessment

**Which views need splitting or extraction?** `main.swift` currently
holds everything — models, `AppState` (ffmpeg orchestration +
CoreGraphics rendering + all app state), 15 `View` structs,
`AppDelegate`, the app entry point, `FontPanelBridge`, and extensions
— in one 2208-line file, with `// MARK:` sections already implying
natural seams:

- `Models.swift` (`VideoFileInfo`, `FFProbeResult`)
- `AppState` split by concern: dependency checking, video loading /
  duration estimation, generation / parallel extraction, rendering
  (`renderContactSheet`, `formatTimestamp`, `parseTimestamps`), and
  sizing math (`estimatedHeight`, `minHeight`/`maxHeight`,
  `calculateHeightForWidth`, `updateWidthFromHeight`, `fitToScreen`)
- `Views/` — `MainView`, `TopBarView`, `SidebarView`, `CanvasView`,
  `ConsoleView`
- `Views/Tabs/` — `LayoutTab`, `StyleTab`, `FramesTab`,
  `ColorPresetSelector`
- `Views/Components/` — `TabButton`, `DependencyRow`
- `AppDelegate.swift`, `FrameSheetApp.swift`, `FontPanelBridge.swift`
- `Extensions.swift` (`Color.toHex`, `NSImage.pixelSize`/`aspectRatio`,
  `View.monoFont`)

Adopting a MoviePrint-style layout specifically also raises a design
question, not just a file-organization one: MoviePrint's sidebar is
one long scrolling column with section dividers, not tabs. Growing
FrameSheet's settings to Output/Naming/Experimental sections means
either adding tabs or flattening `LayoutTab`/`StyleTab`/`FramesTab`
back into one scrollable column — a product decision to make before
implementation. A new movie-list panel is net-new; `CanvasView`'s
single-item video-info card is the closest existing piece but lives
inside the canvas, not a separate list.

**Is rendering logic separable from view code?** Largely yes already.
`renderContactSheet` is a private `AppState` method invoked off-main,
takes a `GenerationParams` value type, and returns `NSImage?` — it has
no dependency on any `View` type, so extracting it into a standalone
`ContactSheetRenderer` type would be a low-risk, mechanical move. The
real separability problem is the *output artifact*: the grid is one
flattened bitmap (JPEG thumbnails composited via CoreGraphics into a
single `NSImage`, displayed as one SwiftUI `Image`). MoviePrint's
per-thumbnail hover/drag/save interactions require the grid to be a
collection of addressable, independently hit-testable views (e.g. a
`LazyVGrid` over a `[Thumbnail]` array), with flattening to one image
deferred to export time. This is the one genuinely new architectural
piece, not a mechanical refactor of what exists.

**State management changes required for live preview?** The current
single-`AppState`, everything-`@Published`, View-triggers-generation
model works for "regenerate everything on any change" but doesn't
scale to per-thumbnail live preview (dragging one thumbnail's in/out
point shouldn't re-run all N ffmpeg extractions). Needed, additively:

- A `Thumbnail` model (id, timestamp/in-out range, cached image or
  path, hidden flag) as `@Published [Thumbnail]`, so a single cell's
  edit can re-run just that cell's extraction.
- `selectedVideo: VideoFileInfo?` → `videos: [VideoFileInfo]` +
  a selected-video id, for the multi-movie list panel — touches
  roughly a dozen call sites (`CanvasView`, `LayoutTab`,
  `generateContactSheet`, etc.); mechanical but not small.

### Concrete refactoring prerequisites, in order

1. Split `main.swift` into the file layout above — zero behavior
   change, mechanical extraction, verifiable by diffing build output.
2. Extract `renderContactSheet`/`formatTimestamp`/`parseTimestamps`
   into a standalone renderer type decoupled from `AppState`.
3. Introduce a `Thumbnail` model + `@Published [Thumbnail]` grid state,
   populated by `generateContactSheet` instead of writing directly to
   a flattened `previewImage`.
4. Build a `LazyVGrid`-based thumbnail view bound to that array
   (replacing the single `Image(nsImage:)` in `CanvasView`), with
   per-cell hover affordances — this is where MoviePrint-parity
   interaction work actually begins.
5. Only after (1)–(4): multi-movie list panel, Output/Naming/Save
   settings, shot-detection sampling, timeline scrubber — each is
   additive once the grid is addressable per-thumbnail.

## 5. Recommendation — phased plan

**Phase 1 — Structural refactor, no visible UI change.** Split
`main.swift` per the file layout above; extract the renderer;
introduce the `Thumbnail` model backing the existing flattened-image
display (rendering still flattens to one image for now — only the
underlying data becomes per-cell). Land safely, verified by
before/after screenshot diff and no behavior change.

**Phase 2 — Settings-panel parity, additive, still single-video.** Add
the settings gaps that don't require new interaction models: rounded
corners, a color picker alongside the presets, alpha/transparent
background export, output-size presets, output-format dropdown,
output-filename templating (reusing the existing `{{placeholder}}`
engine), overwrite/individual-thumbs save options. UI + render-parameter
additions only — closes most of the "Settings panel" and
"Header/metadata" gap-table rows at low risk.

**Phase 3 — Interactive grid + multi-movie (the deep work).** Build
the per-thumbnail `LazyVGrid` with hover overlay (expand/hide/save,
in/out drag), wired to per-cell regeneration through the Phase-1
`Thumbnail` model; add the movie-list left panel and multi-video
`AppState` changes; add the timeline scrubber. This is where
MoviePrint's "set in/out points," "insert and move thumbs," and
"batch create" land. Largest and riskiest phase — should be scoped
into its own TASK.md once Phases 1–2 are in.

**Explicitly not recommended to chase:** shot-detection sampling
(MoviePrint uses openCV for this; FrameSheet dropped its last
non-Swift dependency in v2.0.0 per `CLAUDE.md`, and openCV would
reopen that constraint — needs its own feasibility spike, not a
phase); embed-MoviePrint-data round-tripping (re-editable exports);
the proportional-width timeline view mode. None of these block
parity on the areas in the gap table above.
