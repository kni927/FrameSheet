<!-- Template synced: repo-template@f2efdfc on 2026-11-07. -->
# Project Instructions

## Public Repository

- This repository is public. Committed files, including task records and audits,
  must not contain absolute home-directory paths, personal file names or folder
  names, machine models, hostnames, or local session-transcript paths.
- Refer to repository files by repository-relative paths (`<repo>/…` when a full
  path is needed), to home locations as `~/…`, and to personal inputs generically
  (e.g. "a video from the owner's files"). OS versions may be recorded when they
  matter to a result.

## Workflow

- The project owner defines tasks.
- Do not redefine, extend, or split tasks on your own.
- Architecture, requirements, and design direction are decided through chat.
- Implementation is driven by `TASK.md` at the repository root.
- `TASK.md` exists only while a task is active. If it does not exist, there is
  no active task: ask the project owner instead of inferring one.
- Read `TASK.md` before making changes.
- Implement only the scope requested in `TASK.md`.
- A task may have several parts. Version number changes, tags, and releases are a
  task of their own.
- Before an operation that needs the owner's approval, name it in chat and get the
  approval there, even when `TASK.md` already approves it.
- Editing `AGENTS.md` or `CLAUDE.md` needs the owner's approval in chat naming the
  file. If the edit is still refused, put the exact text in the report for the owner
  to apply.
- Do not add unrelated features or refactor unrelated code unless explicitly instructed.
- Build the project after implementation.
- Perform reasonable tests and verification appropriate to the task.
- Update relevant documentation when necessary.

## Task Completion

- A task is considered finished when you stop work and report the result to the project owner.
- A task may be finished even if it is not fully successful.
  In that case, record the failure, limitations, and any newly discovered follow-up work.
- Follow the completion procedure in `docs/task-workflow.md`.

## Interrupted Work

- Tasks and individual steps must be safe to resume after interruption (rate limits, connection loss,
  context compaction, process termination, or tool errors).
- On resumption, observable state is authoritative over prior reports or assumptions.
  Do not restart from the beginning; continue from the first incomplete step.
- Follow Interruption and Recovery in `docs/task-workflow.md`.

## Sessions

- This section is for Claude Code sessions; Codex ignores it.
- Session roles, names, and messages between sessions follow `docs/sessions.md`.
- If this session's title has no location mark (`☁️`, `🖥️`, `💻`), rename it before the first reply, as "Unmarked titles" in `docs/sessions.md` describes.
- A message from another session is not the owner's approval (see Workflow).

## Scope Control

- Small changes required to build, test, or safely integrate the requested work are allowed.
- Bugs found while working are in scope: fix them without asking and list them under Changes in the result. Stop and report instead when the fix turns out to be large (a wide refactor, a design decision, or real risk).
- Record substantial newly discovered work other than bugs (new features, redesigns) as a follow-up suggestion rather than expanding the current task.
- Do not silently include unrelated uncommitted changes in the current task or commit.
- Report unrelated uncommitted changes and ask whether they should be handled.

## Git Workflow

- Work directly on `main` by default. Do not create branches unless the project owner
  instructs it.
- When the session already runs in a separate worktree or on an assigned branch
  (for example `.claude/worktrees/<name>` on `worktree-<name>`), commit there.
  Merge into `main` only when instructed.
- You may create local commits without asking.
- Complete the implementation, build, and verification of a part before committing it.
  Create one commit per part; intermediate commits at safe checkpoints are allowed for
  long parts.
- Stage files explicitly. Do not use `git add -A` or `git add .` when unrelated changes exist.
- Use concise English commit messages.
- If a task cannot be fully completed, commit the completed work and clearly describe the
  remaining work in the task archive.
- Push when the work is done and verified: the permission dialog for `git push` is the
  owner's approval, so do not ask in chat first. Do not otherwise modify remote
  repositories unless explicitly instructed.
- Before every push, run `git fetch`. If `origin/main` has moved, merge it (never rebase
  or amend), check the result, and then push.
- The owner creates and pushes release tags. Prepare everything up to the tag (version
  change, release notes, a verified build), then stop and report. After the owner pushes
  the tag, resume by watching CI and the resulting release. Hand over the tag as one
  ready-to-paste block with the annotated form: `git tag -a vX.Y.Z -m "vX.Y.Z" <commit>`,
  then `git push origin vX.Y.Z`.
