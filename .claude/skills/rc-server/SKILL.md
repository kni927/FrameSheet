---
name: rc-server
description: Start local TFs from a cloud HQ through Remote Control server mode (claude remote-control --spawn worktree on the Mac), and close that setup cleanly. Use only when the owner has started or asks for server mode; the offer-tf card stays the default way to start a TF.
---

# TFs through Remote Control server mode

`docs/sessions.md` (Local sessions on the Mac) is the rule; this is the
procedure. The owner starts the server only when this is wanted. The Mac
mini also runs an always-on server in `~/Projects/Local/MacMiniHQ`
(kni927/dotfiles `docs/AUTOMATIONS.md`, "Remote Control server"); it is
not for TFs.

## Starting TFs

1. The owner runs `claude remote-control --spawn worktree` in the repository
   on the Mac (optionally `--name "🖥️ <repo> RC server"`). The folder then
   appears to cloud sessions as a `bridge` environment in
   `list_environments`. The server's own first session works in the main
   folder; give it a title with the location mark.
2. Start a TF with `create_session`: that `environment_id`, a title with the
   location mark, and a prompt that says to read `~/.claude/skills/tf/SKILL.md`
   and follow it as if the owner had typed `/tf <what>`. Rename it with
   `set_session_title` if needed; no approval card appears.
3. Each such session works in its own worktree
   (`.claude/worktrees/bridge-<id>/`), so several can run at once. They have
   the `claude-code-remote` tools but not the desktop app's session tools.
   They show in the Mac app, on the Web and on the phone (2026-10-28).
4. They stop answering when the server stops; running `claude remote-control`
   in the same folder within about four hours brings them back.
5. Archiving such a session removes its worktree at once, and unarchiving
   brings back neither the worktree nor the connection (2026-10-07). So a TF
   commits and merges or pushes before it is archived. Because these sessions
   were started from the cloud, they may be archived from the cloud: a TF started
   this way can hand over to a successor started the same way, which archives
   it once the work is committed.

## Closing the setup

Stopping the server does not archive its sessions; they stay listed as
disconnected for about four hours.

1. Each TF commits and merges or pushes its work and reports to its HQ.
2. The owner stops the server (Ctrl+C in its terminal).
3. An HQ, a successor, or the owner archives the remaining sessions of that
   `bridge` environment, the server's first session included. Archiving a
   worktree session removes its worktree and branch; the first session works
   in the main folder, so archiving it changes no files.
4. In the repository, `git worktree list` must show no
   `.claude/worktrees/bridge-*` entry; remove a leftover with
   `git worktree remove <path>` and `git branch -d <branch>`.
