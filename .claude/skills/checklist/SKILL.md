---
name: checklist
description: Add, read or close owner steps in the owner's Todoist project Checklist, the list docs/sessions.md (Status files, "Owner steps count as done") keeps for steps that are critical, urgent, block a next step, or that the owner says are pending. Use when such a step must wait on the owner, when following up an owner step, or when a STATUS file's "Waiting on owner" needs checking.
---

# Checklist

`docs/sessions.md` (Status files) says which owner steps are kept; this is how.

- **Where:** the Todoist project **Checklist** (`6hv5QRGXXcX7vqRR`). Section
  Waiting (`6hv5QRWwJPh6FVFR`) when a next step depends on the task, else On
  hold (`6hv5QRVX8HMhVRX2`). One label naming the repository.
- **Adding:** the Todoist connector's `add-tasks`: a short `content`, and the
  steps in `description` as a bulleted list, one command per line, starting
  with "Added by <session>, <date>." Give a due date only when there is a
  real one. Todoist deadlines are a premium feature this account lacks: put
  a hard date in the title instead.
- **Reading:** `find-tasks` with that project, at the start of a turn that
  follows up an owner step. A task no longer open is done; do not ask the
  owner about it.
- **Shown:** Erga kai Hemerai (https://claude.ai/artifact/BfRA69hSfCditT5eUz8fzY)
  shows the list; the owner completes tasks there or in Todoist. That
  artifact's own database is not used for this: its writes raise a dialog.
