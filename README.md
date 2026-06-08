# <img src="docs/AppIcon.png" width="40" valign="middle"> FrameSheet

![FrameSheet UI Preview](docs/preview.png)

FrameSheet is a macOS native wrapper for vcsi. It generates customizable video contact sheets like MoviePrints.

## Features

- **SwiftUI Native Experience**: Sleek, responsive, and lightweight user interface following modern macOS design languages.
- **Real-time Previews**: Instant feedback loop. See your grid size, spacing, font, and custom colors update on-the-fly.
- **Flexible Grid Controls**: Adjust columns, rows, spacing, and image widths instantly with quick `-` and `+` adjusters.
- **Standard macOS Font Picker**: Choose any installed system font directly using macOS's native font panel.
- **Accurate Time Overlays**: Display video timestamps dynamically mapped in various alignments, or enter manual custom timestamps.
- **Built-in Console Logger**: Select, copy, or export the background `vcsi` process logs directly for quick debugging.

## Prerequisites

FrameSheet bundles its own standalone executable of `vcsi` (compiled statically inside the App Bundle).
However, it requires **FFmpeg** to be installed on your system.
The app automatically checks for this binary on launch:
- `ffmpeg` / `ffprobe` (Must be available in system PATH or standard directories)

### Installing FFmpeg
You can install FFmpeg easily via [Homebrew](https://brew.sh):
```bash
brew install ffmpeg
```

## Building

To compile and package the app locally:
```bash
./build.sh
```
The packaged application will be generated at `./build/FrameSheet.app`.

## Author

Created and maintained by **kni**.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
