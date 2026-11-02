# TASK: v3 T03 — interval sheet editing

From: FrameSheet HQ (via handoff-relay), 2026-11-02.

The owner chose this order for v3.0.0 (2026-11-02): T03 interval editing → T04 Save MoviePrint and import → T05 shot scan and timeline → T06 player view → T07 faces Lv1 → T08 transforms, Save All, polish.

## Background

The skeleton (`docs/tasks/2026-11-02-02-v3-skeleton.md`) shows a default interval sheet. MoviePrint's value is editing that sheet: choosing frames by hovering, scrubbing, inserting, hiding, reordering and expanding, with undo. This TASK makes interval sheets editable as `docs/V3_SPEC.md` describes, and gives the app the kni Design System's type, spacing and radius.

## Goal

On an interval sheet the owner can do everything §5, §7 and the grid parts of §4, §6 and §8 describe, with undo/redo, and the app looks like the kni Design System.

## Scope

### In scope

1. **Core (tested with `swift test`):** undo/redo of library and sheet edits, 50 steps, not persisted (§3); interval operations — change thumb, insert before/after (frame midway to the neighbour), hide/show, reorder, IN/OUT with recapture of the same count between them, and Option variant "hide all before/after" (§7); scrub mapping from pointer position to frame between the neighbours, with the Shift, Option and Control variants and the first/last-thumb rule (§7); Expand → child interval sheet of 16 thumbs inside the thumb's range, named "Sequence a - b", with `parentSheetId` (§5, §3); optimise grid layout (columns = ceil(√n)); stats line text (§6); frame info text (4-digit frames, HH:MM:SS:FF timecode).
2. **Settings panel, grid parts (§6):** stats line; Columns 1–20 (live); Change thumb count → Rows 1–20 with the overwrite warning and Apply; Styling: grid margin, rounded corners, show hidden thumbs; Frame info: frames / timecode / hide, font colour, background colour (Catppuccin presets plus any colour and transparent), position (7), size, margin; Thumbnail cache limit. Header, output, naming, face, timeline and experimental sections come with their TASKs.
3. **Movie list (§4):** sheets under each movie with icon, name and type label; sheet menu: Rename (inline), Duplicate, Delete (Switch view and Convert to interval appear but stay disabled until T05); movie menu: Open file location, Remove; "Movie is missing" with Locate.
4. **Floating toolbar (§4), the parts that work on interval sheets:** Back to parent; Add interval sheet (2×2 … 6×6); Duplicate; Zoom out / Fit / Zoom in (0.25 … 8, default 1); Show hidden thumbs; cycle frame info; Optimise grid layout.
5. **Thumb interactions (§7):** hover overlay with its width thresholds and dimming (EXPAND, Hide/show, IN, OUT, Insert before/after; Save thumb comes in T04); scrub overlay (left neighbour, live frame, right neighbour, CHANGE TO / ADD BEFORE / ADD AFTER, Cancel bar, release confirms); click selects; drag reorder (try SwiftUI `.reorderable()` with `.reorderContainer(for:)` on the grid first, macOS 27; fall back to AppKit only if it falls short).
6. **Keyboard (§8), grid parts:** 1 / 3 toggle the sidebars; A; ⇧⌥←/→ previous/next thumb; Return change/add on the selected thumb (opens the scrub for it); ⌘Z / ⇧⌘Z; ⌘0 / ⌘= / ⌘−; ⌃⌘F; keys ignored while a text field has focus.
7. **Look (§11):** kni Design System tokens — read `project/tokens.json` and `project/README.md` of https://claude.ai/artifact/K9U2uB7ap59mtzLjPi5FyT with the Artifact tool (Mocha colours, type styles caption/body-sm/body/heading-2/heading-1, spacing space-1…space-12, radius sm/md/lg). Fonts: IBM Plex Sans and Plex Mono bundled in the app (OFL 1.1, license under `docs/licenses/`), Hiragino Sans as the Japanese fallback. Surfaces base → mantle → crust with 1 px borders, no shadows or gradients; accent (mauve) used sparingly; system Liquid Glass toolbar tinted with the accent.

