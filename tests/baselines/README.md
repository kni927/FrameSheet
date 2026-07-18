# Verification Baselines

Reference contact-sheet outputs used by the CLI verification harness for
per-backend byte-diff checks. Sources are the local sample videos in
`docs/reference/Royalty Free Videos/` (git-ignored), generated at default
settings (4×4 grid, 1200px, header + timestamps).

| File | Source | Decode backend when captured |
|---|---|---|
| `tos-mov-default.png` | ToS-4k-1920.mov (H.264) | AVFoundation (VideoToolbox) |
| `bbb-mp4-default.png` | Big Buck Bunny HD.mp4 (AV1) | ffmpeg fallback — AV1 has no hardware decode before M3, so on the capture machine (M1) routing correctly falls back |

Baselines are machine-anchored (hardware decoder output can differ across
chips). Regenerate with the smoke harness when the render or decode
pipeline intentionally changes, and record the change in docs/DEV_LOG.md.
