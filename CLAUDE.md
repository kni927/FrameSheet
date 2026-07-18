# CLAUDE.md
@AGENTS.md

## Read First

Before making changes, read:

1. docs/PROJECT.md
2. docs/ARCHITECTURE.md
3. docs/DECISIONS.md
4. docs/KNOWN_ISSUES.md
5. docs/ANTIGRAVITY.md

## Build

- Build: `./build.sh` — compiles the Swift sources under `src/` via `swiftc -parse-as-library`, packages `build/FrameSheet.app`, codesigns with the Developer ID Application identity (`FRAMESHEET_SIGN_IDENTITY` override; ad-hoc fallback), and zips it. Version comes from the latest git tag. Repo-local output only.
- Debug installs go to `~/Applications`, never `/Applications`.

## Development Rules

- Preserve the current SwiftUI architecture.
- Do not bundle FFmpeg — the app shells out to a system-installed `ffmpeg`/`ffprobe`, checked on launch.
- `vcsi` has been removed entirely as of v2.0.0; do not reintroduce it or any Python dependency.
- Keep UI text in English.
- Prefer small targeted fixes over large refactors.
- Do not remove historical information from docs/ANTIGRAVITY.md.

## FFmpeg Conventions

- Frame extraction uses one input-seeking invocation per frame (`ffmpeg -ss <t> -i <file> -frames:v 1`), run 5-way concurrent via `runParallelFrameExtraction()` — not a single-pass `fps=1/interval` filter, and not `-hwaccel videotoolbox` (decoder init overhead dominates for single-frame decodes; software decode is cheap per GOP).
- Temporary thumbnails are written as JPEG (`-q:v 3`), not PNG, to minimize I/O overhead.
- Duration is read from ffprobe format/stream duration first. If missing, `N/A`, or 0, `estimateDuration` falls back to a packet-timestamp scan before generation proceeds — see docs/DEV_LOG.md ("Phase 4") for the two-attempt strategy.
