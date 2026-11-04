# <img src="assets/AppIcon.png" width="40" valign="middle"> FrameSheet

FrameSheet is a macOS app that makes video contact sheets (MoviePrints).

**v3 is in development**: a rebuild that reproduces
[MoviePrint](https://github.com/fakob/MoviePrint_v004) v0.2.23 natively for
Apple Silicon — many movies at once, interval, shot-detection and face sheets,
editable thumbs and scenes, and export as PNG/JPG, JSON and EDL. The target
behavior is in [docs/V3_SPEC.md](docs/V3_SPEC.md). The released app is v2
(tag `v2.3.1`), a settings-to-one-image contact sheet generator.

## Status

v3 so far: add movies with the + button, the A key or by dropping them on the
window. Each movie gets a default interval sheet of 16 thumbs in 4 columns,
which you can edit:

- **Hover a thumb** for IN, OUT, insert before/after, EXPAND, HIDE and SAVE
  (each button has a tooltip); hold ⌥ and IN/OUT turn into ◀ HIDE / HIDE ▶,
  which hide every thumb before or after it.
- **Drag the handle** in the middle of a thumb to scrub from its own frame:
  CHANGE TO by default, ⇧ for ADD BEFORE, ⌥ for ADD AFTER, ⌃ to reach the
  start or end of the movie (the overlay names the keys); drop on the Cancel
  bar to cancel. A quick click on the handle keeps the scrub
  open: move to pick, click to confirm, Esc to cancel. With a thumb selected,
  Return scrubs with the arrow keys.
- **Drag a thumb** onto another to reorder; ⇧⌥←/→ move the selection.
- The window toolbar adds interval sheets (2×2 … 6×6), duplicates the sheet,
  undoes and redoes, zooms (⌘− / ⌘0 / ⌘=, fit height, fit width), shows hidden
  thumbs and the header, cycles the thumb label, switches grid and timeline
  view (G), shows mean colors only in the timeline, optimizes the grid, saves
  the sheet (M) and toggles both sidebars (1, 3).
- **Add shot-detection sheet** (toolbar) scans the movie once for shots and
  streams the scenes into a shot sheet in timeline view (progress and Cancel
  in the toast, or Esc; the same button resumes a cancelled scan, and
  **Rescan for Shots** in the movie's menu starts over; about 9 min for a 2 h
  1080p film). Scanned movies get an "S" on
  their poster. The timeline lays scenes out in rows of a set movie time
  (Minutes per row), as wide as they are long; click a scene to see it at
  full width. A new threshold in the settings panel makes a new sheet from
  the stored scan without scanning again. Interval sheets can be shown as a
  timeline too.
- **Hover a scene** in the timeline for EXPAND (a child sheet inside the
  scene), HIDE, ◀ HIDE / HIDE ▶, jump to the cut before or after, and a scrub
  limited to the scene. The toolbar cuts the selected scene at its thumb and
  merges it with the previous or next scene. **F** opens the detection chart
  (difference per frame, threshold and cuts).
- **Player view** (2, Space, the toolbar, or a double-click on a thumb or
  scene): the movie with a strip of consecutive frames around the current
  one, the sheet as one row, and a timeline bar. Step with ←/→ (±10),
  ⇧ (±1), ⌥ (±100), ⇧⌥ (previous/next cut or thumb); P plays (with audio;
  files read with ffmpeg play video only). Return cuts or merges at the
  current frame on shot sheets (Space switches to changing the thumb), and
  changes the thumb (⇧ adds before, ⌥ after) on interval sheets; S saves the
  current frame.
- **Automatic IN/OUT** (Grid section, More) skips black frames at the start
  and end of a movie when it is added, with a brightness threshold; Apply
  sets them on the current sheet.
- **Save sheet** writes the sheet as PNG or JPG (1024–16384 px or max; the
  height in timeline view) with an
  optional header (file name, folder, details, mini timeline). A PNG carries
  the frame list in MoviePrint-compatible text chunks. Options: folder, file
  name templates (`[MN]` `[ME]` `[SN]` `[FN]` `[TC]`), overwrite or " edit N",
  and a folder with each thumb as its own image. **Export JSON** is in a
  sheet's menu, and **Export EDL** (CMX3600) for shot sheets.
- **Import Sheet…** (the … menu, or the + button, or a drop) reads a PNG or
  JSON saved by FrameSheet or MoviePrint 0.2.x and adds the movie with that
  sheet. A moved movie shows "Movie is missing" with Locate…; **Replace
  movie…** relinks a movie and keeps its sheets; **Clear movie list…** asks
  first and can be undone.
- The settings panel (3) sets columns (rearranges live), target rows and
  Replace (recaptures columns × rows thumbs), header, margins, corner radius,
  the timeline (minutes per row, natural flow, scene width ratio, min scene
  width, shot threshold), the thumb label (frames, with the last frame
  number, or a timecode format; font, size, colors, position), output and
  file names; each section opens with its chevron. The movie list (1) renames,
  duplicates, deletes and exports sheets. The thumbnail cache and ffmpeg are
  in Settings (⌘,), with **Fetch exact frames with ffmpeg** (on by default):
  some files (open-GOP H.264) have frames AVFoundation cannot decode, and
  ffmpeg fetches those; without it such thumbs show the nearest decodable
  frame with a marker.
- **Add faces sheet** (toolbar; click for every 10th frame, every 100th for
  files read with ffmpeg; press and hold for every 100th frame or these
  thumbs) looks for faces with Apple Vision between the sheet's first and
  last thumb and makes a faces sheet of the frames with faces, largest face
  first. It reads the frames in the shot scan's pass, so a movie not yet
  scanned for shots gets that scan up to the last frame too; Cancel or Esc
  keeps what was found, and the same scope resumes. **Sort** (reverse, frame
  number; face count, size, confidence on faces sheets) and **Filter** (face
  count, face size) are one undo step each; the toolbar shows or hides the
  face rectangles (in the window and the player; in saved sheets with
  Output → Include face rectangles). The confidence and size thresholds are
  in the settings panel; Apply rescans the current faces sheet with them.
  A movie's stored shot and face scans can be deleted with **Clear Stored
  Scans** in its menu. Each scan writes timings to
  `~/Library/Logs/FrameSheet/scan.log`.
- ⌘Z / ⇧⌘Z undo and redo up to 50 edits.

## Requirements

- macOS 27 or later on Apple Silicon.
- **FFmpeg**, only for files AVFoundation cannot decode (WebM, MKV, WMV, HEVC
  tagged `hev1`). FrameSheet looks for a chosen path, then your login shell's
  `PATH`, then the usual install directories (Homebrew, MacPorts, Nix).

```bash
brew install ffmpeg
```

## Building

Requires Xcode 27.

```bash
./build.sh
```

The app is assembled at `./build/FrameSheet.app` (with a zip next to it);
SwiftPM's build products stay in `~/Library/Caches/FrameSheet/build`. Run the
core tests with:

```bash
swift test --scratch-path ~/Library/Caches/FrameSheet/build
```

## Author

Created and maintained by **kni**.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
MoviePrint code ported into FrameSheet keeps its MIT notice
([docs/licenses/MoviePrint-LICENSE](docs/licenses/MoviePrint-LICENSE)); the
Catppuccin palette is MIT as well
([docs/licenses/Catppuccin-LICENSE](docs/licenses/Catppuccin-LICENSE)).
