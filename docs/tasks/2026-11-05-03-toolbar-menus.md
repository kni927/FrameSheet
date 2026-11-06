# TASK: toolbar and menus — fewer icons, everything in the menus, faces scope shared across sheets

Defined by the owner in the chat of FrameSheet TF #03 (2026-11-05), written
by the TF ("TASKs from the TF's chat", `docs/sessions.md`). Approved by
the owner in chat (2026-11-05): choices A–D as below, with the two changes
under "Owner's decisions".

## Background

The owner's requests (2026-11-05), in their words, translated:

1. The toolbar has too many icons. When they do not fit, the overflow `>>`
   appears, but the toolbar stops after Zoom in with much blank space, and
   `>>` lists only "Show hidden thumbs".
2. Move More options (Import Sheet…, Clear movie list…) into the File or Edit
   menu; remove its icon.
3. The same for More save options.
4. From an interval sheet, Add faces sheet, then Add shot-detection sheet
   gives the shots at once (good); but Add faces sheet from that shot sheet
   reads the movie again from the start.
5. Add faces sheet: a normal click opens the scope menu (no press and hold).
6. Fit height / Fit width: keep the buttons, gray them out instead of hiding.
7. Every action that is only an icon (merge, cut, …) goes into the menus,
   with shortcut keys.
8. The detection chart can be in the menu only.
9. Make the toolbar editable (customizable).
10. Face detection: not in the right panel, but a Face Detection menu item
    where it is adjusted.

Findings so far:

- 1: each `ToolbarItem` holds a whole `ToolbarIconGroup` (up to 9 buttons),
  so the overflow moves a whole group and lists only its first control
  (`SheetToolbar.swift`; the third group starts with Show hidden thumbs).
  `Guess:` the blank space is the room the next group needs; a toolbar with
  one item per control (needed for 9 anyway) settles it.
- 4: `Checked:` in the owner's scan log (2026-11-05 13:50–13:52, a WebM on
  the ffmpeg path, every 100th frame): the interval sheet's faces scope was
  213 frames; from the shot sheet the scope was 195 frames, "195 not in the
  face cache (213 analyzed before)": no frame shared. The sampled scopes
  spread frames evenly between the sheet's lowest and highest thumb
  (MoviePrint `getIntervalArray`), and a shot sheet's last thumb is the last
  scene's first frame, so the spacing and every position differ.

## Goal

A short default toolbar the owner can customize, every toolbar action also
in a menu (most with a shortcut), Import/Clear/Save options and the
detection chart only in menus, Fit height/width disabled instead of hidden,
Add faces sheet as a plain menu button, face detection settings from a menu,
and a faces scan from any sheet reusing the frames earlier scans analyzed.

## Scope

### In scope

