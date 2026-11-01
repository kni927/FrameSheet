# Status

The current state of this repository, for the next session and for the owner:
what comes next, what is on hold, and what waits on the owner. Rewrite it
rather than append; keep it under about 40 lines. Rules are in `AGENTS.md`,
decisions in `docs/DECISIONS.md`, and history in `docs/tasks/` and Git.

Updated: 2026-11-01

## Summary

FrameSheet: macOS contact-sheet app, v2.3.1 released. v3 is a rebuild that
reproduces MoviePrint v0.2.23 for Apple Silicon (owner, 2026-11-01).

## Next

- v3 planning: the owner's research and decisions are in Google Drive
  `AI/Handoff/FrameSheet/FrameSheet-v3-research-2026-11-01-rev2.md`. Record
  the owner decisions in `docs/DECISIONS.md` and write the v3 spec in `docs/`.
- `CLAUDE.md` Development Rules and FFmpeg Conventions describe v2 ("preserve
  the current SwiftUI architecture", "small targeted fixes"); revise them for
  v3 with the owner's approval naming `CLAUDE.md`.
- First v3 task suggested by the research: a measurement spike on a Mac
  (decode speed, Vision face detection per frame).

## On hold

- None.

## Waiting on owner

- None.

## Notes

- 2026-11-01: rules synced with repo-template; the repository is public, so
  the research file's machine details stay out of committed files.
  MoviePrint is MIT (keep its notice when porting code); PyMoviePrint has no
  LICENSE file, so use its ideas only, not its code.
