# TASK: Phase 3a — Per-Thumbnail Interactivity

## Context

Follow-up to `docs/UI_AUDIT.md` §5 Phase 3, scoped to the "go" portion
only (per Decisions: multi-movie list panel, batch create, and timeline
scrubber remain **pending** — do not build toward them).

This is the largest structural change to date: the preview moves from
a single flattened bitmap to an addressable grid of cells backed by
the `Thumbnail` array introduced in Phase 1. Split into stages;
**verify and commit each stage separately** (same discipline as
Phase 1).

## Stage A — Addressable grid (behavior-preserving)

Replace the single `Image(nsImage: previewImage)` display with a
`LazyVGrid` of `ThumbnailCellView`, one per `Thumbnail`, laid out with
the existing columns/rows/spacing/margin parameters. Compose the final
export image the same way it's composed today (via
`ContactSheetRenderer`, from the `Thumbnail` array) — Stage A changes
*display only*, not export.

- Each `Thumbnail` needs its own rendered `NSImage`/`CGImage` (border,
  corner radius, header text) rather than being drawn only inside one
  flattened composite. Reuse the per-cell drawing code already inside
  `ContactSheetRenderer` — extract it into a function that can render
  either one cell (for display) or the full sheet (for export), so
  there's one source of truth for cell appearance.
- Grid interaction (click, drag, keyboard) not yet — this stage is
  "looks the same, but is now N addressable views instead of 1 image."

### Stage A verification

- Screenshot-diff: exported contact sheet pixel-identical to
  pre-change output at default settings (same byte-diff harness).
- Visual inspection: on-screen grid indistinguishable from the old
  flattened preview at 100% zoom.
- All existing settings (corner radius, colors, alpha, JPEG export
  from Phase 2) still apply correctly per-cell and in the export.

## Stage B — Hover overlay + hide

- Hover over a cell shows an overlay (semi-transparent scrim +
  timestamp + a hide/eye-slash button), matching MoviePrint's
  reference screenshots.
- Hide: toggles `Thumbnail.hidden`. Hidden cells are dimmed/marked in
  the grid (not removed from the array — order and timestamps must be
  preservable) and excluded from the exported sheet. Grid re-flows
  (remaining visible cells fill the rows/columns) — decide and
  document whether re-flow re-runs the layout solver or simply skips
  hidden cells in raster order; keep it consistent with how columns/
  rows params behave elsewhere.
- "Reset hidden" action (sidebar or toolbar) to unhide all.

### Stage B verification

- Hiding N thumbnails removes exactly N cells from the exported sheet;
  grid dimensions adjust per the documented re-flow rule.
- Hidden state doesn't survive regeneration from new sampling settings
  (regenerating rebuilds the `Thumbnail` array) — confirm this is
  acceptable or, if hidden-by-timestamp persistence across regen is
  wanted, flag it as a decision rather than assuming.

## Stage C — Drag-reorder

- Drag a cell to a new position in the grid; `Thumbnail` array reorders
  accordingly. Export follows the new order.
- Use SwiftUI's native drag/drop (`.draggable`/`.dropDestination`,
  macOS 13+) or `onDrag`/`onDrop` depending on the deployment target
  already set in the Xcode/build config — check `build.sh`/project
  settings before choosing the API rather than assuming availability.

### Stage C verification

- Reorder persists through export (verify via visual inspection of
  output order, not just on-screen order).
- Reorder does not corrupt hidden-state or per-cell settings from
  Stage B.

## Stage D — Individual in/out points (per-thumbnail time nudge)

- Per-cell overlay control (e.g. `< >` step buttons or a small
  scrubber) to nudge that thumbnail's source timestamp forward/back by
  a configurable step (default: 1 second), independent of the global
  sampling settings.
- Re-extracts only that one frame (not a full regeneration) —
  performance-sensitive; reuse the existing single-frame extraction
  path from `ContactSheetRenderer`/ffmpeg invocation rather than
  re-running the full sampling pipeline.

### Stage D verification

- Nudging one cell updates only that cell (confirm via timing — should
  be near-instant, not full-grid regeneration time).
- Nudged timestamp reflected correctly in export and in any header
  metadata display.
- Interacts correctly with hide/reorder from Stages B–C.

## Non-goals (explicitly pending, do not implement)

- Multi-movie list panel / switching between source videos.
- Batch contact-sheet creation across multiple videos.
- Timeline scrubber for global range selection (beyond existing Auto
  Sampling Range controls).

## Wrap-up

