# <img src="assets/AppIcon.png" width="40" valign="middle"> FrameSheet

FrameSheet is a macOS app that makes video contact sheets (MoviePrints).

**v3 is in development**: a rebuild that reproduces
[MoviePrint](https://github.com/fakob/MoviePrint_v004) v0.2.23 natively for
Apple Silicon — many movies at once, interval, shot-detection and face sheets,
editable thumbs and scenes, and export as PNG/JPG, JSON and EDL. The target
behaviour is in [docs/V3_SPEC.md](docs/V3_SPEC.md). The released app is v2
(tag `v2.3.1`), a settings-to-one-image contact sheet generator.

## Status

v3 so far: add movies with the + button, the A key or by dropping them on the
window. Each movie gets a default interval sheet of 16 thumbs in 4 columns,
which you can edit:

- **Hover a thumb** for IN, OUT, insert before/after, EXPAND, HIDE and SAVE
  (each button has a tooltip); hold ⌥ and IN/OUT turn into ◀ HIDE / HIDE ▶,
  which hide every thumb before or after it.
- **Drag the handle** in the middle of a thumb to scrub: CHANGE TO by default,
  ⇧ for ADD BEFORE, ⌥ for ADD AFTER, ⌃ to reach the start or end of the movie;
  drop on the Cancel bar to cancel. A quick click on the handle keeps the scrub
  open: move to pick, click to confirm, Esc to cancel. With a thumb selected,
  Return scrubs with the arrow keys.
- **Drag a thumb** onto another to reorder; ⇧⌥←/→ move the selection.
- The window toolbar adds interval sheets (2×2 … 6×6), duplicates the sheet,
  undoes and redoes, zooms (⌘− / ⌘0 / ⌘=, fit height, fit width), shows hidden
  thumbs and the header, cycles the frame info, optimizes the grid, saves the
  sheet (M) and toggles both sidebars (1, 3).
- **Save sheet** writes the sheet as PNG or JPG (1024–16384 px or max) with an
  optional header (file name, folder, details, mini timeline). A PNG carries
  the frame list in MoviePrint-compatible text chunks. Options: folder, file
  name templates (`[MN]` `[ME]` `[SN]` `[FN]` `[TC]`), overwrite or " edit N",
  and a folder with each thumb as its own image. **Export JSON** is in a
  sheet's menu.
- **Import Sheet…** (the … menu, or the + button, or a drop) reads a PNG or
  JSON saved by FrameSheet or MoviePrint 0.2.x and adds the movie with that
  sheet. A moved movie shows "Movie is missing" with Locate…; **Replace
  movie…** relinks a movie and keeps its sheets; **Clear movie list…** asks
  first and can be undone.
- The settings panel (3) sets columns (rearranges live), target rows and
  Replace (recaptures columns × rows thumbs), header, margins, corner radius,
  frame info (font, size, colors, position, timecode format), output and file
  names; each section opens with its chevron. The movie list (1) renames,
  duplicates, deletes and exports sheets. The thumbnail cache and ffmpeg are
  in Settings (⌘,).
- ⌘Z / ⇧⌘Z undo and redo up to 50 edits.

Shot detection, the player view and faces come in later versions.

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
