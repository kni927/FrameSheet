# TASK: README screenshot

From: FrameSheet HQ, for FrameSheet TF #03 (via the Mac relay, 2026-11-07).
Owner approved in HQ chat, 2026-11-07: "go". Estimate: 5 min.

Context: the owner's manual checks are all done (finding 3 / C via undo after Replace, B10: OK). This is the last change before TF #02 releases v3.0.0.

1. Take the owner's screenshot from Google Drive `AI/Handoff/FrameSheet/Screenshot-01.png` (3.6 MB; the main window with Tears of Steel, Big Buck Bunny, Sintel and a Jellyfin HEVC test file; paths show as `~/Downloads/sample-video`, which the owner accepts for the public repository).
2. Scale it to about 1600 px wide (`sips -Z 1600` or similar; keep PNG, aim well under 1 MB) and save it as `assets/screenshot.png`.
3. Put it at the top of README.md, under the intro paragraph: `![FrameSheet v3 main window](assets/screenshot.png)`. Change nothing else in README.
4. Check: the image shows no home path with a user name, no hostname, no Mac model (open it and look); run `scripts/check.sh build` only if you touch code (you should not).
5. Commit (`docs: README screenshot`), fetch/merge, push to main, archive in docs/tasks/, report to the HQ with Took:.

FYI: `.claude/settings.json` on main now lets the sandbox write `~/Library/Caches/FrameSheet` (Logbook, owner approved). If you run a build later, try once `swift build --scratch-path ~/Library/Caches/FrameSheet/build` inside the sandbox and report the exact error (or success), so the HQ knows whether SwiftPM still needs check.sh outside it.

## Progress

- 2026-11-07 12:46 JST: TASK received through the Mac relay; `TASK.md` written.

## Implementation Result

Status: Completed

### Changes

- `assets/screenshot.png` (new): the owner's screenshot scaled from
  3326×1776 to 1600×854, PNG without alpha, 804 KB (ffmpeg; `sips` could
  not write its temporary file inside the sandbox).
- `README.md`: the image line after the introduction (the two opening
  paragraphs), before "Download"; nothing else changed.

### Verification

- Looked at the image: only `~/Downloads/sample-video` paths; no home path
  with a user name, no hostname, no Mac model.
  `scripts/check-private-paths.sh assets/screenshot.png`: 0; no Mac model
  name or "hostname" in its bytes.
- No code changed, so no build.
- SwiftPM inside the sandbox (asked by the HQ), once each:
  `swift build --scratch-path ~/Library/Caches/FrameSheet/build` failed at
  the manifest: `sandbox-exec: sandbox_apply: Operation not permitted`
  (SwiftPM's own sandbox inside Claude Code's). With `--disable-sandbox` it
  got past the manifest and failed writing
  `~/Library/Caches/FrameSheet/build/out/Intermediates.noindex/XCBuildData/<hash>.xcbuilddata/manifest.json`
  ("Operation not permitted", NSCocoaErrorDomain 513), then "Unexpected
  build state"; `~/Library/org.swift.swiftpm` and
  `~/Library/Caches/org.swift.swiftpm` were not writable either (warnings).
  So `scripts/check.sh` outside the sandbox is still needed.

### Remaining Issues

None.
