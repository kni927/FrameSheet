# Design Decisions - FrameSheet

This document outlines key technical trade-offs and structural architectural choices made during the development of FrameSheet.

## Summary of Decisions

### 1. FFmpeg is not bundled

#### Context
FrameSheet's native ffmpeg engine depends on `ffmpeg` and `ffprobe` to probe video metadata and extract thumbnail frames.

#### Decision
We explicitly chose **not** to bundle FFmpeg binaries inside the `FrameSheet.app` package. Instead, the application relies on the system PATH to discover `ffmpeg`/`ffprobe` or searches common installation prefixes (e.g., Homebrew, Miniforge).

#### Rationale
- **Distribution Size**: Bundling FFmpeg binaries would increase the app package size by ~80-100MB, whereas the core app is less than 15MB.
- **Licensing Considerations**: FFmpeg has complex GPL/LGPL configurations. Requiring external installation mitigates license redistribution liabilities.
- **Ease of Installation**: Target power users typically already have Homebrew (`brew install ffmpeg`) or have standard media tools installed on their Macs.

---

### 2. vcsi removed in favor of a native ffmpeg + CoreGraphics engine (v2.0.0)

> **Note**: This decision reverses the original "vcsi is bundled" decision below it was superseded by, which is retained for historical context.

#### Context
`vcsi` (Video Contact Sheet Generator) was a Python-based utility, originally bundled as a standalone PyInstaller binary (see superseded decision below). Its per-frame random-seek extraction made HEVC/4K contact sheets very slow (1m52s–6m42s for a 4×4 grid), and its Pillow-based text rendering did not support system font fallback.

#### Decision
We removed `vcsi` and all Python dependencies entirely. Contact sheets are now generated via a native `ffmpeg` extraction pass (`-hwaccel videotoolbox`, plus `fps=1/interval` for Normal Mode or `-skip_frame nokey` for Fast Mode, writing JPEG `-q:v 3` temporaries) and composited in Swift using CoreGraphics/AppKit (`renderContactSheet`, `NSAttributedString`).

#### Rationale
- **Performance**: Sequential single-pass decoding (Normal Mode, ~2.5–4 min) and especially keyframe-only Fast Mode (<1 second on a 4K60 60s clip) are dramatically faster than vcsi's per-frame seeking.
- **No Python Runtime Anywhere**: Removes the PyInstaller-frozen `vcsi` binary, its packaging step in `build.sh`, and all Python dependencies — simplifying the build and reducing app size.
- **Native Text Rendering**: CoreGraphics/`NSAttributedString` rendering uses system font fallback, addressing limitations of Pillow-based text rendering.
- **Maintainability**: A single ffmpeg invocation plus Swift-side compositing is easier to reason about and debug than shelling out to a frozen third-party Python CLI.

---

### 2a. (Superseded) vcsi was bundled

> **Superseded by Decision 2 above (v2.0.0).** Retained for historical context per project policy.

#### Context
`vcsi` (Video Contact Sheet Generator) is a Python-based utility. Running it natively requires a Python environment, Python packages (`pillow`, `jinja2`, etc.), and proper CLI bindings.

#### Decision
We compile the `vcsi` Python CLI into a standalone, single-executable binary using PyInstaller and place it directly into the application's bundle resources under `Contents/Resources/bin/vcsi`.

#### Rationale
- **No Python Runtime Requirement**: Eliminates the need for end-users to install Python, configure virtualenvs, or manage `pip` dependencies.
- **Simplified Setup**: Out-of-the-box operation. The app works instantly after drag-and-drop once FFmpeg is present.
- **Guaranteed Compatibility**: Freezing `vcsi` locks the internal engine version (v7.0.3), preventing compatibility breakages from upstream package updates.

---

### 3. (Superseded) Monolithic SwiftUI Layout (`main.swift`)

> **Superseded in Phase 1, Stage A (2026-07-18).** The single file grew to 2208 lines and became a bottleneck for the MoviePrint-convergence work in `docs/UI_AUDIT.md`; see Decision 5 below. Retained for historical context per project policy.