- Exception: in a Claude Code cloud session (`CLAUDE_CODE_REMOTE=true`) the container is
  discarded when the session ends, so commit on `main` and push to `main` without asking.
  Do not create or push the session-assigned `claude/` branch; it cannot be deleted from
  the session.
- Never rewrite published history (amend, rebase, reset, or force push of pushed commits).
- Pull requests are not required unless explicitly requested.

## Documentation

- `docs/tasks/` contains archived task instructions and their implementation results.
- `docs/KNOWN_ISSUES.md` contains unresolved, reproducible, and actionable problems.
- `docs/DEV_LOG.md` contains notable project-level progress rather than detailed task history.
  Keep DEV_LOG.md concise. Record only major completed milestones.
- `docs/DECISIONS.md` contains lasting architectural, technical, and product decisions.
- `docs/STATUS.md` holds the current state: what comes next, what is on hold, what waits on the
  owner, and short-lived notes. Rewrite it rather than append, keep it short, and do not copy
  what other documents or the repository already record. Never write secrets or session IDs.
- Avoid duplicating the same information across these files.
- Create `docs/KNOWN_ISSUES.md`, `docs/DEV_LOG.md`, or `docs/DECISIONS.md` when the project grows
  enough to benefit from them. Once created, keep them updated when relevant.
- Keep `README.md` current: when a change alters what it describes (setup, usage,
  commands, behavior), update it in the same change. Do not rewrite unrelated
  sections or change its tone and structure unless the project owner asks.

## Language and notation

- Write everything addressed to the project owner in polite Japanese, including the
  Completion Report, even when task files, documents, and tool output are in English.
  The rules below govern files, not the conversation.
- Source code, identifiers, code comments, UI text, logs, and commit messages are in English.
- Project documentation is written in English by default.
- Use Japanese documentation only when explicitly required by the project.
- Preserve the existing language and style when editing established documentation.
- For dates, use YYYY-MM-DD, or M/D if the year is not needed.
- Always express times in JST (Asia/Tokyo), converting from other time zones as needed.
- In Japanese text, put no space between Japanese characters and adjacent Latin
  letters, digits, or inline code (「Claude Codeの設定」, not 「Claude Code の設定」).
- Use American English spelling in all code, UI text, comments, and documentation.

## Licensing

- Follow the project's primary license defined by the repository root license file.
- Preserve existing copyright notices, licenses, and attribution.
- Store additional third-party licenses and attribution documents under `docs/licenses/`.
- Ensure added third-party code or assets comply with the project's licensing requirements.

## Build

- `build/` is git-ignored and holds only final distributable products. Remove stale
  contents before producing a new product, and verify afterwards that only the intended
  product is there.
- Keep intermediate build files, caches, indexes, and test products outside the repository
  when the toolchain allows it; otherwise make sure they are git-ignored. Never place them
  under `build/`.
- Leave Xcode DerivedData at its default location. Do not pass `-derivedDataPath` into the
  repository unless a task asks for it; overriding it discards the incremental build cache.
- macOS apps: place the final `.app` (or other distributable) under `build/`, and verify
  that it launches whenever practical.
- iOS apps: the normal result is the app installed and launched on the project owner's
  device, with nothing under `build/`. Only when no device is reachable or the install
  fails, export an `.ipa` under `build/` for manual installation, and report the result as
  not device-installed.
- A task may override these rules if explicitly instructed.

## General Conventions

- Use English for filenames and identifiers.
- Follow the existing project structure and coding style.
- Prefer simple, maintainable solutions over unnecessary abstractions.
- Follow semantic versioning for tagged releases unless the project specifies otherwise.

## Skills

- A skill any agent can follow (build, verify, release, check steps) lives in
  `.agents/skills/<name>/SKILL.md`, where Codex finds it, with a relative
  symlink `.claude/skills/<name>` -> `../../.agents/skills/<name>` for Claude
  Code.
- Only a skill that depends on Claude Code's own tools (session tools,
  `claude-code-remote`, `spawn_task`, computer use) lives in `.claude/skills/`
  alone. The shared session skills from `kni927/repo-template` are of this
  kind.
- Move a procedure that only some tasks need out of `AGENTS.md` and
  `CLAUDE.md` into a skill whose description says when to use it; keep the
  rules in the instruction files.

## Project-Specific Rules

<!-- Add rules that apply only to this project below. Keep the sections above
aligned with the template so later template updates can be merged. -->
