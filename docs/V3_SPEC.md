# FrameSheet v3 Specification

FrameSheet v3 reproduces MoviePrint v0.2.23 (fakob/MoviePrint_v004, MIT) as a
native Apple Silicon app. This document is the target behavior; decisions
behind it are in `docs/DECISIONS.md` (14–21). Values come from MoviePrint's
source (`app/utils/constants.js`, `app/store/localStorage.js`,
`app/utils/utils.js`, components) as read on 2026-11-01. Scan and cache
values come from the measurement spike (`docs/v3-measurements.md`,
2026-11-02); **(open)** items are for the owner to decide before the TASK that
builds them.

## 1. Scope

- **In v3.0.0:** everything below.
- **Not in v3:** guide layout (paper aspect ratios); age and gender; same-person
  face grouping (unique faces, occurrence, FIND, same-face filter) — grouping
  may come later as face Lv2.
- **Not reproduced:** MoviePrint's look (Semantic UI, orange accent), update
  check, feedback webview, Google Fonts, the Development menu.
- **Additions over MoviePrint** are not part of v3.0.0 unless listed here:
  ffmpeg discovery (§10), kni Design System look (§11).

## 2. Platform and stack

- macOS 27+, arm64 only, Xcode 27, Swift 6 language mode.
- Swift Package: `FrameSheetCore` (pure logic, unit-tested with `swift test`)
  and the app target; `build.sh` assembles, signs and versions the `.app`.
- SwiftUI; AppKit only where needed (key handling, possibly the timeline).
- Decode: AVFoundation (`AVAssetImageGenerator` for random access,
  `AVAssetReader` for sequential scans); system `ffmpeg`/`ffprobe` as the
  fallback for files AVFoundation cannot open (WebM, MKV, …).
- Faces: Apple Vision face rectangles, behind a `FaceAnalyzer` protocol.

## 3. Data model

- **Library:** ordered list of movie files. Per file: id, URL (with a
  security-scoped bookmark), name, folder, duration, frame count, fps, width,
  height, size, fourCC, poster frame, transform (rotation, crop, aspect
  ratio), IN/OUT frame, scan state.
- **Sheets:** many per file, ordered. Per sheet: id, name, type (`interval` |
  `shot` | `faces`), view (`grid` | `timeline`), `columnCount`,
  `secondsPerRow`, `parentSheetId`, thumbs, scenes.
- **Thumb:** id, frame number, index, hidden, faces (per-frame face data).
- **Scene:** id (= thumb id), start frame, length, mean color, hidden.
- Names `Sheet-N` from a per-file counter (owner, 2026-11-03; MoviePrint's
  `MoviePrint-N` meant nothing to users); expanded sheets "Shot #n" or
  "Sequence a - b".
- **Settings:** global, persisted (§6).
- **Undo/redo:** 50 steps over library and sheet edits, not persisted.

## 4. Window layout

- **Header bar:** Add movies (key A; open panel); "more options": Import
  Sheet… (JSON, or PNG with embedded data), Clear movie list. PNG and JSON
  files are also imported when added by Add movies, drop or Open With (owner,
  T04).
