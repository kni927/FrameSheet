# FrameSheet

FrameSheet is a modern, premium, and lightweight macOS native wrappers for `vcsi`. It allows users to quickly generate highly customizable video contact sheets (MoviePrints) with a beautiful SwiftUI-based graphical interface.

## Features

- **SwiftUI Native Experience**: Sleek, responsive, and lightweight user interface following modern macOS design languages.
- **Real-time Previews**: Instant feedback loop. See your grid size, spacing, font, and custom colors update on-the-fly.
- **Flexible Grid Controls**: Adjust columns, rows, spacing, and image widths instantly with quick `-` and `+` adjusters.
- **Standard macOS Font Picker**: Choose any installed system font directly using macOS's native font panel.
- **Accurate Time Overlays**: Display video timestamps dynamically mapped in various alignments, or enter manual custom timestamps.
- **Built-in Console Logger**: Select, copy, or export the background `vcsi` process logs directly for quick debugging.

## Prerequisites

FrameSheet requires `vcsi` and `ffmpeg` to be installed on your system.
The app automatically checks for these binaries on launch:
- `vcsi` (via Pip or system packages)
- `ffmpeg`/`ffprobe`

## Building

To compile and package the app locally:
```bash
./build.sh
```
The packaged application will be generated at `./build/FrameSheet.app`.

## Author

Created and maintained by **kni** (2026).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