### Out of scope

- Saving or exporting anything (T04), the shot scan and timeline (T05), the player view and double-click (T06), faces (T07), transforms (T08).
- Version change or tag.

### Parts

1. Core operations, undo and tests.
2. Settings panel, movie list menus, toolbar.
3. Hover overlay, scrub, reorder, keyboard.
4. kni tokens and fonts; docs.

## Implementation notes

- Keep the operations in `FrameSheetCore` and the views thin; every user-visible edit goes through one undoable path.
- Scrub frames come from the thumbnail cache and `AVAssetImageGenerator` at display size; keep it responsive (request coalescing, a tolerance during the drag is fine, but the confirmed frame is exact).
- MoviePrint references for behaviour: `ThumbGrid.js`, `Scrub.js`, `actions/index.js`, `utils.js` in fakob/MoviePrint_v004 (MIT; keep the notice when porting).
- Measurement is not needed for this TASK (no decode or scan changes); if decode code changes, run `tools/spike/run-all.sh quick` once.
- Public repository: no Mac model, chip, hostname, user name or personal file names in committed files.
- Update `docs/ARCHITECTURE.md`, `docs/STATUS.md` and `README.md` (usage) as the work changes them.
- Builds and tests go through `scripts/check.sh` (sandbox-excluded; run it as its own command with no redirection appended), and follow the "Commands and sandbox" counting rule in `~/.claude/CLAUDE.md`.

## Verification

- `scripts/check.sh install` passes; new tests cover each core operation in scope 1, including undo/redo across them and the scrub mapping variants.
- With a movie from the owner's files, manually: each hover button, scrub with and without Shift/Option/Control, Cancel bar, reorder, Expand and Back to parent, Rename/Duplicate/Delete sheet, Add interval sheet presets, columns live and rows with Apply, zoom steps and Fit, frame info modes and position, undo/redo of a mixed sequence, keyboard shortcuts, a removed movie file showing "Movie is missing" and Locate.
- The window uses the kni colours, Plex fonts and spacing; put a screenshot in Google Drive `AI/Handoff/FrameSheet/` and name it in the report (never in the repository).
- `git status` clean after the last commit.

## Progress

- Last completed step: all four parts, owner checks, docs.
- Current partial state: none.
- Exact next step: none (archived).

## Implementation Result

**Status:** Completed with follow-up issues

### Changes

- Part 1 (ad058a5): `Sources/FrameSheetCore/Editing/` — `EditHistory`/`EditableLibrary` (50-step undo/redo, settings kept), `IntervalEditing` (change, insert midway, hide/show, hide all before/after, reorder, IN/OUT recapture, columns, Change thumb count, optimise grid, add interval sheet presets, Expand into "Sequence a - b" with `parentSheetId`, duplicate/rename/delete sheet, remove/relink movie, interval scenes), `Scrub` (pointer → frame with Shift/Option/Control and the first/last-thumb rule, CHANGE TO / ADD BEFORE / ADD AFTER), `GridLayout` (optimised columns, stats line, zoom steps, frame info text and size). Ported from MoviePrint (`getScrubFrameNumber`, `createSceneArray`, `onAddThumbClick`, `onExpandClick`, `onInPointClick`/`onOutPointClick`, `onHideBefore`/`onHideAfter`). Settings gained the frame info colour, background, position, size and margin.
- Parts 2–4 (d5be27a): `AppModel` over an `EditableLibrary` with one undoable `edit` path; settings panel (grid stats, columns live with one undo step per drag, Change thumb count with warning and Apply, styling, frame info, thumbnail cache, ffmpeg); movie list context menus (Rename inline, Duplicate, Delete, Switch view / Convert disabled, Open file location, Remove, Movie is missing + Locate); floating toolbar (Back to parent, Add interval sheet 2×2…6×6, Duplicate, zoom 0.25…8 / Fit, show hidden, cycle frame info, optimise); hover overlay (100/160 pt thresholds, dimming), scrub overlay with coalesced live decode and Cancel bar, drag reorder, keyboard (1, 3, A, ⇧⌥←/→, Return scrub, ⌘Z/⇧⌘Z, ⌘0/⌘=/⌘−); kni Design System tokens in `Theme.swift`, IBM Plex Sans/Mono bundled from `assets/fonts` (OFL, `docs/licenses/IBM-Plex-LICENSE`), `build.sh` copies them with `ATSApplicationFontsPath`. `.reorderable()` exists in the macOS 27 SDK but needs a container layout; the absolutely positioned grid uses `.draggable`/`.dropDestination` instead.
- Additions over MoviePrint, from the owner's checks: IN/OUT read "◀ HIDE" / "HIDE ▶" while ⌥ is held; tooltips on every hover button and toolbar item say what the control does.
- c621994: `scripts/check.sh install` added to `sandbox.excludedCommands` and `CLAUDE.md` (owner approved in chat).

