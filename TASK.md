# FrameSheet — Phase 3

## Tasks

1. Remove fast mode
   - Delete fast-mode extraction path, its UI toggle, and the
     keyframe-summary state cleared in loadVideo.
   - Normal mode (per-frame input seek, 5-way parallel) becomes
     the only generation path.
   - Update docs/architecture.md and known-issues.md; note the
     rationale (normal mode now runs in seconds; fast mode hung
     on WebM sources lacking cues) in docs/dev-log.md.

## Verification
- Build, smoke test, commit.
- Generate once each from an .mp4 and the problematic .webm.