# Known Issues - FrameSheet

This document lists known limitations, technical restrictions, and potential bugs identified in FrameSheet.

---

## Technical Limitations

### 1. Font Fallback and Character Corruption (Tofu)
* **Description**: If a font that does not contain Japanese characters (such as `Helvetica` or custom Western-only fonts) is selected, any Japanese characters in the metadata (video name, path, codec names) will render as tofu (□) in the output contact sheet.
* **Reason**: The underlying `vcsi` engine uses Python's Pillow library for text rendering. Pillow only reads glyphs from the single specified font file and does not support system font fallback.
* **Workaround**: Keep the font set to the default `Hiragino Sans` when processing files containing Japanese text.

### 2. Rapid Stepper Updates and Process Termination
* **Description**: Quickly clicking the Grid Dimensions (`+` or `-`) buttons may cause the rendering to restart multiple times, occasionally leaving incomplete background processes.
* **Reason**: FrameSheet terminates the active `vcsi` process whenever a new generation request is triggered (`activeProcess?.terminate()`). While safe, rapid termination and restarting can increase CPU load.
* **Workaround**: Allow the generation to complete (indicated by the progress spinner disappearing) before changing layout options again.

### 3. Font Path Resolution for Sandboxed Fonts
* **Description**: Selecting certain cloud-synced, custom, or system-protected fonts through the native `NSFontPanel` might fail to resolve to a valid local file path or return `.true` on `FileManager.fileExists`.
* **Reason**: macOS handles system-protected fonts and cloud-synced fonts (e.g., from Adobe Creative Cloud or Typekit) via virtual font descriptors or restricted paths.
* **Workaround**: If a font returns to the default Hiragino Sans upon selection, it means its local `.ttf`/`.ttc` file was not accessible. Please choose a standard local font or browse a manual font file.

### 4. Temporary Preview Flicker during Auto-Fit
* **Description**: When a new contact sheet is generated, the preview may flicker or show scrollbars for a fraction of a second before scaling down.
* **Reason**: SwiftUI triggers rendering before the window's updated geometry coordinates propagate to `fitToScreen()`.
* **Workaround**: This is cosmetic and resolves immediately. Clicking "Fit" manually in the header will force-recalculate if needed.
