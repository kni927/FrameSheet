# TASK: v3 T03b — UI legibility pass

From: FrameSheet HQ (via handoff-relay), 2026-11-02. The owner chose (2026-11-02) to make the UI readable before T04. Builds go through `scripts/check.sh install` spelled exactly so; follow the "Commands and sandbox" counting rule.

## Background

After T03 the owner found the v3 UI hard to read next to MoviePrint. Later TASKs add many controls, so the base (type sizes, contrast, spacing, density, overlays) should be right first. Your T03 report lists two related issues: KNOWN_ISSUES 4 (scrub overlay cramped in a small window) and 5 (⌘Z in the rename field undoes the library).

## Goal

The owner finds the movie list, grid, overlays, toolbar and settings panel easy to read, while staying within the kni Design System and MoviePrint's layout.

## Scope

### In scope

1. **Find out what is hard to read, first.** Ask the owner in one AskUserQuestion round (with a fresh screenshot of the current app at a normal window size) which parts are hard to read and why (size, contrast, density, alignment, labels, icons). MoviePrint's screenshots on movieprint.org/help and the GitHub README may serve as the comparison. Write the answers into `TASK.md` Progress before changing anything.
2. **Fix those parts** within the kni tokens: type styles (raise sizes where the owner asks; body 15 px, body-sm 13 px, caption 12 px are the minimums for text the owner must read), `text` vs `text-muted` (muted only for secondary information), `border-control` around controls, focus ring, spacing steps, consistent alignment in the settings panel (label column, value column), readable overlay text on thumbs (backdrop behind hover buttons and frame info), icon size and stroke.
3. **KNOWN_ISSUES 4 and 5:** the scrub overlay fits in a small window (scale or reposition); ⌘Z and ⇧⌘Z in a text field act on the text, not on the library.
4. Keep tooltips on every control; add any that are missing.

### Out of scope

- New features, export (T04) and later TASKs; changing the kni Design System itself (if a token seems wrong for a desktop app, report it to the HQ instead).

### Parts

1. Owner's findings recorded.
2. Fixes, with before/after screenshots.
3. KNOWN_ISSUES 4 and 5; docs.

## Implementation notes

- Measure contrast against the token pairs the design system states; do not invent colours.
- Prefer changing the theme and shared view styles over per-view tweaks, so later TASKs inherit the result.
- Put before/after screenshots in Google Drive `AI/Handoff/FrameSheet/` (never in the repository) and name them in the report.
- Since 2026-11-03 the owner is asked in prose with a recommendation, not with the AskUserQuestion dialog (`~/.claude/CLAUDE.md`, `docs/sessions.md`); item 1 follows that.

## Verification

- `scripts/check.sh install` passes.
- The owner confirms, item by item, that each finding from part 1 is resolved (record their answer in the archive).
- Scrub overlay usable at the smallest window size; ⌘Z in the rename field undoes typing only.
- `git status` clean after the last commit.

## Progress

- Last completed step: all six owner rounds implemented and confirmed; docs updated; archived (2026-11-03).

### Owner's findings (2026-11-03, against MoviePrint side by side)

Type and look
- MoviePrint's type is very small and condensed because it shows a lot; FrameSheet need not copy that.
- The system font (SF) may be enough; bundling IBM Plex Sans may be unnecessary.
- Tooltips are too wordy: cut them down hard.
- Right panel: separate sections with lines, not rounded cards.
- Colour swatches: only a few plus a free choice; the background colour needs an opacity setting.

Toolbar and window
- No header (to be clarified: the print header or a window header).
- Put the sheet toolbar next to the window title (not as in MoviePrint), small icons.
- Fit should be an icon (broken square with vertical/horizontal arrows), not text.
- Frame info icon: "123" rather than "#".
- No Show player view button.
- The + in the title bar works; in "…", Import is disabled and Clear movie list works (as intended).
- Footer is not needed; replace Save MoviePrint with a download button in the toolbar.
- "MoviePrint" as a name means nothing to users; use plain names such as screenshot-1.

Thumbs
- Hover buttons are small, but readable thanks to their backdrop.
- Scrub handle: an icon like <|> rather than the double arrow.
- MoviePrint: hover over the thumb shows the buttons in faint white, hover over a button makes it solid white, large condensed text. Not the design system, but the owner prefers it.
- Frame info: size is proportional to the thumb; the owner wants to set its font and size (MoviePrint has this).

Settings
- No settings window; MoviePrint puts everything in the right panel and it gets too tall.
- Direction (undecided): simple things (grid) in the panel, detailed ones in a settings window; at least the thumbnail cache and ffmpeg move there. Alternative: grid controls in the toolbar and no right panel.
- If the panel stays, its toggle icon should sit on the left side of its area.