#### Context
Modular Swift projects usually separate views, models, and utility files.

#### Decision
We maintain the frontend codebase inside a single `main.swift` file.

#### Rationale
- **Lightweight Compiler Footprint**: Keeps the project easy to compile on any macOS system using a single `swiftc` call without requiring complex Xcode project wrappers.
- **Portable Script-Like Workflow**: Allows easy automation, rapid updates via LLM/agent setups, and simple build scripts (`build.sh`).

---

### 4. (Superseded) Fast Mode (keyframes only) was enabled by default (v2.0.0)

> **Superseded in Phase 3 (2026-07-07).** Fast Mode was removed entirely: the Phase 2 per-frame input-seeking engine made the standard path fast enough (60-min H.264 in ~1 s) that a keyframe-only preview no longer paid for its complexity, and its `-skip_frame nokey` single pass hung on WebM sources lacking cues. Retained for historical context per project policy.

#### Context
Even with the v2.0.0 ffmpeg single-pass engine, Normal Mode's `fps=1/interval` filter requires decoding every frame in the sampled range, which remains slow for long and/or high-fps HEVC sources (~2.5–4 min for a typical 4K clip, several minutes for 240fps slow-motion footage). Loading a video and immediately triggering this full decode made the first preview feel sluggish.

#### Decision
`fastModeKeyframesOnly` defaults to `true`. The initial preview after loading a video uses `-skip_frame nokey -vsync vfr` to extract only keyframes, composited into the requested grid (even-sampling down, or shrinking the row count if fewer keyframes than `rows × columns` exist). A `Fast mode: X of Y keyframes` indicator reports the actual vs. extracted counts. Users can toggle Fast Mode off in the Layout tab to fall back to Normal Mode for an exact, evenly-spaced grid.

#### Rationale
- **Instant First Impression**: A 4K60 60s clip produces a Fast Mode preview in well under a second, versus ~25 seconds in Normal Mode.
- **Opt-in Precision**: Users who need exact, evenly-spaced timestamps or custom timestamps (disabled in Fast Mode) can explicitly switch to Normal Mode.
- **Transparent Trade-offs**: The keyframe-count indicator and UI copy make it clear when the thumbnail count or timestamps are approximate, avoiding silent surprises.

---

### 5. Multi-file SwiftUI layout, split by concern (Phase 1, Stage A — 2026-07-18)

#### Context
`docs/UI_AUDIT.md` identified the single `main.swift` (2208 lines) as the main obstacle to absorbing a MoviePrint-style layout: no per-thumbnail interactivity is feasible while the render pipeline, all app state, and every view live in one file with no separable renderer.

#### Decision
Split into `Models.swift`; `AppState.swift` plus `AppState+Dependencies/Loading/Generation/Sizing.swift` extensions; `Views/` (+ `Tabs/` and `Components/` subdirectories); `AppDelegate.swift`, `FrameSheetApp.swift`, `FontPanelBridge.swift`; `Extensions.swift`; and a standalone `ContactSheetRenderer.swift` with no dependency on `AppState` or any View type. `build.sh` now compiles the full source tree (`find … -name "*.swift"`) instead of naming one entrypoint. This supersedes Decision 3 above.

#### Rationale
- **Unblocks Phase 2/3**: A separable renderer and a per-thumbnail `Thumbnail` model (also introduced in this stage) are prerequisites for any per-thumbnail interactivity or settings growth planned in `docs/UI_AUDIT.md`.
- **No behavior change, provably**: Verified with a byte-for-byte diff harness (fixed thumbnails + fixed params, run against the pre- and post-split renderer) rather than relying on visual inspection alone.
- **Keeps the `swiftc`-only build**: `build.sh` still does a single `swiftc` invocation over multiple files — no Xcode project wrapper introduced, preserving Decision 3's original build-simplicity rationale even though the single-file layout itself is gone.

---

