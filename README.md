# <img src="src/assets/AppIcon.png" width="40" valign="middle"> FrameSheet

![FrameSheet UI Preview](docs/preview.png)

FrameSheet is a macOS native app that generates customizable video contact sheets (MoviePrints).  
**v2** replaces the vcsi backend with a native ffmpeg engine + CoreGraphics compositor, delivering dramatically faster generation especially for HEVC/4K content. By default, FrameSheet generates an instant **Fast Mode** preview using only the video's keyframes, with an optional **Normal Mode** for a full, evenly-spaced sampling pass.

## Features

- **SwiftUI Native Experience**: Sleek, responsive, and lightweight UI following modern macOS design.
- **Fast Mode (keyframes only)**: Enabled by default. Extracts only the video's keyframes (`-skip_frame nokey`) for near-instant previews, even on 4K HEVC footage.
- **Real-time Previews**: See grid size, spacing, font, and colors update on-the-fly.
- **Flexible Grid Controls**: Adjust columns, rows, spacing, and image width with quick `−` / `+` steppers.
- **Standard macOS Font Picker**: Choose any installed system font via macOS's native font panel.
- **Timestamp Overlays**: Uniform or custom timestamps drawn in four corner positions.
- **Custom Header Template**: Jinja2-style placeholders (`{{filename}}`, `{{duration}}`, etc.) resolved in Swift.
- **Built-in Console Logger**: Inspect raw ffmpeg output, copy or export log.

## Fast Mode vs. Normal Mode

| | Fast Mode (default) | Normal Mode |
|---|---|---|
| Frame selection | Keyframes only (`-skip_frame nokey`) | Evenly-spaced sampling (`fps=1/interval`) |
| Speed | Near-instant, even for 4K HEVC | Slower — decodes the full sampled range sequentially |
| Thumbnail count | May be **less than `rows × columns`**, depending on the video's keyframe interval (GOP length). The grid's row count automatically shrinks to fit the actual count. | Always exactly `rows × columns` |
| Timestamps | Approximate (interpolated across the sampled range) | Exact, evenly-spaced (or custom, if configured) |
| Custom Timestamps | Disabled | Available |

The toolbar shows an indicator next to "Show in Finder" reporting how many of the extracted keyframes were used, e.g.:

```
Fast mode: 16 of 54 keyframes
```

Toggle "Fast mode: keyframes only" off in the Layout tab to switch to Normal Mode for a full, precisely-spaced contact sheet.

## Performance

| Mode | 4K60 HEVC, 60s, 4×4 grid |
|---|---|
| **Fast Mode (default)** | **<1 second** — decodes keyframes only |
| **Normal Mode** | **~25 seconds** — sequential decode of the sampled range (`-hwaccel videotoolbox` enabled, but the `fps` filter still requires decoding every frame) |

Both modes use VideoToolbox hardware decoding (`-hwaccel videotoolbox`) and JPEG (`-q:v 3`) for temporary thumbnail files to minimize I/O overhead. Normal Mode decodes the video linearly rather than seeking to each frame individually, which eliminates the keyframe-reload penalty that made HEVC extraction so slow in v1; Fast Mode goes further by skipping non-keyframe decoding entirely.

> **Note**: Normal Mode generation time scales with the sampled duration and frame rate — high-fps slow-motion HEVC footage (e.g. 240fps) can take significantly longer (several minutes) than the figures above.

## Prerequisites

Only **FFmpeg** is required — no Python, no vcsi.

```bash
brew install ffmpeg
```

The app detects `ffmpeg` / `ffprobe` on launch and shows an overlay if they are missing.

## Building

```bash
./build.sh
```

The packaged application is generated at `./build/FrameSheet.app`.

## Author

Created and maintained by **kni**.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
