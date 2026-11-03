# TASK: v3 T05 — shot scan, timeline view, cut/merge, EDL

From: FrameSheet HQ (via handoff-relay), 2026-11-03, next in the owner's order. Pull `main` first (the spec now follows T04b). Builds go through `scripts/check.sh install`; follow the "Commands and sandbox" counting rule; short tooltips on new controls.

## Background

Shot detection and the timeline view are the main capabilities MoviePrint has over FrameSheet v2. The spike fixed the scan design (`docs/v3-measurements.md`: one sequential pass, one 720 px BGRA output, 240 px derived with vImage, about 9 min for a 2 h 1080p60 film). Reading from the start decodes every frame, so open-GOP files (decision 25) are not a problem here.

Estimate: 2–24 h (four parts: scan engine and cache, shot sheets and timeline view, scene interactions and chart, EDL and shot-sheet I/O, each with tests and owner checks; working time only, the full-film scan wait excluded). If the working time passes twice that, tell FrameSheet HQ and the owner. End the T05 report with the `Took:` line from `work-timer --report --since <T05 start>` (added by the HQ, 2026-11-03).

## Goal

The owner can scan a movie for shots, get a shot sheet in timeline view, change the threshold without rescanning, cut and merge scenes, expand a scene, export an EDL, and view interval sheets as a timeline, as `docs/V3_SPEC.md` §5, §6 (timeline and experimental parts), §7 (timeline scenes) and §10 describe.

## Scope

### In scope

