# Project Instructions

## Workflow

- The project owner defines tasks.
- Do not redefine, extend, or split tasks on your own.
- Architecture, requirements, and design direction are decided through chat.
- Implementation is driven by `TASK.md` at the repository root.
- Read `TASK.md` before making changes.
- Implement only the scope requested in `TASK.md`.
- Do not add unrelated features or refactor unrelated code unless explicitly instructed.
- Build the project after implementation.
- Perform reasonable tests and verification appropriate to the task.
- Update relevant documentation when necessary.

## Task Completion

- A task is considered finished when you stop work and report the result to the project owner.
- A task may be finished even if it is not fully successful. In that case, record the failure, limitations, and any newly discovered follow-up work.
- Follow the task completion and archiving procedure in docs/task-workflow.md.

## Scope Control

- Do not implement features outside the requested scope unless explicitly instructed.
- Small changes required to build, test, or safely integrate the requested work are allowed.
- Record substantial newly discovered work as a follow-up issue rather than expanding the current task.

## Git Workflow

- Complete the implementation, build, and verification before creating a commit.
- Create one local commit for each completed task whenever practical.
- Use concise English commit messages.
- If a task cannot be fully completed, commit the completed work and clearly describe the remaining work in the task archive.
- Never push, create releases, or modify remote repositories unless explicitly instructed.
- Initial publication to GitHub and other significant push points are reviewed by the project owner.
- Direct branch merges are acceptable for small solo projects.
- Pull requests are not required unless explicitly requested.

## Documentation

- `docs/tasks/` contains the original task instructions and their implementation results.
- `docs/KNOWN_ISSUES.md` contains unresolved, reproducible, and actionable problems.
- `docs/DEV_LOG.md` contains notable project-level progress rather than detailed task history. Keep DEV_LOG.md concise. Record only major completed milestones.
- `docs/DECISIONS.md` contains lasting architectural, technical, and product decisions.
- Avoid duplicating the same information across these files.
- Create `docs/KNOWN_ISSUES.md`, `docs/DEV_LOG.md`, or `docs/DECISIONS.md` when the project grows enough to benefit from them. Once created, keep them updated when relevant.
- Do not modify `README.md` unless explicitly requested by the project owner.

## Language

- Communication and explanations to the project owner are primarily in Japanese.
- Source code, identifiers, code comments, UI text, logs, and commit messages are in English.
- Project documentation is written in English by default.
- Use Japanese documentation only when explicitly required by the project.
- Preserve the existing language and style when editing established documentation.

## Licensing

- Follow the project's primary license defined by the repository root license file.
- Preserve existing copyright notices, licenses, and attribution.
- Store additional third-party licenses and attribution documents under `docs/licenses/`.
- Ensure added third-party code or assets comply with the project's licensing requirements.

## Build

- Use repository-local build output under `build/`.
- Keep only final distributable products under `build/`.
- Store intermediate build files, caches, indexes, test products, and temporary artifacts outside the repository.
- Remove stale contents from `build/` before producing a new final product.
- Verify that `build/` contains only the intended final product after the build.
- Keep `build/` clean and easy to inspect.
- Verify that the built application launches successfully whenever practical.
- A task may override these rules if explicitly instructed.


## General Conventions

- Use English for filenames and identifiers.
- Follow the existing project structure and coding style.
- Prefer simple, maintainable solutions over unnecessary abstractions.
- Follow semantic versioning for tagged releases unless the project specifies otherwise.
