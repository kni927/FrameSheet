# v3 measurements: decode, shot scan, Vision faces

Measured 2026-11-01 and 2026-11-02 with `tools/spike` (`tools/spike/run-all.sh`) to fix the v3
scan design and defaults. Every number is the median of 3 runs unless a row says otherwise.

- macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2, release build.
- One of the owner's Apple Silicon Macs (the repository is public, so the model and chip
  are not recorded). Faster chips should only make decode faster; see Caveats for what
  would change then.
- ffmpeg 9.0 (a static arm64 build).
- Run outside the Claude Code sandbox: inside it, VideoToolbox cannot decode (`-12911`)
  and Vision lists no GPU.

## Inputs

From the owner's own files. No 4K file and no HDR file were available.

| ID | Container | Codec | Resolution | fps | Duration | GOP (mean / max frames) | Bitrate |
|----|-----------|-------|------------|-----|----------|-------------------------|---------|
| A | MP4 | H.264 High, 8-bit 4:2:0 | 1920×1080 | 59.94 | 107.9 min (387,968 frames) | 248 / 250 (≈4.2 s) | 15 Mb/s |
| B | MP4 | HEVC Main 10, 10-bit 4:2:0, BT.709 SDR, sample entry `hev1` | 1280×720 | 23.976 | 16.2 min (23,277 frames) | 123 / 240 | 3.0 Mb/s |
| C | Matroska | WMV3 (VC-1 Simple/Main) | 1920×1080 | 29.97 | 61.3 min | 71 / 90 | 8.1 Mb/s |

GOP lengths are from the first 5 minutes (`ffprobe -show_entries packet=flags`).

**`hev1` is not decodable by AVFoundation.** `AVAssetReader` fails on B with `-11833`
"The decoder required for this media cannot be found" (`-12906`), and
`AVAssetImageGenerator` returns no image. A stream copy that only changes the sample entry
(`ffmpeg -c copy -tag:v hvc1`) decodes normally; the AVFoundation rows for B use that copy
(B′). The ffmpeg rows use the original B.

## 1. Sequential decode (`AVAssetReader`)

A: the first 5 min (17,982 frames; the whole film is in section 4). B′: the whole file.
"reader" scales in the track output's settings (`kCVPixelBufferWidthKey`/`HeightKey`);
"vImage" and "Core Image" take the full-size output and scale it afterwards.

| Output | Scaling | A fps | A wall (s) | B′ fps | B′ wall (s) |
|--------|---------|------:|-----------:|-------:|------------:|
| native BGRA | — | 711 | 25.3 | 1399 | 16.6 |
| native 420f | — | 702 | 25.6 | 1407 | 16.5 |
| 720 px BGRA | reader | 706 | 25.5 | 1263 | 18.4 |
| 720 px 420f | reader | 711 | 25.3 | 1257 | 18.5 |
| 240 px BGRA | reader | 624 | 28.8 | 1096 | 21.2 |
| 240 px 420f | reader | 618 | 29.1 | 1114 | 20.9 |
| 240 px BGRA | vImage (`vImageScale_ARGB8888`) | 592 | 30.4 | 1003 | 23.2 |
| 240 px BGRA | Core Image | 676 | 26.6 | 1110 | 21.0 |
| 240 px 420f | Core Image | 689 | 26.1 | 990 | 23.5 |

Post-scaling cost per frame: vImage 1.59 ms (A, from 1080p) / 0.80 ms (B′, from 720p);
Core Image 1.30 / 0.74 ms (BGRA), 1.24 / 0.79 ms (420f).

- Decode, not scaling or pixel format, sets the speed: native, 720 px, BGRA and 420f are
  within 2 % of each other on A.
- Asking the reader for 240 px is 12–13 % *slower* than 720 px on both files, and
  scaling afterwards is no better. Small outputs from the reader cost extra.
- This process uses 0.25–0.5 cores; the decoder runs in `VTDecoderXPCService`. The
  system-wide busy count during the runs was 2.6–5.6 cores, background included, so
  it is only an upper bound.
- Peak physical footprint of the process: 22–38 MB in every row.
- A 30 s cold first run on A gave 331 fps, against 700 fps warm (not a median; file
  cache and decoder start-up).

## 2. Shot metric (mean of HSV V = max(R, G, B) at 240 px)

| Input | Without metric | With metric | Metric per frame |
|-------|---------------:|------------:|-----------------:|
| A, 240 px BGRA | 624 fps | 625 fps | 0.015 ms |
| B′, 240 px BGRA | 1096 fps | 849 fps | 0.013 ms |
| A, 240 px 420f (Y-plane mean instead) | 618 fps | 597 fps | 0.009 ms |
| B′, 240 px 420f (Y-plane mean instead) | 1114 fps | 865 fps | 0.007 ms |

The metric (a plain Swift loop over 240×136 pixels) is 1 % of a frame's decode time on A.
The lower fps for B′ with the metric is not explained by the metric's own 0.013 ms; the
`system_cores` count for those runs was about 5.5 against 2.6–2.8 without, so other system
load is the likely cause (not re-run). In section 4 the metric runs on every frame
without lowering the decode rate.

