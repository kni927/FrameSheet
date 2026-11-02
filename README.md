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

- **Hover a thumb** for IN, OUT, insert before/after, EXPAND and Hide (each
  button has a tooltip); hold ⌥ and IN/OUT turn into ◀ HIDE / HIDE ▶, which
  hide every thumb before or after it.
- **Drag the handle** in the middle of a thumb to scrub: CHANGE TO by default,
  ⇧ for ADD BEFORE, ⌥ for ADD AFTER, ⌃ to reach the start or end of the movie;
  drop on the Cancel bar to cancel. A quick click on the handle keeps the scrub
  open: move to pick, click to confirm, Esc to cancel. With a thumb selected,
  Return scrubs with the arrow keys.
- **Drag a thumb** onto another to reorder; ⇧⌥←/→ move the selection.
- The toolbar over the grid adds interval sheets (2×2 … 6×6), duplicates the
  sheet, zooms (⌘− / ⌘0 / ⌘=), shows hidden thumbs, cycles the frame info and
  optimises the grid; the settings sidebar (3) sets columns, rows, margins and
  frame info; the movie list (1) renames, duplicates and deletes sheets.
- ⌘Z / ⇧⌘Z undo and redo up to 50 edits.

Saving prints, shot detection, the player view and faces come in later
versions.

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
([docs/licenses/Catppuccin-LICENSE](docs/licenses/Catppuccin-LICENSE)), and the
bundled IBM Plex fonts are under the SIL Open Font License 1.1
([docs/licenses/IBM-Plex-LICENSE](docs/licenses/IBM-Plex-LICENSE)).
