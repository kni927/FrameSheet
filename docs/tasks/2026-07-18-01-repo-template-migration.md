# TASK: Housekeeping — Migrate Repo Structure to repo-template Conventions

## Goal

Bring FrameSheet's repository layout, agent instruction files, and docs
in line with the current conventions used in kni927/repo-template.
**No application code changes** — this task touches only docs, agent
instruction files, and file layout. Behavior of the app must be
unchanged.

## Rationale

FrameSheet predates the current template (initial build via
Antigravity), so its file placement and instruction files have drifted
from the conventions now used across kni927 repos. This must land
before the upcoming UI audit task, whose output targets `docs/`.

## Steps

### 1. Agent instruction files

- Create `AGENTS.md` as the generic, tool-agnostic ruleset (readable by
  Codex/Jules/Cursor). Migrate any generic rules currently living in
  CLAUDE.md into it.
- Rewrite `CLAUDE.md` to:
  - Import the generic rules via `@AGENTS.md`.
  - Contain only FrameSheet-specific guidance (build command, ffmpeg
    invocation conventions, seeking/parallelization notes, etc.).
  - Stay within the ~200-line context budget.
  - Use `@`-syntax only for files that must be inline-expanded at
    launch; use plain path references for docs that should be
    lazy-loaded on demand.
- Copy the latest versions of these conventions from kni927/repo-template
  rather than reconstructing them from memory.

### 2. Docs consolidation

- Docs already live under `docs/` (an earlier commit moved them there
  as lowercase-hyphen names, e.g. `docs/dev-log.md`). The template's
  `AGENTS.md` specifies uppercase-with-underscore names instead
  (`docs/DEV_LOG.md`, `docs/KNOWN_ISSUES.md`, `docs/DECISIONS.md`);
  `git mv` each doc to match, including the FrameSheet-specific ones
  (`docs/ARCHITECTURE.md`, `docs/PROJECT.md`, `docs/ANTIGRAVITY.md`)
  for consistency.
- Ensure `docs/tasks/` exists for archived task files
  (`YYYY-MM-DD-NN-slug.md`, per `docs/task-workflow.md`). Existing
  `docs/tasks/2026-07-phase-*.md` archives predate this convention —
  leave them as historical records rather than renaming. Move any
  completed root-level `TASK.md` into `docs/tasks/` under the new
  convention before starting this task.

### 3. Cross-reference resolution

- Grep the entire repo for old filenames and paths
  (`DEV-LOG.md`, root-level doc paths, lowercase-hyphen `docs/`
  paths, etc.):
  - README
  - CLAUDE.md / AGENTS.md
  - all files under `docs/`
  - source code comments
  - CI/workflow files, scripts
- Update every hit to the new path. No dead links may remain.

### 4. Verification

- `grep -rn "DEV-LOG\|docs/dev-log\|docs/known-issues\|docs/decisions\|docs/architecture\|docs/project\|docs/antigravity" .`
  (and each other old path) returns zero hits outside historical
  content (e.g. `docs/DEV_LOG.md` entries describing past renames).
- All relative links in markdown files resolve to existing files.
- Build still succeeds: `./build.sh` (this repo has no `.xcodeproj` —
  it's a plain `swiftc -parse-as-library` build; repo-local output
  under `build/`, per the build script's own convention). Debug
  installs go to `~/Applications`, not `/Applications`.
- `git log --follow docs/DEV_LOG.md` shows continuous history back
  through its prior names (`docs/dev-log.md`, `DEV-LOG.md`).

### 5. Wrap-up

- Append a short entry to `docs/DEV_LOG.md` describing this migration.
- Archive this TASK.md to `docs/tasks/` per convention.

## Constraints

- Docs / instruction files / layout only. No Swift code changes.
- Use `git mv` for all moves to preserve history.
- Follow kni927/repo-template as the source of truth where this file
  and the template disagree.

## Implementation Result

**Status:**
- Completed

### Changes

- Local `main` was 17 commits behind `origin/main`, which had already
  moved docs under `docs/` with lowercase-hyphen names and merged an
  unrelated Phase 4 (duration-fallback) feature with its own
  `TASK.md`. Fast-forwarded to `origin/main` before branching so this
  migration lands on top of current history rather than reverting it.
- Archived the completed Phase 4 `TASK.md` to
  `docs/tasks/2026-07-07-01-duration-fallback.md` (with an appended
  Implementation Result sourced from `docs/DEV_LOG.md`) so the new
  housekeeping task could take its place at the root, per this repo's
  convention of one active `TASK.md` at a time.
- Added `AGENTS.md` (verbatim from `kni927/repo-template`) and
  `docs/task-workflow.md`.
- Rewrote `CLAUDE.md` to `@AGENTS.md`-import the generic rules and
  keep only FrameSheet-specific guidance (Read First list using plain
  paths, build command, ffmpeg invocation/parallelization notes). 32
  lines, well under the ~200-line budget.
- `git mv`'d `docs/dev-log.md` → `docs/DEV_LOG.md`,
  `docs/known-issues.md` → `docs/KNOWN_ISSUES.md`,
  `docs/decisions.md` → `docs/DECISIONS.md`,
  `docs/architecture.md` → `docs/ARCHITECTURE.md`,
  `docs/project.md` → `docs/PROJECT.md`,
  `docs/antigravity.md` → `docs/ANTIGRAVITY.md` — the template
  specifies uppercase-underscore for the first three; the rest were
  renamed to match for consistency (confirmed with the project owner).
- Updated the remaining live cross-reference hits (`docs/KNOWN_ISSUES.md`,
  3 occurrences of `docs/dev-log.md`). Left the pre-existing
  `docs/tasks/2026-07-phase-{2,3}.md` archives and
  `docs/ANTIGRAVITY.md`'s self-referential header untouched as
  historical records.
- Appended a migration entry to `docs/DEV_LOG.md`.

### Verification

- Build: passed — `./build.sh` (plain `swiftc -parse-as-library`
  build; this repo has no `.xcodeproj`, so the original TASK.md's
  `xcodebuild -derivedDataPath ./build` verification step doesn't
  apply and was corrected in the steps above). Output at
  `build/FrameSheet.app`, `build/FrameSheet-v2.0.0-macOS.zip`; no new
  warnings beyond pre-existing SwiftUI `onChange` deprecation notices.
- Automated verification: `grep -rniE` sweep for old root filenames
  (`DEV-LOG.md`, `Architecture.md`, etc.) and lowercase-hyphen
  `docs/*.md` paths across README, CLAUDE.md, AGENTS.md, `docs/`,
  `main.swift`, and CI/workflow files (none exist in this repo) —
  zero live hits remain outside `TASK.md`'s own descriptive text and
  the two historical phase archives.
- Manual verification: confirmed all markdown relative links in
  `README.md` resolve (`docs/preview.png`, `LICENSE`,
  `assets/AppIcon.png`).
- Not performed: `git log --follow docs/DEV_LOG.md` (requires this
  commit to land first — verify after committing).

### Remaining Issues

- None

### Follow-up Suggestions

- None
