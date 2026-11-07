# Status

The current state of this repository, for the next session and for the owner:
what comes next, what is on hold, and what waits on the owner. Rewrite it
rather than append; keep it under about 40 lines. Rules are in `AGENTS.md`,
decisions in `docs/DECISIONS.md`, and history in `docs/tasks/` and Git.

Updated: 2026-11-07

## Summary

FrameSheet: macOS contact-sheet app, v3.0.0 released (2026-11-07, GitHub
Release with a notarized zip): a rebuild that reproduces MoviePrint v0.2.23
for Apple Silicon: decisions 14–27 in `docs/DECISIONS.md`, target behavior in
`docs/V3_SPEC.md`, release notes in `docs/release-notes/v3.0.0.md`.

## Next

- Spike follow-ups: measure 4K HEVC and HDR once the owner has such files;
  re-measure on the fastest Mac before raising defaults; re-check decode speed
  with the macOS 27 `AVAssetReaderOutput.Provider` API.
- Releases: `scripts/release.sh X.Y.Z [--dry-run]` on the Mac with the notary
  profile file; the owner tags the commit it prints; then `gh release create`.
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

- None.

## Notes

- The repository is public: measurement and research files name no Mac
  model, chip, hostname or personal file. MoviePrint is MIT (keep its notice
  under `docs/licenses/` when porting code); PyMoviePrint has no LICENSE
  file, so use its ideas only, not its code.