- **Save:** a download button in the window toolbar (owner, 2026-11-03;
  MoviePrint's footer is not reproduced): Save sheet (key M); its menu:
  Open output location, Save All sheets. Undo and Redo buttons sit in the
  toolbar too (owner, T04).
- **Left sidebar — movie list** (key 1): per movie poster frame ("S" badge once
  shot-scanned), name, folder, duration (timecode), size, W×H. Movie menu:
  Edit rotation/cropping/aspect ratio, Open file location (Finder), Replace
  movie, Remove. Missing file → "Movie is missing" and Locate.
  Under each movie its sheets: icon (grid or barcode), name, type label. Sheet
  menu: Rename (inline), Switch grid/timeline view (timeline disabled for
  faces), Convert to interval, Duplicate, Export JSON, Export EDL (shot sheets),
  Delete.
- **Right sidebar — settings** (key 3), §6: the per-sheet and output
  sections, divided by lines and collapsible (owner, T04). App-wide settings (thumbnail cache, ffmpeg) are
  in a Settings window (⌘,) (owner, 2026-11-03).
- **Main area:** empty-state placeholder; grid view; timeline view. Drop
  overlay "ADD MOVIES TO LIST"; with Option held "CLEAR LIST AND ADD MOVIES".
  Accepts any file AVFoundation or ffmpeg can open as video.
- **Sheet toolbar** (in the window toolbar, next to the title; owner,
  2026-11-03): Back to parent; Add shot-detection sheet; Add interval
  sheet (presets 2×2 … 6×6); Add faces sheet (every 100th frame in IN–OUT /
  every 10th / these thumbs); Sort (Reverse, Frame number, Face count, Face
  size, Confidence; disabled for shot sheets); Filter (faces); Duplicate;
  Grid/timeline; Player view (key 2); Zoom out / Fit / Zoom in (0.25, 0.33,
  0.5, 0.75, 1, 2 … 8; default 1); Show hidden thumbs; Show header; cycle frame
  info (frames → timecode → none); Toggle face rectangles; Toggle images (mean
  colors only); Optimize grid layout (columns = ceil(√n)).
- Progress and errors as toasts; long scans show Cancel in the toast.
- **Menus:** standard App, File, Edit (Undo/Redo), View (full screen, fit,
  zoom), Window, Help; Settings… (⌘,) in the App menu.

## 5. Sheets

- **Interval:** N frames evenly between IN and OUT. IN/OUT default to the first
  and last frame unless automatic IN/OUT detection is on. Default 16 thumbs,
  4 columns; created when a movie is first selected.
- **Shot:** built from the stored scan; one thumb per scene at
  `start + floor(length / 2)`; opens in timeline view; the threshold can change
  without rescanning.
- **Faces:** grid only; frames that contain faces; initial sort by face size,
  then optimized grid.
- **Timeline view** for interval sheets: artificial scenes split at the
  midpoints between visible thumbs.
- **Expand** (thumb or scene): child interval sheet of 16 thumbs inside that
  scene, with `parentSheetId` for Back to parent.
- Duplicate; Convert to interval (type change only); Delete.

### 5.1 Grid geometry

Thumb width = movieWidth × 0.25; margin = movieWidth × marginRatio × 0.25;
corner radius ratio 0.04; header height = movieHeight × 0.25 × (1 + (path +
details + timeline) / 3) × 0.25; the whole layout scales to the container ×
zoom. Hidden constants: thumbnailScale 0.25, borderRadiusRatio 0.04,
headerHeightRatio 0.25, thumbInfoRatio 0.075.

### 5.2 Print header

File name; optional folder path (shown as `~/…`); optional details
`TC  fps FPS  W × H  size  fourCC`, separated by spaces; optional mini
timeline with the IN/OUT range and thumb positions. No logo or app icon;
right-aligned by default, with a left-aligned option (owner, T04, replacing
the 2026-11-01 app-icon choice).

## 6. Settings panel

- **Stats line:** grid "C Columns × R Rows = count"; timeline "N Shots /
  ~M Minutes ≈ X cut/min".
- **Grid view** (owner, T03b): Columns 1–20 (default 4, per sheet) rearranges
  live, keeping the thumbs; Rows 1–20 sets a target (extra rows show as
  placeholders, fewer rows dim the thumbs that would go); **Replace**
  recaptures columns × rows thumbs evenly in one undo step, enabled when that
  differs from the current count. Default 16 thumbs.
- **Timeline view:** Minutes per row 10–1800 s (default 120 s, per sheet);
  Natural flow (shot sheets, wrap by width; default off); Change scene count →
  shot detection threshold 3–40 (default 6.0) and Add new MoviePrint.
- **Styling:** grid margin 0–20 (default 4); timeline only: scene width ratio
  0–100 (default 50; multiplier v / 55.5555 + 0.1 for v ≤ 50, else
  (v − 50) / 5.55555 + 1; print height = MoviePrint width, print width =
  height × multiplier) and min scene width 0–10 s (stored as frames, default
  10 frames). Show header (default off) with Show file path / file details /
  timeline (default on); Rounded corners (on); Show hidden thumbs.
- **Frame info:** Show frames (4-digit) / Show timecode / Hide (default);
  the timecode format is selectable (HH:MM:SS:FF and other formats, owner,
  T04). Font color, background color, presets from the Catppuccin
  palette plus any color and transparent. Position: TopLeft (default),
  TopCenter, TopRight, CenterCenter, BottomLeft, BottomCenter, BottomRight.
  Size 1–100 (10). Margin 0–50 (0).
- **Output:** folder (default Desktop; Change…; Same as movie file, off); size
  1024–16384 px in 1024 steps labelled "4096px (×Hpx)" plus "max" (default
  4096; in timeline view it is the height); format PNG (default) / JPG,
  quality 0–100 (80); background color (default transparent; alpha in PNG
  only). Save options: Overwrite (off); Include individual thumbs (off); Embed
  frame numbers (PNG, on); Embed file path (PNG, on); Open Finder after saving
  (off). Thumb format JPG (default) / PNG, quality 95.
- **Naming scheme** with live preview: sheet `[MN].[ME]-[SN]`; single
  thumb `[MN].[ME]-frame[FN]`; individual thumbs `[MN].[ME]-[FN]`. Tokens
  `[MN]` movie name, `[ME]` extension, `[SN]` sheet name (MoviePrint's
  `[MPN]` is accepted as an alias), `[FN]` frame number
  (6 digits), `[TC]` timecode `HH_MM_SS_FF`. Warn when a thumb template lacks
  `[FN]` and `[TC]`. Replace `/\?%*:|"<>` with `-`; when not overwriting,
  append " edit N".
- **Face detection:** confidence threshold 0–100 (70); size threshold 0–100
  (10, % of frame height); "takes effect on next scan".
- **Thumbnail cache** (Settings window; replaces MoviePrint's frame cache, whose per-frame
  images do not fit: 50 GB for a 2 h film at 240 px): memory limit for decoded
  display-size thumbnails, default 256 MB; Clear thumbnail cache.
- **Experimental:** shot detection method Mean (default) / Histogram; detection
  chart (key F); automatic IN/OUT detection (off); input fields instead of
  sliders.
- **ffmpeg** (Settings window): found path and version; Choose… to set a path (§10).

## 7. Thumb and scene interactions

- **Hover overlay** (hidden below 100 px thumb width, compact below 160 px;
  hovering a button dims the thumbs it affects): EXPAND; Hide/show (selects
  the next thumb); Save thumb (original resolution, transform applied); IN /
  OUT (interval sheets: set IN/OUT and recapture the same count between; with
  Option or other sheet types: hide all before/after); Insert before/after
  (interval: frame midway to the neighbour; shot sheets: Jump to cut).
- **Scrub** (drag the handle): overlay with the left neighbour, the live frame
  and the right neighbour, labelled CHANGE TO / ADD BEFORE / ADD AFTER. Mouse X
  maps linearly between the neighbours' frames. Shift: from the left neighbour
  to the current thumb, insert before. Option: from the current thumb to the
  right neighbour, insert after. Control (or the first/last thumb): extend to
  movie start/end. Release confirms; a top Cancel bar cancels. Shot sheets:
  limited to the scene, always change.
- Click selects; double-click toggles player view; drag to reorder (not on
  shot sheets).
- **Timeline scenes:** Expand, Hide, Hide all before/after, Jump to cut
  start/end, Scrub. Box background = mean color with the frame image; the
  selected scene widens to full aspect width.

## 8. Keyboard

| Key | Action |
|---|---|
| 1 / 2 / 3 | Movie list / player view / settings |
| A | Add movies |
| F | Detection chart |
| G | Grid ↔ timeline |
| M | Save sheet |
| Space | Player view; shot sheets: toggle cut/merge vs change-thumb mode |
| ← / → | Player ±10 frames |
| ⇧ ← / → | ±1 frame |
| ⌥ ← / → | ±100 frames |
| ⇧⌥ ← / → | Previous/next cut (timeline) or thumb (grid) |
| Return | Timeline: cut here, or merge at a cut. Shot grid: change thumb. Interval grid: change thumb; ⇧/⌥ add before/after |
| S | Player: save current frame |
| ⌥ while dropping | Clear list, then add |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘0 / ⌘= / ⌘− | Fit / zoom in / zoom out |
| ⌃⌘F | Full screen |

Letter and number keys do nothing while a text field has focus. MoviePrint's
Alt and Ctrl become Option and Control.

## 9. Player view

- Video on top, the sheet as one horizontal strip below (thumbs, or scene bars
  at 0.3 px per frame).
- Frame strip: 20 vertical slices of consecutive frames around the current
  frame (19 in grid mode); middle slice ≈ 1/4 width (1/3 for an odd count),
  halving outward; 1 px gaps, 8 px at a cut.
- Current frame number; playback with audio (AVPlayer); save frame; timeline
  bar with playhead and IN/OUT.
- Buttons: previous cut/thumb, −100, −10, −1, CUT/MERGE or CHANGE / ADD BEFORE
  / ADD AFTER, +1, +10, +100, next.

## 10. Scanning

- **One scan pass:** a single `AVAssetReader` output at max 720 px BGRA
  (transform applied) feeds both the shot metric and face detection; the
  240 px frame for the metric is derived from it with vImage. No second reader
  or output, and no 240 px reader output (both are slower). About 9 min for a
  2 h 1080p60 film on the measured Mac; progress and Cancel are shown. Use the
  macOS 27 `AVAssetReaderOutput.Provider` API.
- **Shot scan** reads every frame at max 240 px (derived as above).
  - Mean method: difference = |mean V − previous mean V| (HSV V, 0–255); mean
    color = HSV mean converted to RGB.
  - Histogram method: 32×32×32 HSV histogram, normalized, chi-square
    (alternative) distance; color = RGB mean.
  - Stored per frame `{frameNumber, difference, meanColor}` in a per-file
    scan cache; scanned once per file; scenes stream to the UI during the scan.
  - Scene list: cut where difference ≥ threshold and ≥ 10 frames since the last
    cut; within that window a larger difference moves the cut. Scene color =
    mean color of the middle frame; the last scene gray.
  - Detection chart: difference per frame, threshold line, and a "calculated
    threshold" from k-means (k = 3) on a 256-bin histogram (display only).
- **Automatic IN/OUT:** scan the first and last min(300, length / 2) frames at
  0.25 scale; IN = first frame with mean V ≥ 20, OUT = the same from the end;
  fall back to the brightest frame.
- **Timeline layout:** fill rows until the summed length exceeds
  `secondsPerRow × fps` with the movie's own fps (MoviePrint hard-codes 25 fps;
  owner, 2026-11-01); px per frame = minimum over rows of (width − 2 × margin ×
  scenes) / frames, short scenes counted at the minimum length; row height =
  (print height − margins) / rows; scene width = max(ppf × length, ppf × min
  length).