Questions from the owner
- Can the timeline view be done now? → No: T05 (spec). Interval-only timeline would be a new feature.

### Decisions (owner, 2026-11-03)

- Fonts: SF Pro, SF Mono and SF Pro Condensed (system); drop the bundled IBM Plex. The owner suggests this as the default for apps (design-system question → HQ).
- In T03b: shorter tooltips; right panel sections divided by lines; fewer swatches plus a free choice, background opacity; Fit as an icon; frame info icon "123"; scrub handle "<|>"; MoviePrint-style hover buttons (faint white over the thumb, solid white over the button, larger condensed text); frame info font and size settings; movie list wrapping and truncation; KNOWN_ISSUES 4 and 5.
- Layout in T03b: sheet toolbar next to the window title (small icons); no footer (stats move to the right panel); a Settings window (⌘,) with the thumbnail cache and ffmpeg; the right panel keeps grid, styling and frame info; its toggle sits on the panel's left side.
- Pending, not dropped: grid controls in the toolbar and no right panel.
- "Header" = the print header (§5.2) → T04.
### Owner's second round (2026-11-03, after the first fixes)

- Redraw loop gone in a quick try (after the DecodeGate and pinning fixes).
- Concurrent decodes: the owner asked about 2–3; kept at 1 for now (one AVD engine on M1, panics), to be measured with the spike before raising.
- Fonts mostly fine. Section titles (Grid, Styling, …) larger and bolder; other text lighter.
- Stats as two lines: large numbers on top ("4  5  19"), small labels under them ("columns  rows  count"); no "×" or "=" (4 × 5 ≠ 19 with hidden thumbs).
- Rows slider always shown and usable (no separate Change thumb count step).
- Rounded corners: adjustable amount, not just on/off.
- Frame info: free choice of font family.
- Margin: separate horizontal and vertical, with a link to move them together.
- Window toolbar: "FrameSheet" text at the far left.
- Toolbar icons: capsule backgrounds too round (Liquid Glass default); remove or square them if possible.
- Right panel: full height like the left sidebar, toggle button at the top.

### Owner's third round (2026-11-03)

