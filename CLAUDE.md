# CLAUDE.md

## Read First

Before making changes, read:

1. PROJECT.md
2. ARCHITECTURE.md
3. DECISIONS.md
4. KNOWN-ISSUES.md
5. ANTIGRAVITY.md

## Git Workflow

- Do not commit directly to main
- Create a feature branch before making changes
- Keep commits focused and small

Example:

bash git switch -c feature/<task-name> 

## Development Rules

- Preserve the current SwiftUI architecture
- Do not bundle FFmpeg
- `vcsi` has been removed entirely as of v2.0.0; do not reintroduce it or any Python dependency
- Keep UI text in English
- Prefer small targeted fixes over large refactors
- Do not remove historical information from ANTIGRAVITY.md

## Validation

Before committing:

bash ./build.sh git diff 

Report:

- Files changed
- Summary of changes
- Build result
- Remaining risks
- Suggested commit message