- Cut and merge recompute the middle-frame thumbs.
- **Faces (Lv1):** Vision face rectangles (Swift API, default revision) on
  the scan pass's 720 px frames; warm the request up when a movie opens. Per face: confidence, size (box height as % of frame height),
  relative box. Per frame: `{frameNumber, faceCount, largestSize, faces}` in
  the scan cache. Scope: every 10th (default) / every 100th frame between
  the lowest and highest visible thumb, or exactly the current thumbs. When the
  shot scan has not run, a face scan runs the same combined pass. On the
  ffmpeg path, every 100th frame is the default. Sort by face
  count, size, confidence; filters (each toggleable): face count 1–10
  (default 1–3), size (default 50–100). Face rectangles overlay.
- **Routing:** check the HEVC sample entry on open; `hev1` and codecs
  AVFoundation lacks (WMV3, VP9/AV1 in MKV/WebM, …) go to the ffmpeg path,
  which decodes in software (no `-hwaccel videotoolbox`) to a BGRA pipe.
  Thumbnails use zero time tolerance, then the ±0.5 s retry (decision 11).
- **ffmpeg discovery** (fallback decode): user-chosen path (persisted) →
  login-shell `command -v ffmpeg` (`/bin/zsh -lic`) → `/opt/homebrew/bin`,
  `/usr/local/bin`, `/opt/local/bin`, `~/.nix-profile/bin`,
  `/nix/var/nix/profiles/default/bin`; validated with `ffmpeg -version`.

