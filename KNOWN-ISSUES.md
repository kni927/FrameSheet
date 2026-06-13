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

### 3. Fast Mode Timestamps Are Approximate (v2.0.0)
* **Description**: When "Fast mode: keyframes only" is enabled, the timestamps shown on the contact sheet correspond to the actual keyframe positions extracted by `-skip_frame nokey -vsync vfr`, not to evenly-spaced intervals across the sampling range.
* **Reason**: Fast Mode skips directly to keyframes rather than decoding at fixed `fps=1/interval` steps, so exact timestamp control is not possible.
* **Workaround**: Disable Fast Mode for an exact, evenly-spaced grid with precise timestamps. Custom Timestamps are also unavailable while Fast Mode is enabled.

### 4. Fast Mode Thumbnail Count May Be Less Than Rows × Columns (v2.0.0)
* **Description**: In Fast Mode, the number of thumbnails placed in the grid can be smaller than `rows × columns` if the video's GOP/keyframe interval produces fewer keyframes than requested within the sampling range.
* **Reason**: Fast Mode only extracts existing keyframes; it does not decode additional frames to fill the grid. When fewer keyframes are available than requested, the row count is shrunk to fit.
* **Workaround**: The `Fast mode: X of Y keyframes` indicator reports the actual vs. extracted counts. Disable Fast Mode to get a full `rows × columns` grid via Normal Mode.

### 5. Normal Mode Remains Slow for High-FPS HEVC Footage
* **Description**: Even with `-hwaccel videotoolbox` enabled, Normal Mode generation time for very high frame-rate slow-motion HEVC sources (e.g. 240fps) can take several minutes, much longer than the ~25 second figure typical of 4K60/60s clips.
* **Reason**: The `fps=1/interval` filter still requires sequentially decoding every frame in the sampled range; hardware decoding reduces but does not eliminate this cost at very high frame rates.
* **Workaround**: Use Fast Mode for a quick preview of high-fps footage, and expect longer wait times in Normal Mode for such sources.

### 6. Temporary Preview Flicker during Auto-Fit
* **Description**: When a new contact sheet is generated, the preview may flicker or show scrollbars for a fraction of a second before scaling down.
* **Reason**: SwiftUI triggers rendering before the window's updated geometry coordinates propagate to `fitToScreen()`.
* **Workaround**: This is cosmetic and resolves immediately. Clicking "Fit" manually in the header will force-recalculate if needed.
