# <img src="assets/AppIcon.png" width="40" valign="middle"> FrameSheet

FrameSheet is a macOS app that makes video contact sheets (MoviePrints).

**v3 is in development**: a rebuild that reproduces
[MoviePrint](https://github.com/fakob/MoviePrint_v004) v0.2.23 natively for
Apple Silicon — many movies at once, interval, shot-detection and face sheets,
editable thumbs and scenes, and export as PNG/JPG, JSON and EDL. The target
behaviour is in [docs/V3_SPEC.md](docs/V3_SPEC.md). The released app is v2
(tag `v2.3.1`), a settings-to-one-image contact sheet generator.

## Status

The v3 skeleton runs: add movies with the + button, the A key or by dropping
them on the window; each movie gets a default interval sheet of 16 thumbs in
4 columns, and the movie list is restored on the next launch. Everything else
in the spec comes in later versions.

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
