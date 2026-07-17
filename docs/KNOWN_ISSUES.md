# Known Issues - FrameSheet

This document lists known limitations, technical restrictions, and potential bugs identified in FrameSheet.

---

## Technical Limitations

### 1. Font Fallback and Character Corruption (Tofu) — Likely resolved in v2.0.0, pending verification
* **Description**: If a font that does not contain Japanese characters (such as `Helvetica` or custom Western-only fonts) is selected, any Japanese characters in the metadata (video name, path, codec names) could render as tofu (□) in the output contact sheet.
* **Reason (pre-v2.0.0)**: The previous `vcsi` engine used Python's Pillow library for text rendering, which only reads glyphs from the single specified font file and does not support system font fallback.
* **Status (v2.0.0)**: Text is now rendered via CoreGraphics/`NSAttributedString` (`renderContactSheet`), which uses macOS's native font fallback. This issue is expected to be resolved, but has not been explicitly re-tested with a non-Japanese font (e.g. `Helvetica`) against Japanese filenames/metadata.
* **Workaround**: Keep the font set to the default `Hiragino Sans` when processing files containing Japanese text, until re-verified.

### 2. Font Path Resolution for Sandboxed Fonts
* **Description**: Selecting certain cloud-synced, custom, or system-protected fonts through the native `NSFontPanel` might fail to resolve to a valid local file path or return `.true` on `FileManager.fileExists`.
* **Reason**: macOS handles system-protected fonts and cloud-synced fonts (e.g., from Adobe Creative Cloud or Typekit) via virtual font descriptors or restricted paths.
* **Workaround**: If a font returns to the default Hiragino Sans upon selection, it means its local `.ttf`/`.ttc` file was not accessible. Please choose a standard local font or browse a manual font file.

### 3. Fast Mode Timestamps Are Approximate — Obsolete (Fast Mode removed in Phase 3)
* **Description (historical)**: When "Fast mode: keyframes only" was enabled, the timestamps shown on the contact sheet corresponded to actual keyframe positions, not evenly-spaced intervals.
* **Status (Phase 3, 2026-07-07)**: Fast Mode was removed entirely; every generation now extracts exact, evenly-spaced (or custom) timestamps. See docs/DEV_LOG.md.

### 4. Fast Mode Thumbnail Count May Be Less Than Rows × Columns — Obsolete (Fast Mode removed in Phase 3)
* **Description (historical)**: In Fast Mode, the grid could hold fewer thumbnails than `rows × columns` when the video contained fewer keyframes than requested in the sampling range.
* **Status (Phase 3, 2026-07-07)**: Fast Mode was removed entirely; the grid is always filled with `rows × columns` frames. See docs/DEV_LOG.md.

### 5. Normal Mode Was Slow for Long / High-FPS Footage — Resolved in Phase 2
* **Description (historical)**: Normal Mode generation used a single-pass `fps=1/interval` filter that sequentially decoded every frame in the sampled range; a 60-min H.264 source took ~220 s even with `-hwaccel videotoolbox`, and high-fps HEVC slow-motion sources took several minutes.
* **Status (Phase 2, 2026-07-07)**: Normal Mode (and Custom Timestamps) now extract each frame with an input-seeking `ffmpeg -ss <t> -i <file> -frames:v 1` invocation, 5 in parallel. The same 60-min benchmark completes in ~1 s (see docs/DEV_LOG.md). Sources with extremely long keyframe intervals could still slow individual seeks, but this has not been observed in testing.

### 6. Duration Estimation Can Be Slow on Large Un-Indexed Files (Phase 4)
* **Description**: For files whose metadata lacks a duration (e.g. WebM without cues), the fallback packet scan must demux the file linearly; on multi-gigabyte un-indexed sources this can take a while (IO-bound, no decoding).
* **Reason**: Without an index/cues the container cannot be seeked to its end, so every packet header must be read to find the last timestamp.
* **Workaround**: The "Estimating duration…" state is cancellable. Files with proper duration metadata skip estimation entirely.

### 7. Temporary Preview Flicker during Auto-Fit
* **Description**: When a new contact sheet is generated, the preview may flicker or show scrollbars for a fraction of a second before scaling down.
* **Reason**: SwiftUI triggers rendering before the window's updated geometry coordinates propagate to `fitToScreen()`.
* **Workaround**: This is cosmetic and resolves immediately. Clicking "Fit" manually in the header will force-recalculate if needed.
