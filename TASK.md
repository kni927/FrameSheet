# TASK: Phase 3a Wrap-up — Keyboard Support, Test-Video Harness, ARCHITECTURE Refresh, v2.2.0

## Context

Closes out Phase 3a (PR #8, commits e081e37..5a0827c on main). Three
follow-ups recorded in the task archive plus the release tag. Small,
mixed task: one feature (keyboard), one harness extension, one docs
refresh, then tag.

## Part 1 — Keyboard support for the thumbnail grid (feature)

Add a selection model + keyboard operations to `ThumbnailGridView`:

- **Selection**: click selects a cell (visible focus ring using the
  accent color); Esc clears selection. Single selection only — no
  multi-select in this task.
- **Arrow keys**: move selection in raster order (Left/Right) and by
  column stride (Up/Down), respecting the current re-flow (hidden
  cells are skipped, matching the visual layout).
- **Space or Delete**: toggle hide on the selected cell (same code
  path as the hover eye button; selection stays on the cell so it can
  be un-hidden immediately).
- **`,` / `.`** (or `[` / `]` — pick whichever doesn't collide with
  existing shortcuts, and document the choice): nudge the selected
  cell's timestamp back/forward by the configured step — same code
  path as the `< >` overlay buttons.
- Focus handling: keyboard ops must work after clicking the grid;
  don't steal keys from sidebar text fields (template field, etc.).
  On macOS 11 target, this likely means an `NSViewRepresentable`
  key-capture layer or `NSEvent` local monitor rather than SwiftUI
  `.onKeyPress` (macOS 14+) — same API-availability discipline as
  Stage C's drag decision.

### Part 1 verification

- All four operations verified in GUI; nudge/hide via keyboard produce
  byte-identical exports to the same operations via mouse.
- Typing in the filename-template field does not trigger grid
  shortcuts.

## Part 2 — Real-video smoke tests (harness)

Extend the CLI harness to run against
`docs/references/Royalty Free Videos/` (git-ignored, present locally):

- Discover `*.mp4`, `*.webm`, `*.mov` in that folder; **skip with a
  clear message if the folder is absent or empty** (CI/fresh clones
  must still pass).
- Per file: generate at default settings; assert non-empty output,
  expected cell count, and sane duration detection (duration fallback
  path exercised where metadata is missing).
- WebM is a named regression target (historical fast-mode hang):
  include a generation-completes-within-timeout assertion for it.
- Record the harness's new section in `docs/DEV_LOG.md`.

## Part 3 — `docs/ARCHITECTURE.md` refresh (docs)

Rewrite the stale component-detail sections to match reality:

- `src/` layout (post-housekeeping), file-by-file responsibilities.
- The Phase 1 split: `AppState` extensions, `ContactSheetRenderer` as
  the single source of truth via `drawCell`.
- The Phase 3a grid/cell model: `Thumbnail` array, `LazyVGrid` display
  path vs. export path, re-flow rule, selection model from Part 1.
- Remove/update anything still describing the tabbed sidebar or
  monolithic `main.swift` (mark superseded rather than silently
  deleting where historical context helps).

## Part 4 — Release v2.2.0

After Parts 1–3 are merged to `main`:

- Tag `v2.2.0` on the merge commit. Tag message: Phase 3a
  per-thumbnail interactivity (addressable grid, hover/hide,
  drag-reorder, per-cell nudge) + keyboard support.
- Harness/docs work need not be listed as release content.

## Wrap-up

- `docs/DEV_LOG.md` entries; keyboard-shortcut choices recorded in
  `docs/DECISIONS.md`.
- Archive this task to `docs/tasks/`.

## Constraints

- No Phase 3b work (multi-movie, batch, timeline scrubber stay
  pending). No multi-select.
- Follow `AGENTS.md` / `CLAUDE.md`. Branch off current `main`.
- Parts may share one branch/PR but keep feature (Part 1), harness
  (Part 2), and docs (Part 3) as separate commits.
