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
- v3.0.0 order (owner, 2026-11-02): T03 interval editing (done) → T04 Save
  MoviePrint, header, naming, PNG/JSON export and import → T05 shot scan,
  timeline, cut/merge, EDL → T06 player view → T07 faces Lv1 → T08
  transforms, Save All, polish → version and release TASK.
- UI pass (owner, 2026-11-02): side by side with MoviePrint the v3 UI is
  still hard to read; detailed UI changes come in a later TASK. Tooltips on
  every control are wanted from now on.
- T03 items the owner has not tried yet: Rename/Delete sheet, Locate for a
  missing movie, ⌃⌘F, frame info position and colours, Columns undo.
- Builds and tests go through `scripts/check.sh` or `scripts/check.sh
  install`, spelled exactly so (exclusions match the exact string).

## On hold

- Face Lv2 (same-person grouping), after v3.0.0.

## Waiting on owner

- None.

## Notes

- The repository is public: measurement and research files name no Mac
  model, chip, hostname or personal file. MoviePrint is MIT (keep its notice
  under `docs/licenses/` when porting code); PyMoviePrint has no LICENSE
  file, so use its ideas only, not its code.
