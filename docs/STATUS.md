# Status

The current state of this repository, for the next session and for the owner:
what comes next, what is on hold, and what waits on the owner. Rewrite it
rather than append; keep it under about 40 lines. Rules are in `AGENTS.md`,
decisions in `docs/DECISIONS.md`, and history in `docs/tasks/` and Git.

Updated: 2026-11-05

## Summary

FrameSheet: macOS contact-sheet app, v2.3.1 released. v3 is a rebuild that
reproduces MoviePrint v0.2.23 for Apple Silicon: decisions 14–22 in
`docs/DECISIONS.md`, target behavior in `docs/V3_SPEC.md`.

## Next

- Spike follow-ups: measure 4K HEVC and HDR once the owner has such files;
  re-measure on the fastest Mac before raising defaults; re-check decode speed
  with the macOS 27 `AVAssetReaderOutput.Provider` API.
- v3.0.0 order (owner, 2026-11-02): T03 → T03b → T04 → T04b → T05 → T06 →
  T07 → T08 transforms, Save All, polish (all done) → v3.0.0 release with a
  notarized zip on a GitHub Release (TF #02). The Codex pre-release audit's
  findings are fixed on `main` (TF #03, 2026-11-05: 15 confirmed and fixed,
  finding 12 refuted; `docs/tasks/2026-11-05-02-audit-fixes.md`), so the
  second Codex audit's fixes are on `main` too (TF #03, 2026-11-06: A, B, C
  fixed, D in KNOWN_ISSUES 7–11; `docs/tasks/2026-11-06-01-audit2-fixes.md`;
  release dry run passed), so a changes-only third audit comes next, and
  the release unless it finds a blocker (owner, 2026-11-06). Manual checks of the first fixes: 1, 5, 10 OK; 9, 13,
  14 skipped. UI round 1 done (`docs/tasks/2026-11-05-03-toolbar-menus.md`;
  decision 27).
- Face follow-ups (owner, 2026-11-04): a "per shot" scope (the middle frame of
  each scene); more Vision workers on chips with two Neural Engines (measure
  first).
- Audio for ffmpeg playback (deferred from T08; the "no audio" label stays).
- Spec wording (T08): full screen is 🌐F on macOS 27 (§8 says ⌃⌘F); the crop
  is in the rotated frame's pixels (§3 says source pixels).
- Run `tools/spike/run-all.sh quick` once with a rotated and a cropped movie.
- Scans and timing tests run slower under load (a remote-screen app, a
  browser using much memory): KNOWN_ISSUES 6.
- Tooltips on every control, kept short (owner, 2026-11-02/03).
- Not yet tried by the owner: MoviePrint 0.2.23 files (only 0.2.12 runs on
  the owner's Mac).
- Builds and tests go through `scripts/check.sh` (`install` also installs
  and launches); it runs outside the sandbox without a dialog; `stop` ends a
  hung run.

## On hold

- Face Lv2 (same-person grouping), after v3.0.0.
- Grid controls in the toolbar and no right panel (owner, 2026-11-03: pending,
  not dropped).
- Concurrent decodes above 1: measure per machine first (Ultra chips have two
  decode engines); see KNOWN_ISSUES 4.

## Waiting on owner

- Manual check of the second audit's fixes on the owner's Mac: B9 OK (Save
  All, 2026-11-06); B10 and C (Replace → undo with the player open) and Save
  Sheet while playing (aae1e27) still to check; B11 needs a file whose frames
  decode only as neighbors (skip without one). Steps:
  `docs/tasks/2026-11-06-01-audit2-fixes.md`.
- The releasing Mac needs the notary profile's name in
  `~/.config/framesheet/notary-profile` (or `FRAMESHEET_NOTARY_PROFILE`);
  `scripts/release.sh` no longer has a default.

## Notes

- The repository is public: measurement and research files name no Mac
  model, chip, hostname or personal file. MoviePrint is MIT (keep its notice
  under `docs/licenses/` when porting code); PyMoviePrint has no LICENSE
  file, so use its ideas only, not its code.
