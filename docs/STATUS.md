# Status

The current state of this repository, for the next session and for the owner:
what comes next, what is on hold, and what waits on the owner. Rewrite it
rather than append; keep it under about 40 lines. Rules are in `AGENTS.md`,
decisions in `docs/DECISIONS.md`, and history in `docs/tasks/` and Git.

Updated: 2026-11-03

## Summary

FrameSheet: macOS contact-sheet app, v2.3.1 released. v3 is a rebuild that
reproduces MoviePrint v0.2.23 for Apple Silicon: decisions 14–22 in
`docs/DECISIONS.md`, target behaviour in `docs/V3_SPEC.md`.

## Next

- Spike follow-ups: measure 4K HEVC and HDR once the owner has such files;
  re-measure on the fastest Mac before raising defaults; re-check decode speed
  with the macOS 27 `AVAssetReaderOutput.Provider` API.
- v3.0.0 order (owner, 2026-11-02): T03 interval editing (done) → T03b UI
  legibility pass (done) → T04 Save MoviePrint, header, naming,
  PNG/JSON export and import → T05 shot scan, timeline, cut/merge, EDL → T06
  player view → T07 faces Lv1 → T08 transforms, Save All, polish → version
  and release TASK.
- Tooltips on every control, kept short (owner, 2026-11-02/03).
- To the HQ for the spec (owner, 2026-11-03): SF fonts as the app default
  instead of IBM Plex; plain sheet names (e.g. screenshot-1) instead of
  MoviePrint-N; Save as a download button in the toolbar (T04); a player view
  button with T06. `docs/V3_SPEC.md` §4 and §6 still describe the floating
  toolbar, footer, no Preferences window and "Change thumb count".
- Not yet tried by the owner: Rename/Delete sheet, Locate, ⌃⌘F, the scrub at
  the smallest window size, ⌘Z while renaming.
- Builds and tests go through `scripts/check.sh` (`install` also installs
  and launches); it runs outside the sandbox without a dialog.

## On hold

- Face Lv2 (same-person grouping), after v3.0.0.
- Grid controls in the toolbar and no right panel (owner, 2026-11-03: pending,
  not dropped).
- Concurrent decodes above 1: measure per machine first (Ultra chips have two
  decode engines); see KNOWN_ISSUES 4.

## Waiting on owner

- None.

## Notes

- The repository is public: measurement and research files name no Mac
  model, chip, hostname or personal file. MoviePrint is MIT (keep its notice
  under `docs/licenses/` when porting code); PyMoviePrint has no LICENSE
  file, so use its ideas only, not its code.