## 3. Vision face rectangles at 720 px (720×406)

200 detections on every 30th frame from 30 min into A (people on screen in about a third
of the frames). `first` is the first request in the run; `median` is over the other 199.

| API | Revision | Compute device | median (ms) | mean (ms) | first (ms) | Faces per frame |
|-----|----------|----------------|------------:|----------:|-----------:|----------------:|
| Swift `DetectFaceRectanglesRequest` | 4 (default) | default | 15.0 | 14.4 | 17 | 0.35 |
| Swift | 4 | forced CPU | 15.5 | 14.7 | 13 | 0.35 |
| Swift | 4 | forced GPU | 15.7 | 14.8 | 15 | 0.35 |
| Swift | 4 | forced Neural Engine | 15.3 | 14.5 | 18 | 0.35 |
| Swift | 3 | default | 8.8 | 8.5 | 13 | 0.33 |
| `VNDetectFaceRectanglesRequest` | 3 (default, newest) | default | 7.6 | 8.1 | 11 | 0.33 |
| VN | 3 | forced CPU | 31.0 | 31.5 | 47 | 0.33 |
| VN | 3 | forced GPU | 20.2 | 20.2 | 26 | 0.33 |
| VN | 3 | forced Neural Engine | 8.5 | 8.4 | 12 | 0.33 |
| Swift, B′ (every 10th frame from 2 min) | 4 | default | 10.9 | 10.9 | 10 | 0.09 |

- Both APIs list `ane, gpu, cpu` for the main compute stage (`supportedComputeStageDevices`).
  Revision 4 is the Swift API's default on macOS 27 and exists only there;
  `VNDetectFaceRectanglesRequest` stops at revision 3.
- **Revision 3 uses the Neural Engine by default.** Default (7.6 ms) matches forced
  Neural Engine (8.5 ms) and is 4× faster than forced CPU (31 ms) and 2.6× faster than
  forced GPU (20 ms).
- **Revision 4 ignores the device setting.** It takes 15 ms whatever device is set, so it
  could not be told from these numbers where it runs. It found about 6 % more faces than
  revision 3 on the same frames.
- First request in a fresh process: 0.9–1.2 s for VN with default or GPU. The first
  request after the build (cold model caches) took 8.6 s (one sample, smoke test).
  Later processes started in 10–90 ms.

## 4. Combined pass on the 2 h film (A, 387,966 frames)

One `AVAssetReader` output at 720 px BGRA (reader-scaled). On every frame, the tool scales
the frame to 240 px with vImage and computes the metric; on every Nth frame, it runs
the Swift face request (revision 4, default device) on the 720 px frame. Everything runs
sequentially on one task.

| N | Detections | Wall | fps | Waiting on Vision | Peak footprint | Process CPU | System busy |
|---|-----------:|-----:|----:|------------------:|---------------:|------------:|------------:|
| 10 | 38,797 | 545.8 s (9.1 min) | 711 | 353.5 s (9.1 ms each) | 39 MB | 0.65 cores | 2.2 cores |
| 100 | 3,880 | 561.5 s (9.4 min) | 691 | 51.3 s (13.2 ms each) | 37 MB | 0.70 cores | 2.3 cores |

Runs were steady (N = 10: 545.0–547.3 s; N = 100: 560.7–565.8 s).

- The whole film scans in about **9 minutes, 12× real time, at the plain 720 px decode
  rate** (706–711 fps in section 1). Face detection on every 10th frame adds nothing to
  the wall time: the decoder keeps decoding ahead while the task waits on Vision.
- Splitting the time into "scan" and "Vision" does not work for that reason; only
  the wall time counts.
- A second 240 px output on the same reader (`--layout dual`, first 5 min, N = 10) halves
  the rate: 359 fps against 696 fps with one output plus vImage. Each output decodes
  the stream on its own.
- Memory stays flat. The process holds one frame at a time (the reader's own queue is
  in the XPC service).

## 5. Random access (`AVAssetImageGenerator`, 16 evenly spaced frames, `maximumSize` 720)

| Input | Tolerance | Total | Per image | Mean / max offset from requested time |
|-------|-----------|------:|----------:|---------------------------------------:|
| B′ (HEVC 720p, GOP ≈ 5 s) | zero | 1.04 s | 65 ms | 0.020 / 0.039 s |
| B′ | ±0.5 s | 1.07 s | 67 ms | 0.037 / 0.214 s |
| A (H.264 1080p60, GOP ≈ 4.2 s) | zero | 3.40 s | 213 ms | 0.008 / 0.016 s |
| A | ±0.5 s | 3.19 s | 200 ms | 0.059 / 0.409 s |

- Not measured on 4K HEVC (no file). Per-image cost grows with resolution and with the
  number of frames to decode from the previous keyframe, so 4K long-GOP will be slower
  than A.
- ±0.5 s saves 0–6 %. The keyframes are 4–5 s apart, so the window rarely reaches
  one and the generator still decodes from the previous keyframe. Zero tolerance is
  frame-exact (offsets are under one frame).