1. **Scan (§10):** one `AVAssetReader` pass with the macOS 27 output-provider API, 720 px BGRA, transform applied, 240 px via vImage; Mean method (HSV V difference, mean color) and Histogram method (32×32×32 HSV, chi-square alternative); per-file scan cache (Float32 metric + mean color per frame, persisted, about 1.5 MB per 2 h film); scenes stream to the UI during the scan; progress and Cancel; ffmpeg path for files AVFoundation cannot read (a BGRA pipe, software decode). Leave a hook for faces in the same pass (T07) but do not detect faces.
2. **Scene list (core, tested):** cut where difference ≥ threshold and ≥ 10 frames since the last cut, a larger difference inside that window moves the cut; scene color = mean color of the middle frame, last scene gray; threshold change rebuilds scenes from the cache without rescanning; cut and merge recompute middle-frame thumbs; automatic IN/OUT (first/last min(300, len/2) frames at 0.25 scale, mean V ≥ 20, brightest fallback) behind the Experimental option.
3. **Shot sheets (§5):** Add shot-detection sheet in the toolbar; one thumb per scene at `start + floor(length / 2)`; opens in timeline view; "S" badge on the movie's poster once scanned; Convert to interval and Switch grid/timeline enabled in the sheet menu (timeline disabled for faces); sort disabled for shot sheets.
4. **Timeline view (§10 layout, §6, §7):** rows filled until the summed length exceeds `secondsPerRow × fps` (the movie's own fps); px per frame and row height as in §10; scene width = max(ppf × length, ppf × min length); scene box = mean color with the frame image; selected scene widens to full aspect width; Toggle images (mean colors only). Settings: Minutes per row 10–1800 s (default 120 s), Natural flow, scene width ratio, min scene width, threshold 3–40 (default 6.0) with "Add new sheet", stats line "N Shots / ~M Minutes ≈ X cut/min". Timeline view also works for interval sheets (artificial scenes split at midpoints).
5. **Scene interactions (§7):** Expand (child interval sheet of 16 thumbs inside the scene, Back to parent), Hide, Hide all before/after, Jump to cut start/end, Scrub (limited to the scene, always change), cut and merge (a button or menu on the selected scene; the player-view keys come in T06).
6. **Detection chart (key F):** difference per frame, threshold line, and the k-means (k = 3) "calculated threshold" on a 256-bin histogram (display only).
7. **EDL export (§12):** sheet menu, CMX3600 style, `TITLE:`, `FCM: NON-DROP FRAME`, events with `* FROM CLIP NAME:`; hidden scenes excluded; tests. Shot-sheet JSON/PNG export and import (`sceneArray`) on top of T04's I/O, with tests.

### Out of scope

- Player view and its keys (T06), faces (T07), transforms and Save All (T08); moving right-panel settings to the Settings window (separate UI step).

### Parts

1. Scan engine and cache; scene list, cut/merge, auto IN/OUT (core, tests).
2. Shot sheets and timeline view with its settings.
3. Scene interactions and the detection chart.
4. EDL and shot-sheet I/O; measurement; docs.

## Implementation notes

- All decoding goes through `DecodeGate`; the scan holds it for its whole pass, and thumb requests wait or are served from the cache (keep the UI responsive; report how).
- Measurement: `tools/spike/run-all.sh quick` once, plus the wall time of one full scan of a long film from the owner's files (no repeat runs).
- MoviePrint references: `calculateSceneListFromDifferenceArray`, `getScenesInRows`, `getPixelPerFrameRatio`, `createSceneArray`, `cutScene`, `mergeScenes` in fakob/MoviePrint_v004 (MIT; keep the notice when porting).
- Public repository: no Mac model, chip, hostname, user name or personal file names.
- Report spec gaps to the HQ instead of editing `docs/V3_SPEC.md`.

## Verification

- `scripts/check.sh install` passes; tests cover the Mean and Histogram metrics on synthetic frames, the scene list rule, threshold changes without rescan, cut/merge, auto IN/OUT, timeline layout math, EDL output and the shot-sheet round trip.
- Manually: scan a long film (progress, Cancel, resume of a cancelled scan or rescan), threshold changes, cut/merge, Expand/Back, Hide all before/after, scrub inside a scene, Natural flow, Toggle images, detection chart, EDL opens in a text editor with the right event count, interval sheet in timeline view, a WebM/MKV file scanned through ffmpeg.
- `git status` clean after the last commit.

## Progress

- Last completed step: all four parts and the owner's rounds committed and confirmed; docs updated; archived (2026-11-04).
- Owner's UI requests during T05 (2026-11-03), after Part 1: inexact marker less prominent, tooltip about "Nearest decodable frame (asked 9,920)"; rename the "Frame info" section to "Thumb label"; one "Format" picker under Frames / Timecode / Hide, with frame formats "9920" and "9920 / 17604" (with the total) besides the timecode formats, shown while collapsed; Naming scheme shows the Sheet template row while collapsed. No disk cache for thumbnails (owner: not needed).
- Owner's checks (2026-11-03/04): scan speed, Esc to cancel, Resume tooltip, Automatic IN/OUT (correct on both reference films after measurement; an AV1 film with bright end credits keeps OUT at the last frame by the rule), marker and labels, Format picker, naming presets, timeline, scene overlay, cut/merge, chart, insert-gap bar, EDL and shot-sheet re-import ("mostly fine, not checked in detail"), full scan of a 2 h 1080p film: 9 min.
- Owner's requests added along the way: Thumb label section with Frame / Frame / Total formats and Max size; Automatic IN/OUT brightness threshold, Apply, in the Grid section; naming presets with Custom…; no default focus in the panel; Esc cancels a scan; Resume shot detection tooltip; scrub preview names the shown frame (N → shows M); accent bar for the insert gap.

## Implementation Result

- Status: Completed with follow-up issues

### Changes

- Scan (core `Scan/`): one sequential pass through the `AVAssetReader` output provider (720 px BGRA, transform applied, vImage 240 px) or an ffmpeg rawvideo pipe; MoviePrint's Mean and Histogram (32×32×32 HSV, chi-square alt) metrics; scenes streamed during the scan; resumable per-movie cache (Float32 difference + RGB per frame); a face-frame hook for T07 (unused); `DecodeGate` shared with thumb requests by pausing at closed-GOP sync samples with adaptive run lengths.
- Scene list and editing (core): ported `calculateSceneListFromDifferenceArray` (threshold, 10-frame window, moving cut), `cutScene`, `mergeScenes`, `createSceneArray`; threshold change from the cache; automatic IN/OUT with a brightness threshold.
- Shot sheets and timeline: Add shot-detection sheet (Esc cancels; resume; Rescan for Shots; "S" badge); timeline view ported from `getScenesInRows` / `getPixelPerFrameRatio` (rows by Minutes per row at the movie's fps, scene width ratio, min scene width, natural flow, selected scene at full width, mean colors only); Grid / timeline switch (G) for shot and interval sheets; timeline print and Save (size = height).
- Scene interactions: timeline hover overlay (EXPAND as "Shot #n", HIDE, ◀ HIDE / HIDE ▶, jump to cut, scene-limited scrub) after MoviePrint's `Scene.js`; Cut at the thumb and Merge with previous / next in the toolbar; detection chart (F) with the k-means (k = 3) calculated threshold.
- EDL (CMX3600, ported `getEDLscenes`) and shot-sheet `sceneArray` export and import.
- Owner-requested UI listed above.

### Bugs found and fixed

- Canceling a scan on the ffmpeg path could hang forever in `Process.waitUntilExit()` while holding `DecodeGate` (the test suite hung for about 3 h; the app's Cancel could freeze every decode): exits are now awaited through `terminationHandler` with a SIGKILL fallback, in `RawVideoPipe` and `ProcessRunner`; test watchdogs added.
- An ffmpeg process blocked on a full pipe ignored SIGTERM (Part 1).
- A paused scan reopened mid-file on open-GOP files fell back to re-reading from frame 0; the app redrew every thumb on each progress event, rebuilt the timeline with new ids each second and saved the library each second.
- Automatic IN/OUT's OUT reader failed on open-GOP files and the failure was silent.
- The Resume tooltip did not appear right after a stop (the partial cache is written after the stream ends).
- Expand on shot sheets used interval scenes; Replace movie / Locate kept a stale scan cache.
- `scripts/check.sh` had no time limit: it now stops itself after 15 min and has a `stop` mode (CLAUDE.md, owner approved).

### Verification

- Build: `scripts/check.sh install` passes (201 tests in 38 suites; 1 known issue, `openGOPEarlierGOPReaderIsExact`), signed, installed and launched.
- Automated verification: Mean and Histogram metrics on synthetic frames; scene list rule; threshold change from the cache; cut/merge; auto IN/OUT (synthetic fades, both decode paths); scan of synthetic clips with hard cuts through AVFoundation and ffmpeg (cuts on the exact frames); cancel/resume repeated (30 iterations twice before keeping 9); timeline layout math; k-means threshold; EDL text at 24 and 29.97 fps; shot-sheet JSON / PNG round trip and a MoviePrint-style sample.
- Measurement: `run-all.sh quick` on a 1080p H.264 file (2026-11-04): decode 720 BGRA 708 fps, combined N=10 691 fps, random exact 182 ms/image, ffmpeg 612 fps — in line with `docs/v3-measurements.md`. Scan probe (60 s each): 710 fps scanning alone, 517 fps with a thumb request every second; an open-GOP film 928 / 839 fps with no fallback to frame 0. Full scan of a 2 h 1080p film from the owner's files: 9 min (owner).
- Manual verification (owner): see Owner's checks above.
- Not performed: a WebM/MKV scan in the app (the ffmpeg scan path is covered by tests on a synthetic MKV); importing a MoviePrint 0.2.23 shot sheet (only 0.2.12 runs on the owner's Mac); an EDL in an NLE.

### Remaining Issues

- Cut and Jump to cut work on the thumb's frame until the player view (T06) provides a current frame.

### Follow-up Suggestions

- T06: Cut / Jump to cut at the player's frame; Return in the timeline as a player key.
- Spec gaps for the HQ (STATUS lists them).

### Time

- Estimate: 2–24 h. Took: about 14 h of wall clock (2026-11-03 16:41 – 2026-11-04 07:05 JST), of which about 3 h was a hung test run noticed late; the work-timer recorded only the last stretch (60 min working, 4 min waiting on the owner) because the hook started late in the session.
