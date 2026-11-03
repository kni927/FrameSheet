# Known Issues - FrameSheet

Unresolved, reproducible problems in v3. The v2 issues (font fallback and
font paths in the CoreGraphics renderer, Fast Mode, preview flicker during
auto-fit) applied to code removed with the v3 skeleton; they stay in the
history of this file up to tag v2.3.1.

---

### 1. Duration estimation can be slow on large un-indexed files (ffmpeg path)
* **Description**: For files whose metadata lacks a duration (e.g. WebM
  without cues), the ffmpeg path scans packet timestamps; on
  multi-gigabyte un-indexed sources this can take a while (IO-bound, no
  decoding).
* **Reason**: Without an index or cues the container cannot be seeked to its
  end, so every packet header must be read to find the last timestamp.
* **Workaround**: None yet; v3 shows no progress for it while a movie is
  being added. Files with duration metadata skip the scan.

### 2. Frame count on the ffmpeg path is estimated from the duration
* **Description**: Containers without a frame count (MKV, WebM) get
  duration × fps, which can exceed the real count by a few frames. The last
  interval thumb then falls back to a frame about 0.5 s earlier (the thumb
  takes that frame number).
* **Reason**: Counting frames exactly needs a full packet scan.
* **Workaround**: None needed for interval sheets; the shot scan (not built
  yet) will count frames as it reads them.

### 3. The zip carries the v2 version until v3 is tagged
* **Description**: `build.sh` names the zip and sets
  `CFBundleShortVersionString` from the latest tag, which is still v2.3.1.
* **Workaround**: Expected; the version changes when v3 is tagged (a task of
  its own).

### 4. Hardware decoder kernel panic under many parallel decodes
* **Description**: Twice (2026-11-02, 2026-11-03) the Mac rebooted with a
  kernel panic in the hardware video decoder driver (`AppleAVD`, process
  `VTDecoderXPCService`, macOS 27.2) while FrameSheet reloaded evicted
  thumbs in a loop and opened many decoder sessions at once.
* **Reason**: A driver bug in macOS; FrameSheet's burst of parallel
  sessions triggered it (inferred from the panic logs, not reproduced).
* **Workaround**: Since T03b all AVFoundation decodes pass one `DecodeGate`
  (one at a time), the shown images are pinned and reloads are throttled; no
  panic since. Raising the gate waits for a per-machine measurement.
