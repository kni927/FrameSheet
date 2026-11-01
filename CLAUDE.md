# CLAUDE.md
@AGENTS.md

## Commands
- Build: `./build.sh` — compiles the Swift sources under `src/` via `swiftc -parse-as-library`, packages `build/FrameSheet.app`, codesigns with the Developer ID Application identity (`FRAMESHEET_SIGN_IDENTITY` override; ad-hoc fallback), and zips it. Version comes from the latest git tag. Repo-local output only.
- Test: none yet
- Lint: none yet
- Measure: `tools/spike/run-all.sh quick <out-dir> <video>...` — after decode or scan changes, a few-minute check of the v3 scan settings (one run each); `full` reruns the battery behind `docs/v3-measurements.md` (about 2 h) only when the owner asks. Run it from the repository root as its own command.
- Sandbox-excluded scripts (listed in `.claude/settings.json`): `tools/spike/run-all.sh` (VideoToolbox and the GPU are unavailable inside the sandbox; owner approved, 2026-11-02)
- Checkpoint commands that always ask (`permissions.ask` in `.claude/settings.json`): none yet
- Debug installs go to `~/Applications`, never `/Applications`.

## Read First

Before making changes, read:

1. docs/V3_SPEC.md
2. docs/DECISIONS.md (v3: decisions 14 on)
3. docs/PROJECT.md
4. docs/ARCHITECTURE.md
5. docs/KNOWN_ISSUES.md
6. docs/ANTIGRAVITY.md

## Development Rules

- v3 is a rebuild that reproduces MoviePrint v0.2.23 (`docs/V3_SPEC.md`);
  follow the spec's behaviour and values, and ask the HQ when it is silent or
  marked (open).
- Target macOS 27+, arm64 only, Swift 6 language mode; SwiftUI, with AppKit
  only where SwiftUI falls short.
- Keep logic that needs no UI (models, layout maths, shot detection, naming,
  EDL, PNG chunks, import) in the core library, covered by `swift test`.
- Do not bundle FFmpeg or link libav*; the app finds a system `ffmpeg`/`ffprobe`
  as `docs/V3_SPEC.md` §10 describes.
- No Python dependency; `vcsi` stays removed.
- MoviePrint code may be ported; keep its MIT notice under `docs/licenses/`.
  Never copy PyMoviePrint code (no license).
- Reproduce MoviePrint's layout and interactions, not its look: content uses
  the kni Design System (Catppuccin Mocha), dark only.
- Keep UI text in English.
- Do not remove historical information from docs/ANTIGRAVITY.md.

## Decode Conventions

- AVFoundation first: `AVAssetImageGenerator` for random access (thumbs),
  `AVAssetReader` for sequential scans; route a file to ffmpeg only when
  AVFoundation has no decodable video track (decision 10).
- Exact-time extraction first, then one retry with ±0.5 s tolerance, keeping
  the time actually decoded (decision 11).
- ffmpeg fallback: duration from ffprobe format/stream duration first; if
  missing, `N/A`, or 0, fall back to a packet-timestamp scan (docs/DEV_LOG.md,
  "Phase 4").
- Scan resolution, face sampling and the frame-cache size follow
  `docs/v3-measurements.md`.

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
