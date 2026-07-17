# Task Workflow

## Task Completion

Follow the task completion and archiving procedure.

```md
## Implementation Result

**Status:** 
- Completed
- Completed with follow-up issues
- Partially completed
- Not completed

### Changes

- Summarize the implemented changes.
- Note important files or components that were modified.
- Record any intentional deviation from the requested scope.

### Verification

- Build:
- Automated verification:
- Manual verification:
- Not performed:

### Remaining Issues

- List unresolved problems directly related to the task.
- Write `None` if no known issues remain.

### Follow-up Suggestions

- List meaningful next-step suggestions discovered during implementation.
- Do not implement them as part of the current task.
- Write `None` if there are no suggestions.
```

When reporting back:

- Append the implementation result to `TASK.md`.
- Record unresolved actionable problems in `docs/KNOWN_ISSUES.md` when appropriate.
- Update `docs/DEV_LOG.md` when the task represents meaningful project progress.
- Update `docs/DECISIONS.md` when a lasting design or architectural decision was made.
- Archive `TASK.md` as: `docs/tasks/YYYY-MM-DD-NN-description.md`.
- Do not leave `TASK.md` in the repository after reporting.

- Use a two-digit sequence number starting at `01` for each date.

- Do not redefine, extend, or split a task on your own.
- Any further work must be recorded as follow-up suggestions and handled as a new `TASK.md` after review by the project owner.

## Completion Report

At the end of every task, provide a concise completion report in the chat response that can be copied directly into another conversation.

- The completion report is intended to be copied into a follow-up chat if needed.

- Use the following structure:

### Completion Report

- Status: Completed / Partially completed / Could not complete
- Summary:
- Files changed:
- Build:
- Automated verification:
- Manual verification:
- Commit:
- Push:
- Remaining issues:
- Suggested next step:

Include exact file paths, commands, test counts, and the local commit hash when available.

Clearly distinguish:
- Verified automatically
- Verified manually
- Not verified

Do not rely on `docs/DEV_LOG.md` or the archived task as the only completion report.
Keep the report self-contained and concise.