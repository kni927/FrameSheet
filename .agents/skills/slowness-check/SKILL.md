---
name: slowness-check
description: First steps when the owner reports that FrameSheet is slow (a scan, the grid, the player, a save, thumbs loading). Take a timing log and measure under the same conditions before stating any cause. Use before explaining or fixing any slowness.
---

# Slowness check

`docs/sessions.md` ("Causes") is the rule: measure before stating a cause,
and mark each cause `Checked:` with the numbers or `Guess:` with the check
that would settle it. This is the FrameSheet procedure (owner, 2026-11-04,
after T07, where three guessed causes were wrong and a timing log found the
real one: machine load, 18.8 s quiet against 33 s under load).

1. **Write down the case.** What was slow, on which movie (described
   generically: codec, resolution, fps, length, open-GOP or not), which
   action, and how long it took for the owner.
2. **Record the machine's load at the same time.** Run
   `top -l 2 -o cpu -n 8 -stats command,cpu` once before reproducing, and
   note any other app above about 20 % CPU (a remote-screen app, a build,
   Spotlight). Ask the owner which apps were open if you cannot see them.
3. **Take the timing log.** Reproduce once in the app and read the newest
   block of `~/Library/Logs/FrameSheet/scan.log` (scans write it: a header
   line, then `<ms since start> <event>`, with main-actor and thumb-request
   totals at the end). For a slowness outside scans, add timing lines for
   that path the same way (a short-lived `ScanLog`-style log) before
   changing behavior, and remove or keep them as the TASK says.
4. **Compare under the same conditions.** Repeat the action once with the
   load from step 2 gone (or present, if it was gone), and once outside the
   app where a probe exists (`tools/spike/run-all.sh quick` for decode and
   scan speed; it runs outside the sandbox as listed in `CLAUDE.md`).
5. **Report numbers, then the cause.** Give the times from steps 3 and 4 in
   a small table, then the cause marked `Checked:` (the numbers show it) or
   `Guess:` (with the next check). Change code only for a checked cause; a
   fix is verified by the same measurement.

Never commit logs or movie names (public repository); quote only the
numbers and generic descriptions.
