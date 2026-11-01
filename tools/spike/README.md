# spike

Throwaway measurement tool for the v3 scan design: AVAssetReader decode speed,
the shot metric, Vision face rectangles, a combined scan pass, AVAssetImageGenerator
random access, and an ffmpeg reference. Results and the recommendation are in
`docs/v3-measurements.md`.

Swift 6 package, macOS 27, arm64. Never commit input videos or frame images.

## Build

Keep the build products outside the repository:

```sh
swift build -c release --package-path tools/spike --scratch-path ~/Library/Caches/FrameSheet/spike
```

The binary is `~/Library/Caches/FrameSheet/spike/release/spike`.

Run it outside the Claude Code sandbox: inside it, VideoToolbox cannot decode
(`-12911`) and Vision sees no GPU.

## Run

```sh
spike decode   <file> [--max 240] [--format bgra|420f] [--scale reader|vimage|coreimage] [--metric] [--seconds S]
spike faces    <file> [--max 720] [--api swift|vn] [--device default|cpu|gpu|ane] [--revision 3|4] [--every 10] [--frames 200] [--start S]
spike devices
spike combined <file> [--every 10] [--layout single|dual] [--scan 240] [--face 720] [--seconds S]
spike random   <file> [--count 16] [--tolerance 0.5] [--max 720]
spike ffmpeg   <file> [--max 240] [--hwaccel] [--seconds S]
```

Every command runs 3 times (`--runs N`) and prints each run and the median.
`--max 0` keeps the source size. `--seconds` limits the range read from the start.

Output keys: `fps`, `wall_s`; `scale_ms` and `metric_ms` per frame; `first_ms`
(the first face request, including model load) and `median_ms` (the rest);
`cpu_cores` is this process (ffmpeg: the child), `system_cores` is the whole
system's busy cores during the run, which includes `VTDecoderXPCService` (and
any background noise); `peak_mb` is the sampled physical footprint.

`run-all.sh` builds the tool and runs measurements, one log per command. It is
excluded from the Claude Code sandbox (`.claude/settings.json`).

```sh
# Quick check after implementation work: the v3 settings, one run each, a few minutes.
tools/spike/run-all.sh quick <out-dir> <video>...
# The whole battery behind docs/v3-measurements.md: 3 runs each, about 2 h.
tools/spike/run-all.sh full <h264-long> <hevc-hvc1> <hevc-original> <mkv> <out-dir> [sections]
```

AVFoundation does not decode HEVC tagged `hev1`; remux such a file for the
`<hevc-hvc1>` input with `ffmpeg -i in.mp4 -map 0:v:0 -c copy -tag:v hvc1 out.mp4`.

GOP lengths for the inputs table come from ffprobe:

```sh
ffprobe -v error -select_streams v:0 -read_intervals "%+300" -show_entries packet=flags -of csv=p=0 <file>
```

(count the packets between `K` flags).
