# Task Workflow

## Task Lifecycle

1. The project owner writes `TASK.md` at the repository root, starting from
   `docs/task-template.md`.
2. The agent implements it. The owner-written sections (Background through
   Verification) are not edited by the agent; progress goes into the
   `Progress` section.
3. On completion, the agent follows Task Completion below. Afterwards no
   `TASK.md` remains at the root.

## Interruption and Recovery

Work may be interrupted by rate limits, connection failures, context compaction,
process termination, or tool errors. The same prompt may be re-sent verbatim.
When resuming:

1. Do not assume the last requested or reported step failed.
2. Inspect the current repository and relevant external state before making further changes.
3. Determine which steps are completed, partially completed, or not started.
4. Continue from the first incomplete step. Re-run a completed step only
   when its result is missing, invalid, or cannot be verified.

The original goal and acceptance criteria remain authoritative throughout.

When determining execution progress, observable state is authoritative,
including:

- Presence or absence of `TASK.md` at the repository root. Its absence
  together with a matching `docs/tasks/YYYY-MM-DD-NN-*.md` archive is strong
  evidence that the task was already completed and reported.
- Files and generated build artifacts such as under `build/`.
- `git status`, diffs, and commit history.
- The current branch and worktree (`git branch --show-current`, `git worktree list`).
- Local commits not yet pushed, using `git log @{u}..HEAD` when an upstream branch is configured.
- Existing tags (`git tag -l`), releases (`gh release view`), and uploaded assets.
- Build and test output.

Before any non-idempotent operation or external side effect, including
commit, tag, push, release creation, or asset upload, explicitly confirm
that the intended result does not already exist.

For long-running or multi-stage work, update the `Progress` section of
`TASK.md` at meaningful phase boundaries with the last completed step,
current partial state, and exact next step.

## Verification Scope

Check what a change can affect, and check it once.

- During development, verify on device only what the change touches. A change
  that leaves a path alone (rendering, saving, file reading, and the like) does
  not re-test it.
- A release artifact (the CI build of a tagged commit) is checked only for what
  it can differ in from the development build of the same commit: versions,
  signing and Gatekeeper, launch, and pieces that depend on where it is
  installed (app extensions such as Quick Look). Features verified on that
  commit are not re-checked; re-check one only if app code changed after it was
  verified.
- An HQ writes a TASK's verification list to match.

## Handover and Session Transfer

Choose the record type by situation. Do not produce more than one for the same event.

- **Normal completion:** follow Task Completion below. No handover file.
- **Deliberate transfer of an incomplete task to a new chat:** create a
  handover report at `docs/handovers/YYYY-MM-DD-NN-<desc>-hNN.md`, matching
  the task's date and sequence number. Use the template at `docs/handover-template.md`.
- **Resuming after an unexpected interruption:** normally just update the
  `Progress` section of `TASK.md` per Interruption and Recovery above. Only for
  a genuinely complex recovery, record it at
  `docs/recoveries/YYYY-MM-DD-NN-<desc>-rNN.md`, reusing the handover template.

A handover records only what exists in this chat and cannot be recovered
from the repository or existing docs. Do not transcribe repository state
(git status, tags, releases); the next session inspects it directly.

## Task Completion

Perform these steps in order:

1. Finish the implementation.
2. Build and verify. For a task with several parts, finish, verify, and commit
   each part in order before moving to the next.
3. Fill in the `Implementation Result` section of `TASK.md`.
4. Update `docs/STATUS.md` (remove what this task finished, add its
   follow-up suggestions), and `docs/KNOWN_ISSUES.md`, `docs/DEV_LOG.md`, and
   `docs/DECISIONS.md` when relevant (see Documentation in `AGENTS.md`).
5. Move `TASK.md` to `docs/tasks/YYYY-MM-DD-NN-<desc>.md`
   (`git mv` if tracked; otherwise move it and `git add` the new path).
   - `YYYY-MM-DD` is the archive date in local time.
   - `NN` is a two-digit sequence number starting at `01` for each date.
6. Commit the documentation and archive with the last part, or on their own
   when every part is already committed.
7. Send the Completion Report below in chat.

Do not leave `TASK.md` in the repository after reporting.
Any further work is recorded as follow-up suggestions and handled as a new
`TASK.md` after review by the project owner.

### Status values

Use exactly one of these in both the Implementation Result and the Completion Report:

- `Completed`
- `Completed with follow-up issues`
- `Partially completed`
- `Not completed`

### Implementation Result

The section layout is defined in `docs/task-template.md`. Guidance:

- **Changes:** summarize the implemented changes, note important files or
  components, and record any intentional deviation from the requested scope.
  List bugs found and fixed along the way separately (`AGENTS.md`, Scope
  Control).
- **Verification:** list Build, Automated verification, Manual verification,
  and Not performed separately.
- **Remaining Issues:** unresolved problems directly related to the task, or `None`.
- **Follow-up Suggestions:** meaningful next steps discovered during
  implementation, not implemented as part of this task, or `None`.

## Completion Report

At the end of every task, provide a concise, self-contained completion report
in the chat response that can be copied directly into another conversation.
Write the report in Japanese; keep the field labels as they are.

### Completion Report

- Status:
- Summary:
- Files changed:
- Build:
- Automated verification:
- Manual verification:
- Commit:
- Push:
- Permission / Sandbox:
- Owner actions:
- Remaining issues:
- Suggested next step:

Include exact file paths, commands, test counts, and the local commit hash when available.

**Owner actions** lists every step the project owner has to perform
after this task (verification, installation, settings, commands to run on another
machine), as a numbered list or a table. Each step states the exact action or
command and the expected result. Write `None` if there are none. The owner reads
the chat report rather than the repository, so a step mentioned only in a file or
buried in another item is easily missed.

**Permission / Sandbox** records how the task interacted with the agent's
permission and sandbox controls, so recurring friction can be traced to a cause.
Write `None` if nothing below happened. Record only what the agent observed.
The agent cannot tell a dialog the owner approved from a call the classifier
approved silently; when the Mac's hook log is readable, count approval dialogs
from `~/Library/Logs/claude-permission-requests.log` (one line per dialog,
managed by `kni927/dotfiles`) since the task started, and otherwise write
`dialogs: unknown`.

- Sandbox bypass or escalation requests (Claude Code `dangerouslyDisableSandbox`,
  Codex escalated permissions), each with the command and the sandbox failure
  that justified it.
- Denials by Auto Mode or by rules, with the action and the reason given
  (or `no reason given`). Count only actual denials.
- Auto Mode check errors, where the classifier returned no verdict (for example
  a server-side error), with the action affected. These are not denials; list
  them separately.
- Permission-mode changes the owner made during the task (for example from
  auto to Accept edits), with the reason if known.
- Other permission or sandbox errors, such as a command that failed inside the
  sandbox because it was not run on its own.
- Main causes and the countermeasure taken or proposed.

This record is the evidence for relaxation decisions, including the global
condition to reconsider Auto Mode allow rules; counting check errors as denials
would argue for relaxing on false grounds. The purpose is an accurate record,
not a smaller number. A request for a command
that genuinely needs review is correct; a count is reduced only by fixing its
cause (running an excluded command on its own, a script that belongs in the
exclusions), never by splitting, wrapping, or rephrasing a command to avoid review.

Clearly distinguish:
- Verified automatically
- Verified manually
- Not verified

Do not rely on `docs/DEV_LOG.md` or the archived task as the only completion report.
