# Status

The current state of this repository, for the next session and for the owner:
what comes next, what is on hold, and what waits on the owner. Rewrite it
rather than append; keep it under about 40 lines. Rules are in `AGENTS.md`,
decisions in `docs/DECISIONS.md`, and history in `docs/tasks/` and Git.

Updated: 2026-11-02

## Summary

FrameSheet: macOS contact-sheet app, v2.3.1 released. v3 is a rebuild that
reproduces MoviePrint v0.2.23 for Apple Silicon: decisions 14–22 in
`docs/DECISIONS.md`, target behaviour in `docs/V3_SPEC.md`.

## Next

- Spike follow-ups: measure 4K HEVC and HDR once the owner has such files;
  re-measure on the fastest Mac before raising defaults; re-check decode speed
  with the macOS 27 `AVAssetReaderOutput.Provider` API.
- The v3 skeleton is on `main` (Swift package, core model, decode layer with
  ffmpeg routing and discovery, minimal app with a default interval sheet,
  `build.sh`; v2 `src/` removed). Next: the features in the order of
  `docs/V3_SPEC.md`; the kni Design System's type and spacing tokens are a
  later TASK.
- Builds and tests go through `scripts/check.sh` (listed in
  `sandbox.excludedCommands`; owner approved 2026-11-02).

## On hold

- Face Lv2 (same-person grouping), after v3.0.0.

## Waiting on owner

- None.

## Notes

- The repository is public: measurement and research files name no Mac
  model, chip, hostname or personal file. MoviePrint is MIT (keep its notice
  under `docs/licenses/` when porting code); PyMoviePrint has no LICENSE
  file, so use its ideas only, not its code.