### 6. Sidebar settings panel: single-scroll column instead of tabs (Phase 1, Stage B — 2026-07-18)

#### Context
`docs/UI_AUDIT.md` flagged the Layout/Style/Frames tab switcher as a layout decision that would need to be made before growing the settings panel toward MoviePrint parity (Output/Naming/Experimental sections): MoviePrint's own settings panel is one continuously scrolling column with section dividers, not tabs.

#### Decision
Adopted MoviePrint's single-scroll-column layout. Removed the tab switcher (`TabButton`, `AppState.activeTab`) and concatenated the three former tabs' content directly, in the same order they previously appeared: Grid Dimensions → Output Options → Font → Colors → Visual Elements → Auto Sampling Range, with dividers between each. The Generate/Cancel action area stays pinned outside the `ScrollView`. Sidebar width grew from 180px (160–220 range) to 240px (200–280 range) to fit the denser column.

#### Rationale
- **Matches the convergence target**: Keeps the settings panel structurally aligned with MoviePrint ahead of Phase 2's planned Output/Naming/Experimental additions, which would have needed a 4th tab or this same flattening later anyway.
- **No content reordering**: Preserves the exact Layout → Style → Frames content order, minimizing the chance of behavior or muscle-memory regressions for existing users.
- **No rendering impact**: Confirmed via the same byte-for-byte diff harness from Decision 5 (unaffected, as expected — no rendering code was touched) plus interactive verification of every control.

---

### 7. Output section, filename templating, and the JPEG-alpha policy (Phase 2 — 2026-07-18)

#### Context
Phase 2 (`docs/UI_AUDIT.md` §5) adds MoviePrint-parity output controls: format choice, size presets, filename templating, quick save, and individual-frame export. Two of these needed explicit policy decisions rather than mechanical implementation.

#### Decision
- **Output is its own sidebar section**, appended after Auto Sampling Range; the pre-existing width/height/spacing group was renamed "Size & Spacing" so "Output" unambiguously means file-writing concerns (format, naming, save behavior). Renderer/param names were left unchanged.
- **Filename templating reuses the `{{placeholder}}` syntax** already used by the header renderer, with a deliberately small token set: `{{filename}}`, `{{width}}`, `{{height}}`, `{{columns}}`, `{{rows}}`, `{{date}}` (YYYY-MM-DD). Path separators are stripped from the resolved name so a template cannot escape the target folder. The extension always comes from the format setting, never the template.
- **JPEG + alpha**: JPEG cannot encode an alpha channel. When the format is JPEG and the background has alpha < 1, the app shows a persistent inline warning in the Output section and exports by compositing over the *opaque version of the chosen background color* (not black). Alpha is never silently dropped without the warning, and the format choice is never overridden behind the user's back.
- **Overwrite policy**: "Overwrite existing" defaults to **off**; collisions auto-suffix `_2`, `_3`, … instead of failing or replacing. The save-panel path is exempt (the panel has its own replace confirmation).

#### Rationale
- **One templating syntax**: A second placeholder dialect for filenames would double the user-facing docs and the implementation surface for marginal benefit.
- **Warn + degrade beats block or silently drop**: Blocking JPEG export for translucent backgrounds would make the two settings feel coupled and mysterious; silently dropping alpha would violate user intent. Compositing over the chosen background color is the closest visual match to what the preview shows.
- **Suffix-by-default is the safe default** for a one-click "Save to Movie Folder" that writes next to the user's source files with no dialog.

---

### 8. Hidden-thumbnail re-flow and hidden-state lifetime (Phase 3a — 2026-07-18)

