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