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

### 3. (Resolved) The zip carried the v2 version until v3 was tagged
* **Resolved**: v3.0.0 is tagged (2026-11-07); `build.sh` also takes
  `FRAMESHEET_VERSION`, which `scripts/release.sh` sets.

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

### 5. Open-GOP files decode only partly with AVFoundation
* **Description**: In an H.264 file whose sync samples are non-IDR I frames
  (open GOP, as some x264 muxers write), AVFoundation decoded 82 of 200
  sampled frames exactly (2026-11-03): every keyframe and every frame of a
  GOP without leading frames, but almost none in GOPs with leading frames.
  Software decoding fails the same way; an `AVAssetReader` that starts at a
  non-IDR keyframe stops with -11821/-12137, so reading from the previous GOP
  recovers only about half of the missed frames; reading from the start of the
  movie works. ffmpeg decodes these frames.
* **Reason**: Inferred from the measurements, not documented by Apple: the
  file's sample table marks the non-IDR I frames as full sync samples (none as
  partial sync), so AVFoundation starts decoding there and fails on frames that
  need the previous GOP.
* **Workaround**: Since T04b (decision 25) a missed frame is read from the
  previous GOP and then, with "Fetch exact frames with ffmpeg" on (default),
  fetched with ffmpeg, so every frame is exact (ffmpeg 0.1–0.4 s per frame).
  Without ffmpeg or with the option off, the nearest decodable frame is shown
  with its real number and a marker, and an inexact scrub is refused.

### 6. A scan timing test fails under memory pressure
* **Description**: `frequentThumbRequestsCostLittle` (`ScanTests.swift`)
  expects a scan with thumb requests every 100 ms to take at most 1.3× the
  scan alone plus 0.2 s. During T08 it failed in 3 of 7 `scripts/check.sh`
  runs (1.34×, 1.46×, 1.75×) and passed in the others (1.07–1.14×), which
  stops `scripts/check.sh install` before the build.
