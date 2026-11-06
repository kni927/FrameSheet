# TASK: Save Sheet pauses playback first

Defined by the owner in FrameSheet TF #03's chat (2026-11-06), written by the
TF ("TASKs from the TF's chat", `docs/sessions.md`).

## Background

The owner's manual check of the second audit's B9: Save All Sheets pauses
the player (OK), but Save Sheet (M, ⌘S) while the player plays keeps
playing and saves too. The owner: Save Sheet should pause as well.

## Goal

Save Sheet pauses playback and waits for the decode gate before its first
decode, as Save All does.

## Scope

- `AppModel+Save.swift`: one helper for both saves.
- The task record; the audit 2 archive gets the owner's B9 result.

Out of scope: Save thumb and Save frame (Save frame pauses already).

## Verification

- `scripts/check.sh install` passes.
- The owner: play, then M: playback pauses and the sheet saves.

Estimate: 5 min.

## Implementation Result

Status: Completed

### Changes

- `Sources/FrameSheet/AppModel+Save.swift`: `pausePlaybackForSave()` and
  `playbackYielded()`, used by Save Sheet and Save All (playback pauses,
  then the save waits for the player's last decode and the DecodeGate).
- `docs/tasks/2026-11-06-01-audit2-fixes.md`: the owner's B9 result.

### Verification

- Build: `scripts/check.sh install`: 322 tests in 71 suites passed (1 known
  issue), no warnings, installed and launched by the script.
- Manual: not yet (the owner: play, then M).
- Cause of "keeps playing and saves" not determined: AVPlayer playback holds
  the DecodeGate while it plays (`PlayerController`), so an AVFoundation
  save would wait behind it; an ffmpeg-routed movie decodes outside the
  gate (by design). Either way the save now pauses first.

### Remaining Issues

None.

### Follow-up Suggestions

None.