- Menus (proposed structure below): File, Edit, View, and a new Sheet menu.
- Toolbar: `toolbar(id:)` with one customizable item per control
  (Customize Toolbar… from the toolbar's context menu and View); a default
  set (below), the rest in the customization palette. Fit height/width
  disabled instead of hidden. Add faces sheet opens its scope menu on click.
  Remove More options, More save options and the detection chart icons.
- Faces scope: the sampled scopes (every 10th / 100th frame) take the frames
  on a fixed grid, multiples of 10 / 100 between the lowest and highest
  thumb, so scans from different sheets share frames (owner, see choice C).
- Face detection: the "Face detection" panel section moves to a Face
  Detection… window or sheet opened from the Sheet menu (owner, choice D).
- Docs: `README.md` where it names toolbar items or keys; the TASK record.
  `docs/V3_SPEC.md` §4/§8 and `docs/DECISIONS.md` are the HQ's: the report
  lists the owner's decisions for the HQ to record.

### Out of scope

- Other panel sections, the player's own controls, new features beyond the
  list, the release.

### Parts

1. Menus with shortcuts; remove More options / save options / chart icons.
2. Customizable toolbar with the default set; Fit height/width disabled; Add
   faces sheet as a menu button.
3. Faces scope on a fixed grid (with a test); Face Detection… from the menu.

## Choices for the owner

A. Menus and shortcuts (proposal; letter keys without ⌘ stay as §8 has them
   and are shown in the menu titles' tooltips only, since a menu shortcut
   would also fire while a text field has focus):

   - File: Add Movies… (A), Import Sheet… ⇧⌘I, —, Save Sheet ⌘S (also M),
     Save All Sheets ⌥⌘S, Open Output Location, —, Clear Movie List… ⇧⌘⌫
   - Edit: Undo ⌘Z, Redo ⇧⌘Z, —, Duplicate Sheet ⌘D
   - Sheet (new): Add Interval Sheet ▸ 2×2 … 6×6 (⌃⌘2 … ⌃⌘6), Add
     Shot-Detection Sheet ⇧⌘D, Add Faces Sheet ▸ Every 10th ⇧⌘F / Every
     100th / These thumbs, Back to Parent Sheet ⌘↑, —, Sort ▸, Filter Faces…
     ⌥⌘F, Optimize Grid Layout ⌥⌘O, —, Cut Scene ⌘K, Merge with Previous
     ⌥⌘←, Merge with Next ⌥⌘→, —, Face Detection… ⌥⌘D, Detection Chart (F)
   - View: Fit ⌘0, Fit Height ⌃⌘0, Fit Width ⌥⌘0, Zoom In ⌘=, Zoom Out ⌘−,
     —, Show Hidden Thumbs ⇧⌘H, Show Header ⌥⌘H, Thumb Label ▸ Frames /
     Timecode / None, Face Rectangles ⌥⌘R, —, Grid / Timeline View (G),
     Player View (2), Mean Colors Only ⌥⌘I, —, Movie List (1), Settings
     Panel (3), Customize Toolbar…

B. Default toolbar: movie list, Add movies, Add interval sheet, Add
   shot-detection sheet, Add faces sheet, Undo, Redo, Zoom out, Fit, Zoom
   in, Grid/Timeline, Player view, Save sheet, panel. In the palette: Back to
   parent, Sort, Filter, Duplicate, Fit height, Fit width, Show hidden
   thumbs, Show header, Thumb label, Face rectangles, Mean colors, Optimize
   grid, Cut, Merge ×2. (The grouped look, icons touching, may not survive
   customization: `Guess:`, checked when built.)

C. Faces scope on a fixed grid (recommended): every 10th scope = frames
   that are multiples of 10 from the lowest to the highest thumb (100 for
   every 100th). Differs from MoviePrint's positions (evenly spread between
   the thumbs) by at most half a step; the count stays about the same.

D. Face Detection…: a small window (like the transform dialog) with the
   current section's controls and Apply; the right panel loses the section.

## Owner's decisions (2026-11-05)

- A–D as proposed, except:
- The single-letter keys (A, M, F, G, 1, 2, 3) also get ⌘ shortcuts in the
  menus: a ⌘ shortcut does not fire while a text field has focus, so it can
  be a menu shortcut (only the bare letter cannot). Add Movies ⌘O, Save
  Sheet ⌘S, Detection Chart ⇧⌘C, Grid / Timeline View ⌘G, Movie List ⌘1,
  Player View ⌘2, Settings Panel ⌘3; the bare letters keep working.
- Face Detection…: the Apply button's place is to be reconsidered. The TF
  puts it at the bottom right as the window's default button (Return),
  next to Close, disabled with a caption when there is nothing to apply;
  the owner checks it.

## Implementation notes

- Builds and tests through `scripts/check.sh install`.
- Menu commands act on the main window's model; disabled states as the
  toolbar has them now.
- Keep UI text in English; tooltips short.

## Verification

- `scripts/check.sh install` passes; a core test for choice C (two sheets'
  scopes share their frames).
- The owner checks the menus, shortcuts, toolbar customization and overflow,
  and a faces sheet from a shot sheet after one from an interval sheet.

Estimate: 50 min of working time (three UI parts, mostly menus and the
toolbar; one core change with a test).

## Progress

- 2026-11-05 15:04 JST: owner approved A–D with the two changes above.
- Implemented in one commit (5612a1c): parts 1 and 2 touch the same toolbar
  and menu files, and Face Detection… (part 3) was built with the menus.

