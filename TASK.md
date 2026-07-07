# FrameSheet — Phase 2

## Tasks

1. Repo structure cleanup
   - Adopt: README.md and CLAUDE.md at root; all other docs
     under docs/ (dev-log.md, known-issues.md, archive of
     completed task lists as docs/tasks/YYYY-MM-*.md).
   - Move stray files accordingly; update any paths referenced
     in build.sh / CLAUDE.md.

2. App icon
   - docs/AppIcon.png exists but is actually JPEG data.
     Convert to real PNG (sips -s format png), decide final
     location per task 1 (suggest assets/AppIcon.png),
     point build.sh at it, verify iconset/icns generation.

3. Normal-mode generation speed (main task)
   - Investigate current ffmpeg invocation for non-fast mode.
     If it uses output seeking or a full-decode select filter,
     switch to input seeking: `ffmpeg -ss <t> -i <file> -frames:v 1`
     per frame (frame-accurate in modern ffmpeg).
   - Parallelize per-frame extraction (4–6 concurrent).
   - Target: 60-min H.264 source in seconds, not minutes.
   - Only if still insufficient: -hwaccel videotoolbox.

4. Cold-start race
   - Delay processing of a stashed Finder-open URL until the
     async ffmpeg dependency check completes.

## Deferred (do not implement)
- File > Open Recent submenu via AppKit hack — revisit only if
  Dock/Apple-menu recents prove insufficient in daily use.

## Verification
- Build after each task, commit per task.
- Task 3: time normal-mode generation on a ~60-min video
  before/after and record numbers in dev-log.md.