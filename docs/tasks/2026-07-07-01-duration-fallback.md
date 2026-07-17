# FrameSheet — Phase 4

## Tasks

0. Housekeeping
   - Archive Phase 2/3 task lists to docs/tasks/.

1. Duration fallback for files lacking metadata
   - If ffprobe format/stream duration is missing, N/A, or 0,
     estimate duration by demux-only packet scan (e.g. read
     last packet pts via ffprobe; if the container cannot seek
     to the end, fall back to a full -show_packets scan of
     pts_time and take the max).
   - Show a brief "estimating duration…" state in the UI while
     scanning, and make it cancellable.
   - Guard: if estimation still fails, surface a clear error
     instead of silently producing a sheet of identical frames.

## Verification
- Build, smoke test, commit.
- Test with: normal .mp4, the ~2h15m a.webm (duration present,
  must not regress), and a synthesized cues-less/duration-less
  WebM (Claude Code already knows how to generate one via pipe).

## Implementation Result

**Status:**
- Completed

### Changes

- Archived Phase 2/3 task lists to `docs/tasks/`.
- Added `estimateDuration` duration-fallback logic (`main.swift`): when
  ffprobe's format/stream duration is missing, `N/A`, or 0, the app
  estimates duration from packet timestamps — attempt 1 seeks to a
  late timestamp and reads trailing packets' `pts_time`; attempt 2
  falls back to a full `-show_entries packet=pts_time` scan taking the
  max. The canvas shows an "Estimating duration…" state with a
  cancellable action (wired to the sidebar Cancel), and a clear error
  surfaces if estimation still fails.

### Verification

- Build: passed (see `docs/DEV_LOG.md`, "Phase 4" entry)
- Automated verification: none
- Manual verification: normal `.mp4` and a 2h15m VP9 `.webm` with
  duration metadata generate immediately (no regression); a
  synthesized cues-less/duration-less WebM produced a correct
  evenly-spaced sheet (estimated 29.967 s) instead of 16 copies of
  frame 0.

### Remaining Issues

- None

### Follow-up Suggestions

- None