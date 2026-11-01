# Handover Report

<!--
Use only when handing an INCOMPLETE task to a new chat. For completed
tasks, the docs/tasks/ archive plus the chat completion report suffice —
do not create a handover.
Record only what lives in this chat and cannot be recovered from the repo
or existing docs. Do not transcribe git/tag/release state; the next session
inspects it directly.
File: docs/handovers/YYYY-MM-DD-NN-<desc>-hNN.md (match the task's date/NN).
-->

## 1. Objective

- Goal and acceptance criteria:
- Out of scope:

`TASK.md` remains the source of truth for scope if present. Record here only
refinements agreed in chat but not yet in `TASK.md`. Progress already recorded in
the `Progress` section of `TASK.md` need not be repeated here.

## 2. Status and Next Step

- Last completed step:
- Working branch:
- Blocker, if any:
- **Exact next step:** one action, immediately executable
  (file/path/command + expected result).

Do not transcribe repository state. The next session determines progress by
inspecting it directly, per Interruption and Recovery in `docs/task-workflow.md`.

## 3. Decisions and Open Questions

- **Decided (chat-only, not yet in code or `docs/DECISIONS.md`):**
  - decision — reason — affected files
- **Open (must not be treated as decided):**
  - question — why it matters — options / recommendation

## 4. Uncommitted Work and Constraints

- Work not yet committed that git won't show cleanly (files, what, why):
- Constraints / non-negotiables (do-not-modify, approval-required, etc.):

## 5. Next-Session Prompt

Paste into the next chat together with this report:

---

Continue the task using the Handover Report below as the sole prior context.

- Treat the report as a handover record, not unquestionable truth. Before
  changing anything, inspect the current repository and external state;
  observable state wins where it differs from the report.
- Do not restart from the beginning or repeat completed operations unless
  their result is missing, invalid, or unverifiable.
- Distinguish decided from open; preserve all constraints.
- Perform the Exact Next Step first unless observable state shows it is done.
- Keep this report updated as new facts, decisions, or failures appear.
- Follow Interruption and Recovery in `docs/task-workflow.md`.

[PASTE HANDOVER REPORT HERE]

---