## 11. Look

- Content in the kni Design System (Catppuccin Mocha base): color, spacing
  and radius tokens from the design system itself; dark appearance only.
- Type: the system fonts (SF Pro, SF Mono, SF Pro Condensed) at the design
  system's sizes, instead of its IBM Plex (owner, 2026-11-03).
- Window chrome and toolbar: system Liquid Glass, tinted with the kni accent.
- MoviePrint's layout and interactions are reproduced; its look is not.

## 12. Export, import, persistence

- **Save sheet:** render the sheet offscreen at the target size with
  frames grabbed fresh at about 2× thumb size (capped at the original);
  PNG or JPG; limit 16384 px; timeline: size = height.
- **PNG embedded data:** `tEXt` chunks before IEND, MoviePrint-compatible keys:
  `version`, `filePath` (URI-encoded), `transformObject` (JSON),
  `columnCount`, `frameNumberArray` (JSON, non-shot) or `sceneArray` (JSON,
  shot).
- Include individual thumbs → a folder named after the print.
- **Save All MoviePrints:** queue over all sheets of all files (files with no
  sheet get a default interval sheet); modal progress with Cancel.
- **JSON export** `<file>-<sheet>.json` =
  `{filePath, transformObject, columnCount, frameNumberArray | sceneArray}`.
- **EDL export** (shot sheets): CMX3600-style, `TITLE:`, `FCM: NON-DROP FRAME`,
  events with `* FROM CLIP NAME:`; hidden scenes excluded.
- **Import** PNG or JSON, from FrameSheet v3 and from MoviePrint 0.2.x → a new
  file entry and sheet (frame list → interval/grid; scene array →
  shot/timeline); rotation ignored on import. Replace movie relinks a file.
- **Persistence:** library, sheets and settings as Codable JSON in Application
  Support, saved shortly after each change and restored on launch; per-file
  scan cache (per-frame metric as Float32, about 1.5 MB per 2 h film, plus
  face data for sampled frames); thumbnails are cached in memory only.

## 13. Open items

- None. Still to measure: 4K HEVC and HDR inputs, and the fastest Mac
  (`docs/v3-measurements.md`, Caveats).
