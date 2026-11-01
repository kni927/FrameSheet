# TASK: v3 measurement spike (decode, shot scan, Vision faces)

## Background

MoviePrint's shot detection reads every frame, and its face sheets sample every 10th or 100th frame. For long-GOP H.264/HEVC, sampling still means decoding nearly every frame, so v3's design (one decode pass for shot scan + face detection, scan resolution, face sampling interval, frame-cache size) depends on numbers we do not have yet. The research marked them unverified.

## Goal

Measure, on this Mac, the costs that fix the v3 scan design and defaults, and record them with a recommendation in `docs/v3-measurements.md`.

## Scope

### In scope

A small Swift command-line tool under `tools/spike/` (its own Swift package, macOS 27, arm64, Swift 6) that measures:

1. **Sequential decode** with `AVAssetReader` over the whole file: fps and wall time, output scaled to max 240 px (shot scan) and max 720 px (faces), BGRA vs `420YpCbCr8BiPlanarFullRange`; note whether scaling in the reader's output settings or afterwards (vImage/Core Image) is faster.
2. **Shot metric cost**: per-frame mean of HSV V (= max(R,G,B)) at 240 px, as MoviePrint's Mean method does; the added cost on top of decode.
3. **Vision face rectangles** at max 720 px: ms per frame with the Swift Vision API (`DetectFaceRectanglesRequest`) and with `VNDetectFaceRectanglesRequest`; which compute devices the request supports (e.g. `supportedComputeStageDevices`) and the time when forced to CPU vs the default, to tell whether the Neural Engine is used.
4. **Combined pass** on a long film (about 2 h): decode every frame at 240 px for the shot metric, and run face detection on every Nth frame at 720 px for N = 10 and N = 100; total wall time, peak memory, CPU load.
5. **Random access**: `AVAssetImageGenerator`, 16 evenly spaced frames, zero tolerance vs a tolerance of ±0.5 s, on the 4K HEVC file (thumbnail generation for interval sheets).
6. **ffmpeg reference**: system `ffmpeg` decoding the same files to a rawvideo pipe at 240 px (`-f rawvideo -pix_fmt bgra -vf scale=...`), fps, for planning the WebM/MKV fallback; plus one WebM or MKV file if the owner has one.

Inputs: ask the owner for video files from their own collection: a 1080p H.264 file, a 4K HEVC file, a long film (about 2 h), and, if available, a WebM/MKV file and a 10-bit/HDR file. Record each generically (container, codec, resolution, fps, duration, GOP length from ffprobe), never by file name or path.

Run each measurement 3 times and report the median.

### Out of scope

- Any change under `src/`, `build.sh`, or v2 docs other than STATUS.
- Committing any video or frame image.
- Building the v3 app or its package layout (the next TASK).

### Parts

1. The tool under `tools/spike/` with a short README (how to run it).
2. The measurements and `docs/v3-measurements.md`.

## Implementation notes

- Build with `swift build -c release --scratch-path` pointing outside the repository (for example `~/Library/Caches/FrameSheet/spike`), so no `.build/` lands in the repository; if one does, git-ignore it. Nothing goes under `build/`.
- The repository is public (`AGENTS.md`, Public Repository): `docs/v3-measurements.md` records the macOS and Xcode versions only; no Mac model, chip, hostname, user name or file names. Put the chip and Mac model in your report to the HQ only.
- Keep the tool simple and throwaway-quality but readable; it will be reused to re-measure later.

## Verification

- The tool builds in release mode and runs on every input without crashing.
- `docs/v3-measurements.md` has: inputs (generic), a table per measurement (median of 3), and a Recommendation section proposing the scan resolution, face sampling default, whether one combined pass is viable for a 2 h film (and expected time), whether Vision uses the Neural Engine, and the frame-cache size.
- `git status` clean after the commit; no video files, no `.build/` tracked.

## Progress

- Last completed step: Part 2 (measurements, `docs/v3-measurements.md`).
- Current partial state: none.
- Exact next step: none; task archived.

## Implementation Result

**Status:** Completed with follow-up issues

### Changes

- Part 1 (489dfef): `tools/spike/`, a Swift 6 package (macOS 27, arm64) with the
  commands `decode`, `faces`, `devices`, `combined`, `random` and `ffmpeg`, a README,
  and `run-all.sh`, which builds the tool and runs the whole battery as one command.
  `.gitignore` gains `/tools/spike/.build/` (none was created; the build uses
  `--scratch-path ~/Library/Caches/FrameSheet/spike`).
- Part 2: `docs/v3-measurements.md` (inputs, a table per measurement, Recommendation,
  Caveats); `docs/STATUS.md` updated.
- Deviations: no 4K HEVC or HDR file was available (owner), so the 720p 10-bit HEVC file
  stands in for random access and HEVC decode. Measurements 1–2 on the 2 h H.264 film
  use its first 5 minutes (the whole film is decoded in measurement 4); the 61 min MKV
  uses its first 5 minutes for ffmpeg. The HEVC file is tagged `hev1`, which AVFoundation
  cannot decode, so its AVFoundation rows use an `hvc1` stream copy made in the session
  scratchpad (not committed).
- Added beyond the list: native-size decode as a baseline, a dual-output layout for the
  combined pass, Vision revision 3 against 4, and `-hwaccel videotoolbox` for ffmpeg.
- Bugs found and fixed: none.

### Verification

- Build: `swift build -c release --package-path tools/spike --scratch-path ~/Library/Caches/FrameSheet/spike`
  succeeds (deprecation warnings only, recorded in Caveats).
- Automated verification: `run-all.sh` ran 45 commands × 3 runs on the three inputs
  without a failure (2026-11-01 23:46 to 2026-11-02 01:28 JST).
- Manual verification: smoke runs of every command; the logs were checked against the
  tables in `docs/v3-measurements.md`.
- Not performed: 4K HEVC and HDR inputs (none available); `powermetrics` (needs root) to see
  where Vision revision 4 runs.

### Remaining Issues

- 4K HEVC and HDR numbers are missing.
- Where Vision revision 4 runs is unverified.

### Follow-up Suggestions

- Measure 4K HEVC and HDR when the owner has such files (`run-all.sh` with the new inputs).
- Re-measure on the fastest Mac before raising defaults.
- Re-check decode speed with the macOS 27 `AVAssetReaderOutput.Provider` API, which replaces
  the deprecated `copyNextSampleBuffer()`.