Bugs found and fixed:
- AVFoundation batch results whose requested time matched no request were dropped, leaving thumbs blank (719bc5c); now decoded one by one.
- Exact-time frames were renamed from the decoded timestamp, which can be a frame off; now the requested frame is kept (past-the-end clamps to the last frame) (719bc5c).
- Together with the new reload-on-evict path these caused a redraw/decode loop, likely behind a forced restart of the Mac during testing; images are now cached under the requested frame too and reloads are throttled (d5be27a).
- Hover dimming never fired (two stacked `onHover`), EXPAND did not dim the other thumbs as in MoviePrint, ⌥-click was hard to see, the scrub handle lost its drag to the thumb's reorder drag (now starts on press; a quick click keeps the scrub open as MoviePrint's trigger time does), and a thumb-wide tooltip hid the buttons' tooltips (all d5be27a).

### Verification

- Build: `scripts/check.sh install` — 58 tests in 13 suites pass; `build/` holds only `FrameSheet.app` and the zip; installed and launched from `~/Applications`.
- Automated verification: new tests for every core operation in scope 1 (`EditingTests`, `ThumbNavigationTests`), undo/redo across a mixed sequence, the 50-step limit, and all scrub mapping variants.
- Manual verification (computer use): kni colours, Plex fonts and cards; frame info frames/timecode; zoom 200 % and Fit; duplicate sheet and undo; Change thumb count with Apply; optimise grid; undo back to 16; ⇧⌥→ selection; keyboard scrub and confirm; blank thumbs fixed after the fix. Screenshot: Google Drive `AI/Handoff/FrameSheet/2026-11-02-t03-kni-look.jpg`.
- Manual verification (owner): every hover button, dimming for IN/OUT/Hide/EXPAND, ⌥ HIDE, Expand and Back to parent, mouse scrub with ⇧/⌥, drag reorder, redraw loop gone.
- Measurement: `tools/spike/run-all.sh quick` once after the decode change (H.264 720 px BGRA 714 fps, combined 654 fps, unchanged from the spike; AVFoundation items fail on MKV as expected).
- Not performed: Rename/Delete sheet and Locate for a missing movie by the owner, ⌃⌘F, frame info position/colour combinations, Columns slider undo, ⌃ scrub.

### Remaining Issues

- The v3 UI is still hard to read next to MoviePrint (owner); detailed UI changes are a later TASK.
- `docs/KNOWN_ISSUES.md` 4 (scrub overlay cramped in small windows) and 5 (⌘Z in the rename field).
- `tools/spike/run-all.sh` with arguments runs sandboxed (exclusions match exact strings).

### Follow-up Suggestions

- A UI pass against MoviePrint side by side (owner's request), keeping tooltips on every control.
- Consider replacing the offset grid with a custom `Layout` to use `.reorderable()`.
