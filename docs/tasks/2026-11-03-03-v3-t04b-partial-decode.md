# TASK: v3 T04b — frames AVFoundation cannot decode (open-GOP files)

From: FrameSheet HQ (via handoff-relay), 2026-11-03. Pull `main` first (the spec now follows T04 and is en-US). Builds go through `scripts/check.sh install`; follow the "Commands and sandbox" counting rule; short tooltips on new controls.

## Background

KNOWN_ISSUES 5: in open-GOP H.264 files (non-IDR sync samples) AVFoundation decodes only part of the frames exactly; the ±0.5 s retry moves thumbs to keyframes, and a scrubbed frame is silently moved. ffmpeg decodes them. Owner decision (2026-11-03): AVFoundation stays the default; a Settings option fetches such frames with ffmpeg, per frame. This concerns frames of a file that is already open, not routing the whole file, so decision 10 stands; record the new rule as decision 25 in `docs/DECISIONS.md` (this TASK is the owner's approval to add it).

## Goal

With the option on, every requested frame of such a file is the exact frame; with it off, the app never shows or saves a frame other than the one it says, and the ffmpeg path is frame-exact.

## Scope

### In scope

1. **Detection and fallback (core + decode layer):** when an exact AVFoundation request fails (or returns a different frame), and the option is on and ffmpeg is available, fetch that frame with ffmpeg (input seek, exact frame) through `DecodeGate`; keep AVFoundation for every frame it decodes exactly. Optionally remember per file that it is partly decodable, to go to ffmpeg first for its failing GOPs.
2. **Settings window:** an option (on by default if your measurement shows it costs nothing for normal files; otherwise off) with a short explanation and tooltip; disabled with a note when ffmpeg is missing.
3. **Truthful frames with the option off:** a thumb that falls back to a nearby frame shows its real frame number/time (decision 11) and a small marker; a scrubbed, confirmed frame that cannot be decoded exactly is not silently moved: tell the user (toast) and keep the previous frame.
4. **ffmpeg path offset:** fix the (f − 0.5)/fps seek that is one frame off on such files; frame-exact on CFR files, with a test.
5. **Save:** Save sheet and Save thumb use the same path, so saved images match the window.
6. **Change (HQ, owner approved 2026-11-03): new first fallback, AVFoundation from one GOP earlier.** When an exact `AVAssetImageGenerator` request fails or returns a different frame, first try an `AVAssetReader` (macOS 27 output-provider API) whose time range starts just before the previous sync sample (one GOP before the target's GOP), decode forward through `DecodeGate` and keep only the target frame; only when that also fails, use the ffmpeg per-frame fetch. Steps first: (1) test on the synthetic open-GOP clip and the owner's open-GOP file whether reading from one GOP earlier gives every frame exactly (record in Progress); (2) measure the per-frame time (median over the frames that failed before) against the ffmpeg fetch, and run `run-all.sh quick`; (3) if exact and within about 2× of ffmpeg, make it the default fallback (hardware decoding, no ffmpeg needed); otherwise skip it. Report the numbers either way. Decision 25 covers both fallbacks. Hypothesis behind it (HQ research): `stss` lists non-IDR I frames as full sync samples (no `kCMSampleAttachmentKey_PartialSync`), so AVFoundation starts at them; not confirmed in Apple's documentation.

### Out of scope

- Routing whole files to ffmpeg by this detection; T05 shot scan (sequential reading from the start already works there); moving right-panel settings to the Settings window (a later UI step).

### Parts

1. Core and decode changes with tests (synthetic open-GOP clip made with ffmpeg/x264 in the test, frames encoding their number, as in the skeleton's tests).
2. Settings option, markers and toasts.
3. Measurement and docs.

## Implementation notes

- Measure with `tools/spike/run-all.sh quick` (decode changes) and record in the report: cost on a normal H.264 file (should be none) and the time per ffmpeg-fetched frame on the open-GOP file.
- Public repository: describe the test file generically ("an open-GOP H.264 file from the owner's files"); no file names.
- Update `docs/KNOWN_ISSUES.md` (5), `docs/ARCHITECTURE.md`, `docs/STATUS.md`, `README.md` as the change requires; report spec gaps to the HQ instead of editing `docs/V3_SPEC.md`.

## Verification

- `scripts/check.sh install` passes; tests: open-GOP clip all frames exact with the option on; with it off, no frame mislabeled; ffmpeg path frame-exact.
- Manually on the owner's open-GOP file: 16 thumbs exact with the option on; scrub to frames in GOPs with leading frames confirms exactly; with the option off, markers and the toast appear; a normal file behaves as before.
- `git status` clean after the last commit.

## Progress

- Last completed step: implemented, owner-checked, docs updated, archived (2026-11-03).
- Note: `docs/reference/` is no longer ignored — the owner had the folder removed from the repository (its files live outside it) after the HQ's message was written.
- Parts 1–2 implemented (not committed; 119 tests pass): `FFmpegFrameFallback` per frame inside `DecodeGate`, frame-exact ffmpeg seek (earlier input seek + `select` by pts + `showinfo`), Settings option `exactFramesWithFFmpeg` (default on), markers, scrub refusal toast, Save names by the decoded frame. `run-all.sh quick` on a normal 1080p H.264 file (2026-11-03): decode 720 BGRA 711 fps, random exact 180 ms/image, combined N=10 617 fps, ffmpeg 537 fps — in line with `docs/v3-measurements.md` (the spike uses its own decoders, so it does not exercise this change).
- Item 6 result (2026-11-03). Synthetic clip (keyint 16, bframes 3, open GOP; all keyframes full sync, none partial): the exact generator misses 48 of 64 frames (every non-keyframe from 13 on, not only leading B frames); a reader from the previous sync sample recovers 15 of 48 — only targets whose previous keyframe is the IDR frame 0; from a non-IDR keyframe it ends with -11821/-12137 after at most that keyframe; a reader from the movie start recovers all 48. Test `openGOPEarlierGOPReaderIsExact` (known issue). Owner's open-GOP file, 63 frames (52 failing the generator), sequential: earlier-GOP reader exact on 25 of the 52 (where the previous GOP has no leading frames), errors on the rest; ffmpeg exact on 63/63. Median ms on generator-failed frames: reader 27 (640 px) / 20 (1920 px), ffmpeg 93 / 387; a failing reader read costs about 13–18 ms. Hypothesis not confirmed: the reader fails whenever it starts at a non-IDR keyframe whose own leading frames lack references.
- Owner decision (2026-11-03, in this chat): three steps — exact generator request → earlier-GOP reader → ffmpeg (Settings option). The reader step runs whether or not the option is on.
- Scope item 6 added by the HQ (2026-11-03); done as decided above.
- Owner's checks (2026-11-03): toggling the option no longer redraws exact thumbs, also across sheets; the marker appears (on newly fetched inexact thumbs, e.g. after Expand) with its tooltip; the scrub starts at the thumb's own frame; with the option on, 16 thumbs exact and a scrubbed frame confirmed exactly; with it off, the toast and the kept frame. Asked for and added: a modifier hint under the scrub.

## Implementation Result

- Status: Completed with follow-up issues

### Changes

- Decode (decision 25): three steps per frame inside `DecodeGate` — exact generator request; `EarlierGOPReader` (`AVAssetReader` output provider from the previous full sync sample, kept by pts); `FFmpegFrameFallback` when "Fetch exact frames with ffmpeg" is on (default) and ffmpeg is found; otherwise the ±0.5 s retry. `DecodedFrame` names its decoder and exactness. Batches collect failures and run steps 2 and 3 one by one.
- ffmpeg path frame-exact: input seek a little early, `select` by pts, frame number from `showinfo`; also exact for leading B frames.
- App: Settings option (disabled with a note without ffmpeg); toggling sets the fallback on open backends and refetches only inexact thumbs; inexact marker at the bottom right of a thumb (window only); SAVE moved to the top center of the hover overlay; an inexact scrub is refused with a toast; the scrub starts at the thumb's own frame (piecewise map around the press point) and names its modifier keys; Save thumb and each-thumb files are named by the decoded frame.
- Docs: decision 25, KNOWN_ISSUES 5, ARCHITECTURE, STATUS, README.

### Bugs found and fixed

- `NSCache` dropped thumbnails under memory pressure far below its limit, so other sheets redrew: `ThumbnailCache` is now an LRU cache with a strict byte limit.
- Toggling the option cleared the whole cache and reopened every backend.
- The ffmpeg path's (f − 0.5)/fps seek returned f ± 1 on open-GOP files.
- Save thumb named files by the requested frame instead of the decoded one.

### Verification

- Build: `scripts/check.sh install` passes (124 tests, 21 suites, 1 known issue: `openGOPEarlierGOPReaderIsExact` documents the reader's limit).
- Automated verification: synthetic open-GOP clip (libx264 .mov, non-IDR sync samples) — option off: generator 16 / reader 15 / 33 inexact, none mislabeled; option on: all 64 exact (generator 16 / reader 15 / ffmpeg 33); ffmpeg path exact; toggle on an open backend; LRU cache; scrub press mapping.
- Measurement: `run-all.sh quick` on a normal 1080p H.264 file in line with `docs/v3-measurements.md` (the spike does not use this path). Probe on an open-GOP H.264 file from the owner's files (one run outside the sandbox): see the Item 6 result above.
- Manual verification (owner): see Owner's checks above.
- Not performed: a rotated partly decodable movie (step 2 is skipped for rotated tracks); a VFR phone video with the new detection.

### Remaining Issues

- Files AVFoundation decodes only partly still cost about 0.1–0.4 s per ffmpeg-fetched frame; without ffmpeg about half of such frames stay inexact (marked).

### Follow-up Suggestions

- T05's shot scan reads from the start, which decodes every frame of such files.
- Spec gaps for the HQ (STATUS lists them).