## Implementation Result

Status: Completed

### Changes

- `Sources/FrameSheet/AppCommands.swift` (new): File (Add Movies… ⌘O,
  Import Sheet… ⇧⌘I, Save Sheet ⌘S, Save All Sheets ⌥⌘S, Open Output
  Location, Clear Movie List… ⇧⌘⌫), Edit (Undo, Redo, Duplicate Sheet ⌘D),
  Sheet (Add Interval Sheet ▸ ⌃⌘2…6, Add Shot-Detection Sheet ⇧⌘D, Add Faces
  Sheet ▸ Every 10th ⇧⌘F, Back to Parent Sheet ⇧⌘P, Sort ▸, Filter Faces…
  ⌥⌘F, Optimize Grid Layout ⌥⌘O, Cut Scene ⌘K, Merge with Previous / Next
  Scene ⌘[ / ⌘], Face Detection… ⌥⌘D, Detection Chart ⇧⌘C), View (Fit ⌘0,
  Fit Height ⌃⌘0, Fit Width ⌥⌘0, Zoom, Show Hidden Thumbs ⇧⌘H, Show Header
  ⇧⌘E, Thumb Label ▸, Show Face Rectangles ⌥⌘R, Grid/Timeline ⌘G, Player
  ⌘2, Mean Colors Only ⌥⌘I, Movie List ⌘1, Settings Panel ⌘3,
  `ToolbarCommands`).
- Deviations from the proposal (conflicts found while writing): Merge
  ⌥⌘←/→ → ⌘[ / ⌘] and Back to Parent ⌘↑ → ⇧⌘P (text fields use those keys,
  and a menu shortcut wins over the field); Show Header ⌥⌘H → ⇧⌘E (⌥⌘H is
  the system's Hide Others). Reported to the owner.
- `SheetToolbar.swift`: `CustomizableToolbarContent`, one item per control,
  the default set of choice B, the rest `showsByDefault: false`; Fit
  height/width disabled instead of hidden; Add faces sheet a plain menu
  button; no More save options and no detection chart icon.
- `ContentView.swift`: `toolbar(id:)`; no More options menu; Clear, Filter
  Faces… and Face Detection… driven by model flags (`AppModel.swift`).
- `SettingsPanel.swift`: the Face detection section became
  `FaceDetectionDialog` (Apply as the default button at the bottom right,
  Close beside it); `MenuDialog` for Filter Faces….
- `FaceScanner.swift` (`FaceScanScope.frames`): the sampled scopes take the
  multiples of 10 / 100 between the lowest and highest thumb.
- Tests: `FaceTests.swift` (scope frames on the grid;
  `sheetsShareTheirSampledFrames`: a shot sheet's 196 frames all among the
  interval sheet's 214 on a 21313-frame movie).
- `README.md`: menus, shortcuts, Customize Toolbar…, Face Detection….

### Owner's decisions for the HQ

- All toolbar commands in menus, most with ⌘ shortcuts; the §8 single
  letters keep working and get ⌘ versions (spec §4, §8).
- A customizable toolbar with the default set of choice B (spec §4).
- Face detection thresholds in a Face Detection… dialog, not the panel
  (spec §6).
- Faces sampled scopes on a fixed 10 / 100-frame grid instead of
  MoviePrint's evenly spread frames (a deviation from MoviePrint; a
  decision for `docs/DECISIONS.md`).

### Verification

- Build: `scripts/check.sh install`: 307 tests in 64 suites passed (1 known
  issue), no warnings, installed and launched by the script.
- Manual: the owner was shown the result and said to proceed (2026-11-05);
  no item-by-item results were reported.
- Not performed: the toolbar's look (placement of `.automatic` items, the
  lost grouped look) was not seen by the TF.

### Remaining Issues

- None known. The faces scope change makes face scans stored before it
  miss on their first rescan (frames moved to the grid).

### Follow-up Suggestions

- HQ: record the decisions above in `docs/V3_SPEC.md` §4/§6/§8 and
  `docs/DECISIONS.md`.
