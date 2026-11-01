# CLAUDE.md
@AGENTS.md

## Commands
- Build: `./build.sh` — compiles the Swift sources under `src/` via `swiftc -parse-as-library`, packages `build/FrameSheet.app`, codesigns with the Developer ID Application identity (`FRAMESHEET_SIGN_IDENTITY` override; ad-hoc fallback), and zips it. Version comes from the latest git tag. Repo-local output only.
- Test: none yet
- Lint: none yet
- Sandbox-excluded scripts (listed in `.claude/settings.json`): none yet
- Checkpoint commands that always ask (`permissions.ask` in `.claude/settings.json`): none yet
- Debug installs go to `~/Applications`, never `/Applications`.

## Read First

Before making changes, read:

1. docs/PROJECT.md
2. docs/ARCHITECTURE.md
3. docs/DECISIONS.md
4. docs/KNOWN_ISSUES.md
5. docs/ANTIGRAVITY.md

## Development Rules

- Preserve the current SwiftUI architecture.
- Do not bundle FFmpeg — the app shells out to a system-installed `ffmpeg`/`ffprobe`, checked on launch.
- `vcsi` has been removed entirely as of v2.0.0; do not reintroduce it or any Python dependency.
- Keep UI text in English.
- Prefer small targeted fixes over large refactors.
- Do not remove historical information from docs/ANTIGRAVITY.md.

## FFmpeg Conventions

- Frame extraction uses one input-seeking invocation per frame (`ffmpeg -ss <t> -i <file> -frames:v 1`), run 5-way concurrent via `runParallelFrameExtraction()` — not a single-pass `fps=1/interval` filter, and not `-hwaccel videotoolbox` (decoder init overhead dominates for single-frame decodes; software decode is cheap per GOP).
- Temporary thumbnails are written as JPEG (`-q:v 3`), not PNG, to minimize I/O overhead.
- Duration is read from ffprobe format/stream duration first. If missing, `N/A`, or 0, `estimateDuration` falls back to a packet-timestamp scan before generation proceeds — see docs/DEV_LOG.md ("Phase 4") for the two-attempt strategy.

## Sandbox
- The global Claude Code instructions define how to run commands so sandbox
  exclusions apply. Project-specific exclusions live in `.claude/settings.json`
  under `sandbox.excludedCommands`; list them under Commands.
- An operation that tasks need outside the sandbox again and again (saving and
  restoring preferences, unregistering an app, and the like) goes into a project
  script listed in `sandbox.excludedCommands`, with its step under Commands. The
  auto mode classifier then finds it in `CLAUDE.md`, also when a subagent runs
  it; a step written only in `TASK.md` or a task record is refused as a bypass.
- Commands that must always be confirmed, even in auto mode (for example a release
  or upload script), go under `permissions.ask` in `.claude/settings.json`. Do not
  add `allow` rules there, except `mcp__claude-code-remote__send_message`
  (owner approved, 2026-10-07); other `allow` rules bypass the auto mode
  classifier.
- The auto mode classifier reads the chat and `CLAUDE.md`, not `TASK.md`, so an
  approval written only in `TASK.md` does not count. It has refused edits to
  `CLAUDE.md` and `AGENTS.md` ("Self-Modification") that had no approval in chat,
  and creating a release tag ("Production Deploy"); see Workflow and Git Workflow
  in `AGENTS.md`.

## Plan Mode
- `TASK.md` is the approved plan. Do not enter plan mode because a task touches
  multiple files or unfamiliar code paths.
- Use plan mode only when `TASK.md` leaves an implementation choice to the project
  owner, or when you intend to deviate from `TASK.md`. Present the plan and wait
  for approval.

## Compact Instructions

When compacting, preserve working state for continuation, not chat history.

Always keep:
- Current goal and acceptance criteria
- Exact files changed, created, deleted, or inspected — and why
- Important functions, classes, routes, settings, commands, config keys
- Architectural / business rule decisions
- Rejected approaches and why they were rejected
- Errors, failed tests, commands run, and fixes attempted
- Pending tasks and the exact next step

Summarize:
- Completed exploration
- Older discussion
- Repeated command output

Drop:
- Verbose logs unless they contain unresolved errors
- Duplicate explanations
- Abandoned ideas no longer relevant

After compaction, re-read `TASK.md` (and the handover or recovery file in use, if any) before continuing.
