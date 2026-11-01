#!/bin/zsh
# Builds the spike and runs measurements. Run outside the Claude Code sandbox
# (VideoToolbox decoding and the GPU are unavailable inside it); it is listed in
# .claude/settings.json sandbox.excludedCommands.
#
#   tools/spike/run-all.sh quick <out-dir> <video>...
#       Regression check after implementation work: one run each of the settings
#       v3 uses (720 px BGRA decode, combined pass, faces, random access, ffmpeg)
#       on the first 60-120 s of each video. A few minutes in all.
#   tools/spike/run-all.sh full <h264-long> <hevc-hvc1> <hevc-original> <mkv> <out-dir> [sections]
#       The whole battery behind docs/v3-measurements.md (3 runs each, about 2 h).
#       sections: any of "decode faces random ffmpeg combined" (default: all).
#
# Each command's output goes to <out-dir>/<name>.log; progress goes to stdout.
set -u
mode=${1:-}
scratch=~/Library/Caches/FrameSheet/spike
spike=$scratch/release/spike

build() {
  mkdir -p "$1"
  swift build -c release --package-path "${0:A:h}" --scratch-path "$scratch" > "$1/build.log" 2>&1 \
    || { echo "build failed, see $1/build.log"; exit 1; }
}

run() {
  local name=$1; shift
  echo "$(date '+%H:%M:%S') $name"
  "$spike" "$@" > "$out/$name.log" 2>&1 || echo "  FAILED: $name"
}

summary() {
  # One line per log: name and the median line the tool prints last.
  for f in "$out"/*.log(N); do
    [[ ${f:t} == build.log ]] && continue
    echo "${f:t:r}: $(grep -i median "$f" | tail -1)"
  done
}

if [[ $mode == quick ]]; then
  (( $# >= 3 )) || { echo "usage: $0 quick <out-dir> <video>..."; exit 2; }
  out=$2; shift 2
  build "$out"
  i=0
  for file in "$@"; do
    i=$((i + 1))
    run q$i-decode-720-bgra decode   "$file" --runs 1 --seconds 60 --max 720
    run q$i-combined-n10    combined "$file" --runs 1 --seconds 120 --every 10
    run q$i-random-exact    random   "$file" --runs 1
    if command -v ffmpeg > /dev/null; then
      run q$i-ffmpeg        ffmpeg   "$file" --runs 1 --seconds 60
    fi
  done
  run q1-faces-swift faces "$1" --runs 1 --frames 50
  echo "$(date '+%H:%M:%S') done"
  summary
  exit 0
fi

[[ $mode == full ]] || { echo "usage: $0 quick|full ... (see the header of this script)"; exit 2; }
shift
h264=$1 hevc=$2 hevc_orig=$3 mkv=$4 out=$5
sections=${6:-"decode faces random ffmpeg combined"}
build "$out"

# 1-2. Sequential decode and shot metric: first 5 min of the long H.264 film, whole HEVC file.
if [[ $sections == *decode* ]]; then
  for tag file range in h264 "$h264" "--seconds 300" hevc "$hevc" ""; do
    run decode-$tag-native-bgra     decode "$file" ${=range} --max 0
    run decode-$tag-native-420f     decode "$file" ${=range} --max 0 --format 420f
    run decode-$tag-240-bgra        decode "$file" ${=range} --max 240
    run decode-$tag-240-420f        decode "$file" ${=range} --max 240 --format 420f
    run decode-$tag-720-bgra        decode "$file" ${=range} --max 720
    run decode-$tag-720-420f        decode "$file" ${=range} --max 720 --format 420f
    run decode-$tag-240-bgra-vimage decode "$file" ${=range} --max 240 --scale vimage
    run decode-$tag-240-bgra-ci     decode "$file" ${=range} --max 240 --scale coreimage
    run decode-$tag-240-420f-ci     decode "$file" ${=range} --max 240 --format 420f --scale coreimage
    run decode-$tag-240-bgra-metric decode "$file" ${=range} --max 240 --metric
    run decode-$tag-240-420f-metric decode "$file" ${=range} --max 240 --format 420f --metric
  done
fi

# 3. Vision face rectangles at 720 px, 200 detections from 30 min into the film.
if [[ $sections == *faces* ]]; then
  for api in swift vn; do
    for device in default cpu gpu ane; do
      run faces-$api-$device faces "$h264" --api $api --device $device --start 1800 --every 30
    done
  done
  run faces-swift-rev3 faces "$h264" --api swift --revision 3 --start 1800 --every 30
  run faces-hevc-swift faces "$hevc" --api swift --start 120 --every 10
fi

# 5. Random access: 16 evenly spaced frames.
if [[ $sections == *random* ]]; then
  for tag file in hevc "$hevc" h264 "$h264"; do
    run random-$tag-exact random "$file"
    run random-$tag-tol05 random "$file" --tolerance 0.5
  done
fi

# 6. ffmpeg to a BGRA rawvideo pipe at 240 px (first 5 min, except the short HEVC file).
if [[ $sections == *ffmpeg* ]]; then
  run ffmpeg-h264    ffmpeg "$h264" --seconds 300
  run ffmpeg-h264-hw ffmpeg "$h264" --seconds 300 --hwaccel
  run ffmpeg-hevc    ffmpeg "$hevc_orig"
  run ffmpeg-hevc-hw ffmpeg "$hevc_orig" --hwaccel
  run ffmpeg-mkv     ffmpeg "$mkv" --seconds 300
fi

# 4. Combined pass: layouts on 5 min, then the whole film for N = 100 and N = 10.
if [[ $sections == *combined* ]]; then
  run combined-h264-300s-single combined "$h264" --seconds 300 --every 10 --layout single
  run combined-h264-300s-dual   combined "$h264" --seconds 300 --every 10 --layout dual
  run combined-h264-full-n100   combined "$h264" --every 100
  run combined-h264-full-n10    combined "$h264" --every 10
fi
echo "$(date '+%H:%M:%S') done"
