---
name: checklist
description: Add, read or close owner steps in the owner's Todoist project Checklist, the list docs/sessions.md (Status files, "Owner steps count as done") keeps for steps that are critical, urgent, block a next step, or that the owner says are pending. Use when such a step must wait on the owner, when following up an owner step, or when a STATUS file's "Waiting on owner" needs checking.
---

# Checklist

`docs/sessions.md` (Status files) says which owner steps are kept; this is how.

- **Where:** the Todoist project **Checklist** (`6hv5QRGXXcX7vqRR`). Section
  Waiting (`6hv5QRWwJPh6FVFR`) when a next step depends on the task, else On
  hold (`6hv5QRVX8HMhVRX2`). One label naming the repository.
- **Adding:** the Todoist connector's `add-tasks`: a short `content`, and at
  most two lines of `description`: why, and where the steps are (a skill, a
  repository file); never the steps themselves. Give a due date only when
  there is a real one, and a hard date in the title (Todoist deadlines are
  premium only).
- **Not here:** a reminder months ahead goes to Google Calendar as an
  all-day event (two-line description, pointing to the steps); when it comes
  up, the owner or a session adds the task then.
- **Reading:** `find-tasks` with that project, at the start of a turn that
  follows up an owner step. A task no longer open is done; do not ask the
  owner about it.
- **Shown:** Erga kai Hemerai (https://claude.ai/artifact/BfRA69hSfCditT5eUz8fzY)
  shows the list; the owner completes tasks there or in Todoist. That
  artifact's own database is not used for this: its writes raise a dialog.