## 6. ffmpeg reference (rawvideo BGRA pipe at 240 px)

`ffmpeg -i <file> -an -sn -vf scale=240:136 -pix_fmt bgra -f rawvideo -` into the tool.
A and C: the first 5 min; B: the whole original (`hev1`) file.

| Input | Decoder | fps | ffmpeg CPU | System busy |
|-------|---------|----:|-----------:|------------:|
| A, H.264 1080p60 | software | 602 | 5.6 cores | 7.9 cores |
| A | `-hwaccel videotoolbox` | 215 | 1.0 cores | 4.2 cores |
| B, HEVC 10-bit 720p (`hev1`) | software | 693 | 5.5 cores | 7.8 cores |
| B | `-hwaccel videotoolbox` | 646 | 1.6 cores | 4.5 cores |
| C, WMV3 1080p30 in MKV | software | 450 | 1.8 cores | 3.1 cores |

- Software ffmpeg nearly matches AVFoundation's speed (602 against 624 fps at 240 px on A)
  but uses almost every core.
- `-hwaccel videotoolbox` with a `scale` filter is slower for H.264, because each frame
  is copied back from the hardware surface. For a fallback, software decoding is the
  better default.
- WMV3 decodes on about two cores at 450 fps, 15× real time for 30 fps material.

## Recommendation

- **Scan design: one decode pass, one reader output at 720 px BGRA.** Compute the shot
  metric on a 240 px copy made with vImage from each 720 px frame, and run face detection
  on the same 720 px frames. Do not open a second output or a second reader for 240 px
  (it halves the speed), and do not ask the reader for 240 px directly (it is
  12–13 % slower than 720 px).
- **Scan resolution: 240 px long side for the shot metric** (MoviePrint's scale). It is
  derived for free from the 720 px frame, and the metric costs 0.015 ms per frame. BGRA
  rather than 420f: same decode speed, and both the V metric and Vision want RGB.
- **Face sampling default: every 10th frame.** On a 2 h 1080p60 film it costs no extra
  wall time against every 100th frame (9.1 against 9.4 min). Keep N = 100 as the
  option for slow inputs (the ffmpeg path), where detection would compete for CPU.
- **One combined pass is viable for a 2 h film: about 9 minutes on this Mac** for 1080p60
  H.264 with faces on every 10th frame (12× real time), using under 40 MB in the process.
  Show progress and allow cancel; 4K material will take longer.
- **Neural Engine:** revision 3 runs on it by default (7.6 ms against 31 ms forced to CPU).
  For revision 4, the Swift default, the device setting makes no difference (15 ms), so
  where it runs is unverified. Use the Swift API with its default revision 4, which finds
  slightly more faces. Its cost is hidden behind decode at N = 10. Revision 3 remains
  a fallback if detection ever becomes the bottleneck. Warm the request up when a movie
  opens (first request: up to 1.2 s; 8.6 s on cold caches).
- **Frame cache: keep scan results, not frames.** A 240 px BGRA frame is 128 KB, so all
  387,966 frames of A would take about 50 GB; nothing at frame level fits in memory.
  Persist per-frame results instead: the metric as Float32 takes 1.5 MB for A, plus
  face rectangles for the sampled frames. For thumbnails (65–213 ms each from
  `AVAssetImageGenerator`, so a 16-frame sheet costs 1–3.4 s to regenerate), use an
  `NSCache` of decoded `CGImage` thumbnails at display size, limited by cost to
  **256 MB**. That is about 220 thumbnails at 720 px (1.17 MB each) or about 1,950 at
  240 px. The limit is small enough for Macs with little memory and should be a setting.
- **Thumbnail time tolerance: zero.** ±0.5 s saves almost nothing on 4–5 s GOPs and loses
  frame accuracy.
- **Input routing:** check the HEVC sample entry when opening a file. `hev1` (and codecs
  AVFoundation lacks, such as WMV3 or VP9/AV1 in MKV/WebM) must go to the ffmpeg fallback,
  or for `hev1` through a remux to `hvc1`. The fallback should use software ffmpeg,
  which reaches about 600 fps for 1080p H.264 and 450 fps for WMV3 at 240 px.

## Caveats

- No 4K HEVC and no HDR input: sections 1, 4 and 5 lack the 4K numbers the TASK asked
  for, and HDR (PQ/HLG) tone handling was not checked.
- `AVAssetReader.add(_:)`, `startReading()` and `copyNextSampleBuffer()` are deprecated
  in the macOS 27 SDK in favour of `AVAssetReader.outputProvider(for:)` /
  `AVAssetReaderOutput.Provider.next()`. The spike uses the deprecated API; v3 should use
  the new one and re-check the decode rate with it.
- Where revision 4 runs could not be seen with timing alone (`powermetrics` needs root
  and was not run).
- On a faster chip, decode gets faster but the Vision time per request may not shrink as
  much. At N = 10, Vision's 9 ms per request then sets a floor of about 6 minutes per
  2 h film. Re-measure on the fastest Mac before raising the default.
- System-wide CPU counts include other load on the Mac; per-process counts miss the
  decoder's XPC service. Neither is an exact measure of decode CPU.