- OK: section titles bold/large, rest light; rows slider with ⌘Z; corner radius, separate margins, free font choice; tooltips now short.
- Rows should change the layout as soon as it moves, like Columns.
- Frame info: separate horizontal/vertical margins (with link), like Styling.
- Toolbar: a little space left of "FrameSheet"; the movie-list toggle right after the "FrameSheet" text; the right-panel toggle always at the far right (the panel's own hide button left a dead button behind); a gap between the text and the icons; slightly larger icons.
- Tooltip font larger: not possible with `.help` (system-drawn); a custom tooltip is a later decision.
- Hover overlay: "‹|›" larger; overlay text sized relative to the thumb, not absolute; a slight enlargement of the button under the pointer.
- Movie list: poster left; name, then folder, then duration · W×H · size (two detail lines).
- Save (MoviePrint's Save) = export the sheet as one still image → T04.
- Decoders per chip: Ultra chips have two media engines; the gate stays at 1 until measured per machine.

### Owner's fourth round (2026-11-03)

- Rows like Columns: rearrange only (columns follow from rows), the thumb count stays.
- Bring back "Change thumb count": only that reloads with a new count.
- Toolbar: space between "FrameSheet" and the movie-list toggle; the panel toggle right after Optimize grid with a small gap (not at the far right); "Optimize" spelling; all icons get the subtle background the panel toggle has.
- Movie list: folder and the duration · W×H · size line wrap under the poster for more room.

### Owner's fifth round (2026-11-03)

- OK: rows rearrange; toolbar spacing and panel toggle.
- "Change thumb count" is itself the Apply action (a button); its tooltip says "Replaces N thumbs with M; ⌘Z undoes".
- New toolbar buttons left of Fit: Fit height (up/down arrows) when the sheet has space above and below, Fit width (left/right arrows) when it has space at the sides.
- Toolbar: where no gap is intended, no space between icon backgrounds (close up or fill).
- Movie list folder: the full path filling the line ("/Users/…/sample-video"), middle-truncated.
- Custom-drawn tooltips: not wanted (MoviePrint draws its own; not needed).
- Concurrent decodes: not decided at 1; pending for the future (measure per machine; Ultra chips have two media engines).

### Owner's sixth round (2026-11-03)

- OK: Fit height / Fit width, grouped icon backgrounds, full folder path.
- Movie list path and duration lines: same size, SF Pro Condensed, lighter weight.
- Thumb count (option A, owner): no Thumbs slider; Columns rearranges live (count unchanged); Rows only sets the target rows — more rows show empty placeholder rows, no reload; a "Replace" button recaptures columns × rows thumbs (one undo step), enabled when that differs from the current count; tooltip "Replace 17 thumbs with 5 × 5 = 25; ⌘Z undoes". Rows below the current need leave the layout as is (the tooltip shows the smaller count).

- To HQ (spec changes): SF fonts; plain sheet names (e.g. screenshot-1) instead of MoviePrint-N; Save as a download button in the toolbar (T04); a player view button with T06.

### Owner's seventh round (2026-11-03)

- OK: Replace enabled at rest when the last row is partly filled.
- Duration line back to the regular weight (the path line stays condensed).
- Fewer target rows dim the thumbs past columns × rows (a preview of how many go; Replace recaptures evenly).
- "UI is fine for now." Both last changes confirmed.

## Implementation Result

- Status: Completed with follow-up issues

### Changes

- Fonts: system SF Pro, SF Pro Condensed and SF Mono; the bundled IBM Plex, its license and the build.sh font step removed (owner decision).
- Window toolbar: "FrameSheet" title and movie-list toggle at the left; sheet tools (back, add interval sheet, duplicate, zoom out, Fit height, Fit width, Fit, zoom in, show hidden, frame info, Optimize grid, panel toggle) as grouped icons with one shared quiet background, Liquid Glass capsules hidden. Floating toolbar and footer removed.
- Settings window (⌘,) with the thumbnail cache and ffmpeg; the right panel (full height, line-divided sections) keeps Grid, Styling and Frame info.
- Grid: two-line stats; Columns rearranges live; Rows sets a target (placeholder rows / dimmed thumbs), Replace recaptures columns × rows (one undo step).
- Styling: separate horizontal/vertical margins with a link; corner radius 0–20 %. Frame info: any installed font family, size, horizontal/vertical margins, four swatches + transparent + picker, background opacity. Settings decode the former keys.
- Hover overlay in MoviePrint's style (faint white, solid white and slightly larger under the pointer, condensed text sized from the thumb, "‹|›" handle); ◀ HIDE / HIDE ▶ with ⌥; short tooltips everywhere.
- Movie list: poster with the name beside it; full folder path (condensed) and duration · W×H · size under it.
- KNOWN_ISSUES 4 (scrub overlay scales into a small window) and 5 (⌘Z/⇧⌘Z act on the text while renaming) fixed.
- Core: `GridGeometry` separate margins, corner ratio, fit/fill zooms; `GridLayout.rows` / `columns(rows:)`; `FrameInfoFamily`; `ScrubLayout` fitting.

### Bugs found and fixed

- Two kernel panics in the hardware decoder driver (AppleAVD, macOS 27.2) during an evicted-thumb reload loop: all AVFoundation decodes now pass one `DecodeGate`; on-screen images are pinned outside the cache; reloads of the same image wait at least 2 s.
- The scrub frame cache was cleared on every loop pass (a bad replace in T03).

### Verification

- Build: `scripts/check.sh install` passes (68 tests, 13 suites), release build signed, installed to `~/Applications` and launched.
- Automated verification: new tests for separate margins, corner radius, fit/fill zooms, zoom between steps, rows/columns helpers, settings migration, scrub layout in a small window.
- Manual verification: the owner confirmed each round item by item (rounds 2–7 above, including no redraw loop after the panic fixes). Screenshots in Drive `AI/Handoff/FrameSheet/`: `2026-11-03-t03b-before.jpg`, `2026-11-03-t03b-after-1.jpg`, `2026-11-03-t03b-after-2.jpg`. The agent checked the panel toggle survives hiding the panel.
- Not performed: scrub at the smallest window size and ⌘Z while renaming were not tried by the owner; contrast was not measured against token pairs (the owner judged by eye, and part of the look deliberately leaves the design system).

### Remaining Issues

- `docs/V3_SPEC.md` §4/§6 still describe the floating toolbar, footer, no Preferences window, Plex and "Change thumb count"; spec changes are for the HQ.
- KNOWN_ISSUES 4: the decoder driver panic is mitigated, not cured.

### Follow-up Suggestions

- HQ: spec updates (SF fonts as the app default, plain sheet names, Save as a toolbar download button, player view button with T06, the T03b layout).
- Pending (owner): grid controls in the toolbar without a right panel; more than one concurrent decode after a per-machine measurement.