- `docs/DEV_LOG.md` entry per stage (or one combined entry referencing
  all four commits — match whatever granularity Phase 1 used).
- Record the re-flow rule (Stage B) and hidden-state-across-regen
  behavior as decisions in `docs/DECISIONS.md`.
- Archive this task to `docs/tasks/`.
- Flag `docs/ARCHITECTURE.md` refresh as a follow-up (still outstanding
  from the src/ move) — now covering the grid/cell model too.

## Constraints

- Follow `AGENTS.md` / `CLAUDE.md`. Branch off current `main`
  (`v2.1.0`).
- Each stage: separate commit, separate verification, do not proceed
  to the next stage until the current one's verification passes.
- If any stage surfaces a product decision not covered here (e.g. the
  re-flow rule, hidden-state persistence), stop and flag it rather than
  choosing silently — same pattern as the sidebar decision in Phase 1.

## Implementation Result

**Status:**
- Completed

### Changes

Four stages, one commit each, on `feature/phase3a-thumbnail-interactivity`:

- **Stage A (`a901115`)**: Preview replaced by a `LazyVGrid` of
  `ThumbnailCellView` (new `src/Views/ThumbnailGridView.swift`,
  `ThumbnailCellView.swift`), laid out from
  `ContactSheetRenderer.metrics`. Per-cell drawing extracted into a
  shared `drawCell` (one source of truth); new `renderCellImage` /
  `renderHeaderImage` produce the display images alongside the export
  composite. Grid lays out from a params snapshot (`displayParams`)
  captured at render time. Export path untouched.
- **Stage B (`0a12ce6`)**: Hover scrim with timestamp + eye toggle
  (`src/AppState+Grid.swift`: `toggleHidden`/`resetHidden`/
  `recomposeSheet`); hidden cells dim in place, excluded from sheet
  and individual-frame export via approved raster-order re-flow
  (`reflowParams`: columns fixed, rows = ceil(visible/cols));
  "Unhide All (N)" in the canvas toolbar; hidden resets on regen
  (approved decision).
- **Stage C (`01155e5`)**: Drag-reorder via onDrag/onDrop +
  `DropDelegate` live-move (deployment target macOS 11 ruled out
  `.draggable`); drop recomposes the sheet so export follows.
- **Stage D (`99e9843`)**: `< >` nudge buttons on the hover overlay;
  configurable Nudge Step (0.1–10s, default 1s, persisted) in Auto
  Sampling Range; single ffmpeg re-extract per nudge into the
  retained frames dir; clamped to [0, duration]; per-cell spinner;
  superseded-generation guard. `Thumbnail.timestamp`/`imagePath` are
  now mutable.

### Verification

- Build: passed after every stage; only pre-existing `onChange`
  deprecation warnings. Installed to `~/Applications` and exercised
  live per stage.
- Automated verification: harness grew to 30 checks, all pass —
  including T1 (default-settings export still byte-identical to the
  Phase 1 baseline after the Stage A renderer restructuring) and
  T10a–f (re-flow math + reflowed sheet exactly one row shorter).
- Manual verification (computer-use GUI, with export region-compare
  scripts for ground truth):
  - Stage A: on-screen grid at 100% zoom visually identical to the
    flattened preview (header strip, spacing, timestamps).
  - Stage B: hide 2 of 20 → export contains 18 cells, last row 3
    cells + background (pixel-checked); Unhide All restores; hides
    reset after regeneration.
  - Stage C: exported sheets before/after a drag region-compare as
    exactly the permutation [1,2,0,3,…] with all other cells
    byte-stable; a further reorder preserved an existing hidden cell.
  - Stage D: nudging one cell (+1s) changed exactly that cell in the
    export (19 others byte-stable), timestamps updated in overlay and
    burned-in label, near-instant (single ffmpeg invocation);
    dragging the nudged cell carried frame + timestamp along.
- Automation note: the computer-use drag gesture only initiates
  SwiftUI drag sessions reliably with a slow press-hold-move pattern;
  two GUI drag attempts were no-ops (exports byte-identical, caught
  by the region compare) and were retried. App-side behavior was
  correct in every successful session.

### Remaining Issues

- None

### Follow-up Suggestions

- `docs/ARCHITECTURE.md` refresh (outstanding since the src/ move,
  noted again here): should now also describe the grid/cell display
  model (`displayParams` snapshot, cellImages cache, recompose path).
- Optional: a keyboard affordance for hide/nudge on a focused cell —
  TASK's "keyboard" mention was scoped out of Stage A and never
  required later; worth a small follow-up task if wanted.