#### Context
Phase 3a made grid cells individually hideable. Two product questions had to be settled explicitly (flagged to the project owner rather than chosen silently, per the task's constraint): how the exported sheet re-flows around hidden cells, and whether hidden state survives regeneration.

#### Decision
- **Re-flow: raster-order skip with row shrink.** Visible cells compact forward in raster order (left→right, top→bottom). The `columns` setting keeps its configured value and the exported row count shrinks to `ceil(visibleCount / columns)` (`ContactSheetRenderer.reflowParams`); the last row may be partially filled. The on-screen grid keeps showing hidden cells dimmed in place so they can be un-hidden.
- **Hidden state resets on regeneration.** Regenerating (sampling/grid/settings changes, new video) rebuilds the `Thumbnail` array with all cells visible. Hidden state is deliberately transient.

#### Rationale
- **Consistency with existing parameters**: `columns` everywhere else is an exact user-set value while row count already derives from content; shrinking rows preserves that meaning. A fixed-dimensions alternative (leaving background holes in the export) was rejected by the project owner.
- **Predictability over cleverness**: carrying hidden state across regeneration by timestamp matching becomes ambiguous the moment sampling settings change (every timestamp shifts). A fresh grid after regeneration is the least surprising behavior; timestamp-keyed persistence remains a possible future decision if a concrete need appears.

---

### 9. Grid keyboard model: navigate all cells, `,`/`.` nudge keys (Phase 3a wrap-up — 2026-07-18)

#### Context
The Phase 3a wrap-up added keyboard support to the thumbnail grid. Two choices needed recording: how arrow navigation treats hidden cells, and which keys drive the per-cell nudge.

#### Decision
- **Arrow navigation traverses ALL displayed cells**, including dimmed hidden ones (owner-approved). The task draft said "hidden cells are skipped, matching the visual layout," but per decision #8 the grid *shows* hidden cells in place — skipping them would contradict the actual visual layout and make keyboard-only unhide impossible.
- **Nudge keys are `,` and `.`** (over the `[`/`]` alternative): they are the unshifted forms of `<`/`>`, mirroring the on-screen chevron buttons, and collide with no existing shortcuts (⌘O/⌘C/⌘S are all command-modified). They are matched by *character* rather than key code so they work across keyboard layouts.
- **Key capture is an `NSEvent` local monitor** (deployment target macOS 11 predates SwiftUI `.onKeyPress`, same availability discipline as the Stage C drag API choice). The monitor passes events through while any text field is being edited (first responder is an `NSTextView` field editor) or command/control/option is held.

#### Rationale
- Reachability beats literalism: a keyboard model where hidden cells can be selected keeps hide/unhide symmetric with the mouse path.
- One mental model for nudge: `,`/`.` ↔ `<`/`>` chevrons.
- A deliberate consequence of the text-field guard: clicking a cell while a sidebar field is focused selects the cell but keys stay with the field until focus leaves it — typing into settings can never trigger grid actions.

---

### 10. Decode-backend routing: AVFoundation primary, ffmpeg fallback (v2.3.0 — 2026-07-18)

#### Context
Through v2.2.0 every frame came from spawned ffmpeg processes, making ffmpeg a hard dependency even for formats macOS decodes natively.

#### Decision
All probing/extraction goes through a `DecodeBackend` protocol. On load, AVFoundation is probed first; the file routes to `FFmpegBackend` only when the asset has no decodable video track (WebM/MKV — and codec/hardware gaps such as AV1 before M3). When the fallback is needed but ffmpeg is missing, the load fails with a message naming the format and suggesting `brew install ffmpeg`. The launch "FFmpeg not found" overlay became a dismissible informational notice; the active backend is logged to the console per load.

#### Rationale
- **ffmpeg becomes optional** for mp4/mov/m4v, unblocking future standalone distribution without bundling ffmpeg (and its GPL/LGPL considerations — see decision #1).
- **Hardware decode**: VideoToolbox roughly halves extraction times (see DEV_LOG measurements) and keeps a resident decoder for per-cell work.
- **Capability-probing beats extension lists**: routing on "does AVFoundation report a decodable track" automatically handles codec-inside-container surprises (an `.mp4` carrying AV1 correctly falls back on M1/M2 and will route natively on M3+).

---

### 11. Exact-time tolerance with bounded per-frame retry (v2.3.0 — 2026-07-18)

#### Context
`AVAssetImageGenerator` was configured with zero time tolerance (exports must be timestamp-accurate; coarse tolerance is a Phase 3b scrub concern). Real-world testing surfaced H.264 streams (ToS sample; ffmpeg logs `mmco: unref short failure` for it) where scattered exact-time requests hard-fail with "Cannot Decode" — 9 of 20 frames on the sample — which the renderer would silently paint as dark filler cells.

#### Decision
Zero tolerance remains the first attempt for both batch and nudge extraction. A frame that fails exactly is retried once with a bounded ±0.5s tolerance; the actual decoded time is propagated into the `Thumbnail`, so on-image timestamps and the nudge state reflect the frame really shown. Every retry is logged to the console. Whole-file fallback to ffmpeg on a single frame failure was rejected (owner decision): it would discard the hardware-decode win and reintroduce the ffmpeg dependency for slightly non-conformant but otherwise fine native files.

#### Rationale
- **Zero missing cells** while staying exact wherever the stream allows it.
- **Truthful labels over pretty labels**: a snapped frame shows its real time (observed drift ≤0.3s on the sample).
- The failure is deterministic per stream+time, so retried outputs remain byte-stable for the baseline policy.

---

### 12. Per-backend verification baselines in tests/baselines/ (v2.3.0 — 2026-07-18)

#### Context
Backend changes legitimately change pixels (different scaler/color pipeline than ffmpeg), so the single Phase-1 byte-baseline could no longer cover both paths. The owner approved a root-level `tests/` directory (updating the src-layout root inventory from decision-era 2026-07-18-05).

#### Decision
- **ffmpeg path**: the Phase-1 render baseline stays authoritative; the renderer harness must remain byte-identical, and the WebM smoke tests (hang-regression timeout, duration-less packet scan) must pass unchanged through the fallback route.
- **AVFoundation path**: default-settings outputs for the local sample videos are committed under `tests/baselines/` and byte-compared by the smoke suite, which also asserts deterministic reruns and that every cell is backed by a real frame file. Baselines are machine-anchored (hardware decoders can differ across chips); regeneration requires a DEV_LOG entry.

> **No longer applies (v3 skeleton, 2026-11-02):** the v2 renderer and `tests/baselines/` were removed with the v2 sources. v3 checks decoding with `swift test`: the decode tests make short clips with the system ffmpeg whose frames encode their own number, and assert that each backend returns the requested frame.

---

### 13. Debug builds sign with Developer ID; version derives from git tags (v2.3.1 — 2026-07-18)

#### Context
Debug builds were ad-hoc signed, and every rebuild produced a different code signature. macOS TCC ties permission grants to bundle ID + code signature (designated requirement), so grants like Files-and-Folders folder access would be invalidated on each rebuild — the same class of issue as Accessibility-API tools hit. Separately, `CFBundleShortVersionString` was a hardcoded script variable stuck at 2.0.0 while v2.1.0–v2.3.0 shipped, and the bundle identifier still carried the Antigravity-era `com.gemini.` prefix.

#### Decision
- **Bundle identifier** is `com.kni.FrameSheet` (old preferences domain orphaned intentionally; no migration).
- **Version from tags**: `build.sh` derives `CFBundleShortVersionString` from `git describe --tags --abbrev=0` and `CFBundleVersion` from `git rev-list --count HEAD` (release procedure in `docs/task-workflow.md`: tag first, then build).
- **One signing identity for all builds**: debug and release builds sign with the Developer ID Application certificate with hardened runtime (`--options runtime`); `FRAMESHEET_SIGN_IDENTITY` overrides auto-detection, and machines without the identity fall back to ad-hoc with an explicit warning. **Notarization/stapling stays release-only** (currently manual; credentials not yet registered). The `~/Applications` debug-install rule is orthogonal and unchanged.

#### Rationale
- **Stable TCC grants**: an identical certificate + bundle ID yields a stable designated requirement, so permission grants survive rebuilds — relevant to FrameSheet mainly for folder-scoped file access.
- **Tags as the single source of version truth** removes a manual per-release edit that had already drifted three releases.
- **Fallback over failure**: contributors without the certificate still get working (ad-hoc) builds, with the trade-off surfaced in the build log.

---

## v3 decisions (2026-11-01)

The owner decided these on 2026-11-01, after research by a gateway session
(MoviePrint v0.2.23 source and help pages, PyMoviePrint, Apple documentation).
Decisions 1–13 above describe v2 and stay as history; where a v3 decision
contradicts one of them, v3 wins from v3.0.0 on.

### 14. v3 is a rebuild that reproduces MoviePrint v0.2.23 for Apple Silicon

#### Context
MoviePrint (fakob/MoviePrint_v004, MIT) is no longer developed; its last
release, v0.2.23, crashes under Rosetta 2 on Apple Silicon (0.2.12 and earlier
still run, without face features). FrameSheet v2 is "settings → regenerate one
flattened image", while MoviePrint is a document editor: movies → sheets →
thumbs/scenes with persistent per-thumb state, undo, and many movies at once.
Extending v2 toward that would replace nearly all of it.

#### Decision
- FrameSheet v3 reproduces MoviePrint v0.2.23, its UI layout and interactions
  included, as a native Apple Silicon app.
- Same repository (`kni927/FrameSheet`), new major version v3, rebuilt rather
  than extended. v2 stays reachable through its tags and Git history.
- MoviePrint's code may be ported where useful; ported code keeps its MIT
  notice under `docs/licenses/`. PyMoviePrint has no LICENSE file: its ideas
  may be used, never its code.

### 15. v3 targets macOS 27 and Apple Silicon only

#### Decision
Minimum macOS 27, arm64 only, built with Xcode 27. Every Mac the owner uses
runs macOS 27.

#### Rationale
Allows current SwiftUI (reorderable grids, document APIs), the Swift Vision
API, and Liquid Glass without availability branches.

### 16. Face features: detection only (Apple Vision) first

#### Decision
- Lv1, first: Apple Vision face rectangles — face count, size and position,
  face sheets, sort and filter by count and size, rectangle overlay.
- Lv2 (same-person grouping: unique faces, occurrence, FIND), for example
  ONNX Runtime with YuNet + SFace models: to be considered later.
- Lv3 (age and gender): not planned.

#### Rationale
Vision has no public face-identity embedding, so grouping needs an extra
runtime and models; age and gender add a model for low accuracy and little
value. Face analysis sits behind a protocol so Lv2 can be added without
changing the UI.

### 17. ffmpeg stays an external tool; discovery is fixed

#### Decision
Decision 1 still holds in v3: ffmpeg/ffprobe are not bundled and libav* is not
linked. Discovery must also find installs outside Homebrew (the v2
`findCommandPath` only checks two prefixes and a non-login shell's PATH).

### 18. v3 look: kni Design System, dark only; guide layout dropped

#### Decision
- The app's content (movie list, grid and timeline, settings panel, player
  view) uses the owner's kni Design System (Catppuccin Mocha base) for colour,
  type and spacing, with tokens taken from the design system itself. The
  appearance is fixed to dark.
- System window chrome stays Liquid Glass (the Xcode 27 SDK no longer lets an
  app opt out).
- MoviePrint's own look (dark Semantic UI, orange accent) is not copied; only
  its layout and interactions are.
- MoviePrint's guide layout (padding the print to paper aspect ratios) is not
  part of v3. A fixed output aspect ratio, if wanted later, would be a simple
  output option.

### 19. v3 build: Swift 6 package with a tested core library

#### Decision
v3 is a Swift Package: a core library (models, layout maths, shot detection,
naming, EDL, PNG chunk I/O, MoviePrint import) with unit tests run by
`swift test`, and an app target. `build.sh` keeps assembling and signing the
`.app` with the tag-derived version (decision 13). Swift 6 language mode with
strict concurrency; SwiftUI, with AppKit only where SwiftUI falls short.

#### Rationale
The editor logic (scene lists, timeline layout, naming, import/export) is
pure and worth testing; a package is also what ONNX Runtime needs if face Lv2
comes. Supersedes the swiftc-only build for v3.

### 20. v3 is built on `main`; v2 stays at its tags

#### Decision
v3 work lands on `main` from the start, following the Git Workflow in
`AGENTS.md`. The v2 sources are removed when the v3 skeleton lands; v2 stays
reachable at tag v2.3.1 and in history. No further v2 releases are planned.

### 21. v3.0.0 scope: MoviePrint 0.2.23 minus the dropped features

#### Decision
The first v3 release covers MoviePrint 0.2.23 — interval, shot and face
sheets; grid and timeline views; hover overlay, scrub, cut and merge; player
view; export and import (PNG with embedded data, JSON, EDL); Save All — except
guide layout, face grouping (Lv2) and age/gender (Lv3). Details are in
`docs/V3_SPEC.md`.

### 22. Measurements: a quick check by default; the script runs outside the sandbox (2026-11-02)

#### Decision
- After implementation work, measurement is a short regression check
  (`tools/spike/run-all.sh quick`: the settings v3 uses, one run each, a few
  minutes). The full battery (3 runs each, about 2 h) reruns only when the
  owner asks, for example for new kinds of input or a different Mac.
- `tools/spike/run-all.sh` is listed in `.claude/settings.json`
  `sandbox.excludedCommands` (owner approved, 2026-11-02).

#### Rationale
The spike's full battery took about 1 h 40 min and mostly re-checked settings
already chosen. Inside the sandbox VideoToolbox cannot decode and Vision sees
no GPU, so every run needed a bypass dialog.

### 23. v3 window layout and type after the legibility pass (2026-11-03)

#### Decision
The owner decided during T03b (in the TF's chat):
- Type uses the system fonts (SF Pro, SF Mono, SF Pro Condensed) at the kni
  Design System's sizes; the bundled IBM Plex is dropped.
- The sheet toolbar sits in the window toolbar next to the title; Save
  MoviePrint becomes a download button there, and MoviePrint's footer is not
  reproduced.
- App-wide settings (thumbnail cache, ffmpeg) move to a Settings window (⌘,);
  the right panel keeps the per-sheet sections, divided by lines.
- Still open: grid controls in the toolbar with no right panel at all.

#### Rationale
Side by side with MoviePrint the T03 UI was hard to read; system fonts render
best on macOS and need no bundling.

### 24. Sheets are named `Sheet-N`; the naming token is `[SN]` (2026-11-03)

#### Decision
New sheets are named `Sheet-1`, `Sheet-2`, … per movie (capital S), and the
file-name token for the sheet name is `[SN]`, so the default file name is
`[MN].[ME]-[SN]`. `[MPN]` stays accepted as an alias, and names in imported
MoviePrint files are kept as they are. The Show player view button comes with
the player view (T06), not earlier as a disabled control.

#### Rationale
"MoviePrint" is the original app's brand and means nothing to FrameSheet
users.

### 25. Frames AVFoundation cannot decode exactly: three steps per frame (2026-11-03)

#### Context
In open-GOP H.264 files whose sync samples are non-IDR I frames, AVFoundation
decodes only part of the frames exactly (KNOWN_ISSUES 5). Decision 10 routes a
whole file to ffmpeg only when AVFoundation has no decodable video track, so
such a file stays on AVFoundation.

#### Decision
Each requested frame of an open file goes through up to three steps, one at a
time inside `DecodeGate`:
1. the exact `AVAssetImageGenerator` request;
2. if it fails or returns a later frame, an `AVAssetReader` read from just
   before the previous sync sample, keeping only the target frame (always on;
   it succeeds where the previous keyframe is IDR or the previous GOP has no
   leading frames);
3. if that fails, a per-frame ffmpeg fetch, when the Settings option "Fetch
   exact frames with ffmpeg" is on (default on) and ffmpeg is found;
   otherwise the ±0.5 s retry, whose frame is shown with its real number and a
   marker (decision 11).
A scrubbed frame that cannot be decoded exactly is not stored; the thumb keeps
its frame and a toast says why. Saving uses the same path. Decision 10 stands:
this concerns frames of a file already open, not routing the file.

#### Rationale
Measured on an open-GOP file from the owner's files (2026-11-03): the
generator decoded 11 of 63 sampled frames exactly; step 2 recovered 25 of the
52 others at about 20–27 ms per frame (13–18 ms to fail); ffmpeg recovered all
at about 93 ms (640 px) to 387 ms (1920 px). Step 2 keeps hardware decoding
and needs no ffmpeg, so it goes first; ffmpeg covers the rest. Frames the
generator decodes exactly never reach step 2, so normal files cost nothing
extra (owner approved the three steps in TF #01's chat).

### 26. Movie transforms: applied once in the decode path; a change clears stored scans (2026-11-04)

#### Context
v3.0.0 includes MoviePrint's per-movie rotation, cropping and aspect ratio
(0.2.18–0.2.19, decision 21). Every consumer must show the same image:
thumbs, scrub, player, scans, saved prints and frames. The shot and face
scan caches hold values computed from the frames as they were scanned.

#### Decision
- Rotation (0/90/180/270, clockwise) is applied to the upright frame first,
  then the crop, in the rotated frame's pixels, as MoviePrint does. The math
  is in `FrameSheetCore` (`MovieTransformMath.swift`); `TransformedBackend`
  wraps each movie's backend in `AppModel.backend(for:)`, so every decoded
  image is transformed in one place. Scans apply the same transform in
  `ScanFrameConverter` (vImage rotation and a view into the crop).
- The aspect ratio does not change the decoded image: thumbs, scrub and the
  player are drawn to it (stretched, as MoviePrint does), and saved
  individual thumbs and frames are scaled to it.
- Player video (AVPlayer's layer and ffmpeg playback's frames) stays
  untransformed and is turned, moved and clipped in the view
  (`MovieTransform.playbackPlacement`); paused stills are decoded through
  the transformed backend.
- A stored scan does not record the transform. When a movie's rotation or
  crop changes (the dialog, undo or redo), the app clears its cached images,
  player frames and stored shot and face scans, as Clear Stored Scans does;
  the dialog says so when the movie has stored scans, and it cannot be opened
  while a scan runs. Sheets keep their thumbs and scenes; face boxes already
  on a faces sheet keep the old coordinates until it is scanned again: a
  faces sheet records the transform its faces were found with, says so in a
  banner when the movie's rotation or crop differs, and Apply rescans it.
- MoviePrint's 2.21:1 preset value 0.5525 (1.81:1) is corrected to 0.4525.

#### Rationale
One wrapper in the decode path keeps every consumer consistent without
touching each one. Clearing scans on a change is simpler than versioning the
cache by transform and cannot show scenes or faces from other frames; a
rescan of a 2 h film takes minutes, and transforms are set rarely, usually
before scanning.

### 27. Menus for every command; customizable toolbar; faces on a fixed frame grid (2026-11-05)

#### Decision
The owner decided in FrameSheet TF #03's chat:
- Every toolbar command is also in the File, Edit, View or new Sheet menu,
  most with a ⌘ shortcut; the single-letter keys of §8 stay.
- The toolbar is customizable (one item per control, a short default set);
  controls that do not apply are disabled, not hidden.
- Face detection settings move from the right panel to a Sheet → Face
  Detection… window.
- Faces sampled scopes take the multiples of 10 or 100 between the first and
  last thumb, instead of MoviePrint's per-sheet spread.

#### Rationale
Menus make every command findable and give it a shortcut; a customizable
toolbar keeps the window uncluttered and fixed the overflow that listed only
one control. Checked from the owner's scan log: an interval sheet's scope
(213 frames) and a shot sheet's (195) shared no frame under the per-sheet
spread, so each new faces sheet rescanned; a fixed grid lets sheets reuse
analyzed frames.