* **Reason**: Checked (2026-11-05): after the failing runs the load average
  was 8.6–9.1, with little free memory and active swapping. With apps closed
  (load average 3.8, no swap-outs), it passed at 1.13×. Which part of the load
  slows the shared run most is not measured. TF #03 (2026-11-05): 1 of 5
  runs failed at 2.53× with the scan alone at 11.29 s (9.6–9.9 s in the
  passing quiet runs, 1.08–1.10×); `top` is refused inside the sandbox, so
  the load was not recorded. 2026-11-06: once the scan alone took 26.74 s
  (6.01–9.01 s in the runs before and after) and the shared run passed the
  tests' 30 s watchdog, which ends the whole test run (`Hang: scan of
  long.mp4`); the rerun passed at 1.28×.
* **Workaround**: Close memory-heavy apps (browsers, a remote-screen app) and
  run again. Record the load (`top -l 2 -o cpu -n 8 -stats command,cpu`) as
  the `slowness-check` skill says when it recurs.

### 7. Face scopes at their boundaries
* **Description**: A sampled scope (every 10th / 100th frame) whose thumbs
  span no multiple of the step analyzes the lowest thumb instead (every
  100th over frames 37–42 analyzes 37); with every thumb hidden, a sampled
  scope's empty range becomes frames 0–0 and can analyze frame 0. The spec
  (§4, §6) still describes Add faces sheet's click as the default scope and
  press-and-hold as the menu, while the toolbar opens the menu on a click
  (owner, 2026-11-05).
* **Reason**: `FaceScanScope.frames` and `FaceSheetSource` fall back to the
  lowest thumb or frame 0 (second pre-release audit, 2026-11-06, traced).
* **Workaround**: None needed in normal use; the HQ decides the intended
  short-range behavior and updates the spec.

### 8. Large scans and saves work on the main actor
* **Description**: Reading and parsing scan caches, building the final
  scene list, rendering the whole print and encoding the library JSON run
  on the main actor; during `ImageRenderer`'s render Cancel cannot act. No
  stall was measured.
* **Reason**: Second pre-release audit (2026-11-06), traced in
  `AppModel+Faces.swift`, `AppModel+Scan.swift`, `AppModel+Save.swift`,
  `AppModel.swift` (`saveNow`).
* **Workaround**: Wait for the stage to end; measure with the
  `slowness-check` skill before moving work off the main actor.

### 9. Two saves at once can pick the same name with Overwrite off
* **Description**: Two Save Frame (or Save thumb) commands started together
  can both choose the same free name before either writes, and the atomic
  write then replaces the first file; the UUID name after `edit 99999` is
  not checked either.
* **Reason**: The free-name check (`FileNaming.outputURL`) and the write
  are separate steps (second pre-release audit, 2026-11-06, traced).
* **Workaround**: Wait for one save to finish before starting the next.

### 10. ffmpeg scans count frames after a seek or a timestamp gap
* **Description**: The ffmpeg resume and automatic IN/OUT paths seek half a
  frame early and number the buffers from the first one without checking
  timestamps; on the AVFoundation path a timestamp jump of 1,000 nominal
  frames or more hands the image to face analysis under the stored index.
* **Reason**: `ShotScanner.swift` (`runFFmpeg`, the gap handling) and
  `AutoInOut.swift` (second pre-release audit, 2026-11-06, traced; not in
  that TASK's scope).
* **Workaround**: Rescan from the start (movie menu) when a resumed scan's
  cuts look shifted.

### 11. ffmpeg 5.1 or later is needed
* **Description**: Frame runs (the frame strip) and ffmpeg playback pass
  `-fps_mode passthrough` (ffmpeg 5.1, 2022) so each pixel buffer pairs with
  its `showinfo` timestamp; an older ffmpeg rejects the option and those
  decodes fail.
* **Reason**: The second pre-release audit's fix (2026-11-06); no version
  check in `FFmpegLocator`.
* **Workaround**: Install a current ffmpeg (`brew install ffmpeg`).

### 12. Some commands still miss a source change while they wait
* **Description**: Save Sheet binds its movie and sheet when it starts, but
  a Replace or Undo during its wait for playback lets the new source supply
  the pixels while the name and embedded data are the old movie's; a scan
  cancelled by an undo can still drain old thumbnails into the cleared
  cache, and its deferred cleanup does not block a new scan; a player
  CHANGE/CUT and Save Frame's encoding do not check the generation before
  they commit.
* **Reason**: Third pre-release audit (2026-11-06) findings 2, 4 and 5,
  traced in `AppModel+Save.swift`, `AppModel+Transform.swift`,
  `AppModel+Faces.swift`, `PlayerController.swift`; not reproduced.
* **Workaround**: Do not replace or undo a movie while a save, scan or
  player edit of it runs.

### 13. Pipe readers outlive a child that keeps the pipes open
* **Description**: After its 2 s drain deadline `ProcessRunner` returns but
  leaves its blocked readers; `RawVideoPipe.finish` cannot reach its
  deadline when a descendant keeps stdout open.
* **Reason**: Third audit finding 6, traced; ffmpeg and ffprobe start no
  such children.
* **Workaround**: None needed with the system ffmpeg.

### 14. notarytool's own error can show the profile name
* **Description**: `scripts/release.sh` no longer prints the profile, but
  notarytool's diagnostic for a missing profile names it, and its output
  goes to the release log.
* **Reason**: Third audit finding 7 (the message text read from the tool's
  binary).
* **Workaround**: Check `~/.config/framesheet/notary-profile` before a
  release; the log stays on the Mac.

### 15. ffmpeg playback estimates timestamps after one late line
* **Description**: When a `showinfo` timestamp is 500 ms late, ffmpeg
  playback names the rest of its frames by an estimate at 1/fps.
* **Reason**: Third audit finding 8, traced in `FFmpegPlayback.swift`.
* **Workaround**: Pause and play again.

### 16. The duration probe reads the first video stream
* **Description**: For a file without a duration whose first video stream
  is a cover picture, the packet-timestamp probe uses `v:0` while decoding
  uses the selected stream: the duration can be wrong or missing.
* **Reason**: Third audit finding 9 (`FFmpegBackend.estimateDuration`).
* **Workaround**: None; such files are rare.

### 17. Imports keep at most 10,000 thumbs or scenes without saying so
* **Description**: `ImportLimits.maxItems` cuts a longer frame list or
  scene array and the import still reports success.
* **Reason**: Third audit finding 10.
* **Workaround**: Split very large sheets before exporting them.

### 18. Faces sheets without a stored source are not marked on Replace
* **Description**: Replace movie marks faces sheets for Apply only when
  they record their scan source; sheets from before Apply existed keep the
  old movie's face boxes unmarked.
* **Reason**: Third audit finding 11 (`Library.relink`).
* **Workaround**: Delete and remake such a faces sheet after Replace movie.

### 19. A terminated release run leaves its temporary files
* **Description**: `scripts/release.sh` cleans its worktree, build folder
  and archives on exit, but not when it is killed with SIGTERM.
* **Reason**: Third audit finding 12 (an `EXIT` trap only).
* **Workaround**: After an interrupted release, run `git worktree prune`
  and remove the leftover temporary folder.
