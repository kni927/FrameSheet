# TASK: Decode Backend — AVFoundation Primary, ffmpeg Fallback

## Context

Independent of Phase 3b (still pending — no scrub UI, no multi-movie
work in this task). Goal: invert the decode architecture so
AVFoundation (`AVAssetImageGenerator` + VideoToolbox hardware decode)
is the primary backend for natively supported formats (mp4/mov/m4v —
H.264/HEVC/ProRes), with the existing ffmpeg-spawn path demoted to a
fallback for AVFoundation-unsupported formats (WebM/MKV/etc.).

Motivations, in order: (1) removes ffmpeg as a hard dependency for the
common formats, unblocking future standalone `.app` distribution
without bundling ffmpeg; (2) hardware decode should meaningfully speed
up generation and per-cell nudge; (3) in-process decoder residency
(kept-alive `AVAsset`) sets up cheap frame access if scrub UI is ever
approved in 3b — but do not build any scrub UI now.

Split into stages; separate commits, separate verification, stop and
flag any product decision not covered here.

## Stage A — Backend abstraction (behavior-preserving)

- Define a `DecodeBackend` protocol covering what the pipeline needs:
  probe/open (duration, dimensions, fps), extract frame at timestamp,
  batch extraction for the sampling pass, and cleanup.
- Wrap the current ffmpeg invocation path as `FFmpegBackend`
  conforming to it. `AppState`/generation code talks only to the
  protocol from here on.
- No behavior change: full 30-item render harness + 25-item smoke
  suite must pass byte-identical against existing baselines.

## Stage B — AVFoundation backend + routing

- `AVFoundationBackend`:
  - Keep the `AVAsset` alive for the loaded video (in-process
    residency; released on video close/replace).
  - Duration/dimensions via `loadValuesAsynchronously` on the needed
    keys — the async `load(.duration)` API is macOS 12+, and the
    deployment target is macOS 11, so use the completion-handler API
    (same availability discipline as prior stages).
  - Frame extraction via `AVAssetImageGenerator`:
    `appliesPreferredTrackTransform = true` (rotated-metadata videos),
    `requestedTimeToleranceBefore/After = .zero` (exact frames — the
    export must be timestamp-accurate; fast/coarse tolerance is a 3b
    scrub concern, not built now).
  - Batch sampling via `generateCGImagesAsynchronously` for the main
    generation pass.
- Routing policy: on load, probe with AVFoundation first; route to
  `FFmpegBackend` only if the asset has no decodable video track.
  If routing falls back and ffmpeg is not installed, fail with a
  user-facing message naming the format and suggesting
  `brew install ffmpeg` — not a crash, not a silent hang.
- Show the active backend somewhere unobtrusive (e.g. console/log
  line) for diagnosability.

## Stage C — Wire the single-frame path + measure

- Route the per-cell nudge (Stage D of Phase 3a) through the backend
  protocol; on the AVFoundation path this should hit the resident
  asset, no process spawn.
- Measure and record in `docs/DEV_LOG.md`:
  - Full generation time, old vs new, on the ToS 4K mov from
    `docs/reference/Royalty Free Videos/`.
  - Single-cell nudge latency, old vs new.

## Verification & baseline policy

Backend change means pixel-level output changes on the AVFoundation
path (different scaler/color pipeline than ffmpeg). Baseline policy:

- **ffmpeg path**: existing baselines remain authoritative — WebM
  smoke tests (including the synthetic no-duration WebM and the hang
  regression timeout) must pass unchanged, routed through fallback.
- **AVFoundation path**: generate new baselines for mp4/mov at default
  settings; commit them as the new reference. Byte-diff discipline
  continues per-backend from here on.
- Sanity checks on the AVFoundation baselines before accepting them:
  correct frame count, correct timestamps in headers, no color-space
  banding/washout at a glance, orientation correct.
- All Phase 2 settings (corner radius, alpha PNG, JPEG quality) and
  Phase 3a interactions (hide/reorder/nudge/keyboard) verified
  functional on the AVFoundation path.
- `./build.sh` updated to link the needed system frameworks
  (AVFoundation/CoreMedia + whatever the compiler requires); still no
  Xcode project, no new third-party dependencies.

## Wrap-up

- `docs/DECISIONS.md`: backend routing policy, exact-tolerance
  policy, per-backend baseline policy.
- `docs/ARCHITECTURE.md`: add the backend layer (small targeted edit,
  not a full rewrite).
