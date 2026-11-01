---
name: reload-instructions
description: Bring a long-running session's instructions up to date - pull the attached repositories, re-read AGENTS.md, CLAUDE.md and docs/sessions.md, and read the owner's current custom instructions from kni927/dotfiles instructions/full/claude.md, which win over the copy the session started with. Use when the owner says "reload", or when Upstream HQ says the custom instructions changed.
---

# Reload the instructions

A session keeps the instructions it started with. A new container (after the
session sat idle) clones the repositories again and re-reads their instruction
files, but the owner's custom instructions stay as they were when the session
was created. This skill catches both up without a new session.

1. In each repository attached to this session, `git pull --ff-only` on `main`
   (stop and say so if it is not a fast-forward). Read `AGENTS.md`,
   `CLAUDE.md` and `docs/sessions.md` again in full; where they differ from
   what you were following, follow the files.
2. Read `instructions/full/claude.md` in `kni927/dotfiles`: the clone at
   `/home/user/dotfiles` if there is one (pull it first), otherwise attach it
   with `add_repo` (access `read`) and clone it. This is the owner's current
   custom instructions; where it differs from the copy in your system prompt,
   follow the file.
3. Never copy that file, or any part of it, into another repository, an
   artifact, or a message: it holds personal details, and some repositories
   are public (`kni927/cooViewer`).
4. Tell the owner in one English line what changed (files and sections), or
   `Instructions unchanged`.
