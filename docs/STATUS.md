# Status

The current state of this repository, for the next session and for the owner:
what comes next, what is on hold, and what waits on the owner. Rewrite it
rather than append; keep it under about 40 lines. Rules are in `AGENTS.md`,
decisions in `docs/DECISIONS.md`, and history in `docs/tasks/` and Git.

Updated: 2026-11-01

## Summary

FrameSheet: macOS contact-sheet app, v2.3.1 released. v3 is a rebuild that
reproduces MoviePrint v0.2.23 for Apple Silicon: decisions 14–21 in
`docs/DECISIONS.md`, target behaviour in `docs/V3_SPEC.md`.

## Next

- In progress: TF #01 v3-spike on a Mac — decode, shot-scan and Vision face
  measurements into `docs/v3-measurements.md`; fills the **(measure)** items
  in the spec.
- `CLAUDE.md` Development Rules, Commands and FFmpeg Conventions still
  describe v2; the HQ proposed v3 text to the owner (needs the owner's
  approval naming `CLAUDE.md`).
- Then: v3 skeleton (Swift package, core models, ported decode backends and
  renderer, ffmpeg discovery; v2 `src/` removed), then the features in the
  order of `docs/V3_SPEC.md`.
- `docs/PROJECT.md` and `docs/ARCHITECTURE.md` describe v2; rewrite them with
  the skeleton TASK.

## On hold

- Face Lv2 (same-person grouping), after v3.0.0.

## Waiting on owner

- Spec open items (`docs/V3_SPEC.md` §13), before the TASKs that build them.

## Notes

- The repository is public: measurement and research files name no Mac
  model, chip, hostname or personal file. MoviePrint is MIT (keep its notice
  under `docs/licenses/` when porting code); PyMoviePrint has no LICENSE
  file, so use its ideas only, not its code.