- `docs/DEV_LOG.md` entries incl. the Stage C measurements.
- Archive to `docs/tasks/`.
- After merge to `main`: tag `v2.3.0` (release content: AVFoundation
  primary decode backend with hardware acceleration; ffmpeg now
  optional, required only for WebM/MKV).

## Constraints

- No scrub UI, no multi-movie, no ffmpeg bundling/packaging work.
- No behavior change for ffmpeg-routed formats.
- Follow `AGENTS.md` / `CLAUDE.md`. Branch off current `main`
  (`v2.2.0`).

## Implementation Result

**Status:**
- Completed

### Changes

Branch `feature/avf-decode-backend`, one commit per stage:

- **Stage A (`c95de75`)**: `DecodeBackend` protocol (probe, duration
  estimation, batch extraction, single-frame extraction, cancel,
  close) + `FFmpegBackend` wrapping the entire existing ffmpeg spawn
  path unchanged. AppState (Loading/Generation/Grid) talks only to
  the protocol; console diagnostics via a main-queue `logSink`.
- **Stage B (`ba656af`)**: `AVFoundationBackend` — resident
  `AVURLAsset` per loaded video, completion-handler loading APIs
  (macOS 11 target), `AVAssetImageGenerator` batch + single-frame,
  `appliesPreferredTrackTransform`, VideoToolbox decode. Routing:
  AVF-first, ffmpeg fallback only when no decodable video track;
  fallback-needed-but-missing produces the format-naming
  `brew install ffmpeg` error (verified via CLI check). Launch
  overlay demoted to a dismissible notice; active backend logged.
  Baselines committed under `tests/baselines/` (owner-approved
  location) with a README documenting machine anchoring.
- **Stage C (`29fef3a`)**: nudge verified on the resident asset
  (no spawn) and measurements recorded in DEV_LOG.
- **Flagged mid-task (owner decisions)**: zero-tolerance
  `AVAssetImageGenerator` hard-fails scattered frames on some real
  H.264 streams ("Cannot Decode"; ToS sample: 9/20 frames, its
  stream triggers ffmpeg's `mmco: unref short failure` too). Owner
  approved exact-first + bounded ±0.5s per-frame retry with actual
  decode times propagated into `Thumbnail` (labels stay truthful);
  whole-file ffmpeg fallback rejected. Recorded as decision #11.
  The `DecodeBackend` completions were extended to carry per-frame
  actual timestamps for this.
- Notable finding: the "mp4" sample (Big Buck Bunny) is AV1, which
  AVFoundation only decodes on M3+; on this M1 it correctly falls
  back to ffmpeg — evidence the track-decodability probe routes by
  capability, not extension.

### Verification

- Build: passed at each stage (`./build.sh`; new AVF deprecation
  warnings are the deliberate macOS 11-compatible API choices, same
  discipline as prior stages).
- Automated: render harness 30/30 with the ffmpeg-path default render
  still byte-identical to the Phase 1 baseline (Stage A and B);
  smoke suite grown to 36 checks, all pass — AVF routing for the
  H.264 mov, ffmpeg fallback for WebM ×2 (hang-regression timeout and
  packet-scan duration fallback intact, outputs unchanged) and the
  AV1 mp4, per-file all-frame-files-present (catches per-frame decode
  failures — it caught the zero-tolerance issue), deterministic
  byte-identical reruns, and byte-match against the committed
  `tests/baselines/` references. ffmpeg-missing fallback message
  check passes.
- Manual (GUI): backend line in console; ToS mov generates a full
  20-cell grid via AVFoundation with retry lines logged; hide/unhide/
  keyboard/Esc functional on the AVF path; nudge console shows the
  single re-extract via AVFoundation with a truthful snapped
  timestamp (38.000s requested → t=37.750s decoded → "0:37" label).
- Measurements (ToS-4k-1920.mov, M1, medians): batch 16 frames
  0.74s → 0.26s (~2.8×); single-frame nudge 131ms → 65ms (~2.0×).
- Baseline sanity before adoption: cell count, snapped timestamps in
  labels, orientation, and a cross-backend frame-content comparison
  (ffmpeg extraction of the same timestamp matches the AVF cell).

### Remaining Issues

- None

### Follow-up Suggestions

- The committed baselines are machine-anchored (M1 VideoToolbox);
  regenerating on different hardware will produce different bytes —
  the README documents the policy, but CI on other machines would
  need its own baseline set.
- In-process decode residency now makes a Phase 3b scrub UI cheap if
  ever approved (coarse-tolerance preview generator on the resident
  asset).
