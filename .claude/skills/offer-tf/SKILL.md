---
name: offer-tf
description: Offer the owner a new local TF on the Mac as a one-click spawn_task card, with a prompt that actually starts the TF. Use when an HQ needs a TF for its repository, or when a TF wraps up and work that needs the Mac remains.
---

# Offer a TF with a card

`docs/sessions.md` ("Local sessions on the Mac") is the rule; this is the
procedure.

0. **Prefer no card.** Ask the base local session of the Mac the TF should
   run on (Mac mini HQ or MacBook HQ; Mac relay from the cloud) to start it
   with `start_session` in the repository's folder, using the prompt of
   step 4, then `detach_session`. Offer a card only when that session lacks
   `start_session` (sessions created before about 2026-11-05) or does not
   answer.

1. **Get the tool.** `mcp__ccd_session__spawn_task` may be deferred; load it
   with ToolSearch. If it is not available, tell the owner to open a local
   session in the repository and type `/tf <what>`, and stop here.
2. **Check the repository.** The card opens in this session's repository.
   For a TF in another repository, ask that repository's HQ to offer it.
3. **Check that the main clone is free.** With `list_sessions`, look for
   another TF of this repository that is still working. If there is one,
   the owner must pick Start with worktree; say so in step 5.
4. **Queue the card** with `spawn_task`. `<what>` starts with the TF's number,
   `#NN` (TF numbers in `docs/sessions.md`), for example `#02 blender-pilot`:
   - `title`: `Start <repo> TF <what>`;
   - `tldr`: one or two sentences in the owner's language on what the TF
     will do;
   - `prompt`, starting with exactly this line, then the First lines
     (`docs/sessions.md`, Messages; kind `tf`), then any context the TF
     needs and, while cloud-to-local messages are refused (`docs/sessions.md`,
     Messages), the whole first TASK under a `TASK:` line:

     ```
     Start this session as a TF: read `~/.claude/skills/tf/SKILL.md` and follow it exactly as if I had typed `/tf <what>`, so `$ARGUMENTS` is `<what>`.
     ```

   Do not start the prompt with `/tf`: a slash command in a card's prompt
   does not run, and `/tf` cannot be invoked by the model.
5. **Tell the owner** the card's title and which button to press: Start
   locally, or Start with worktree when step 3 found a working TF. No pull is
   needed first; the TF brings itself up to date when a TASK arrives. The
   card shows in the app on every Mac; the owner presses it on the Mac that
   should do the work (the client Mac has more memory, the server Mac is
   always on). When the TF announces itself, send the TASK to the `from-session` of
   that message (while that is refused, the TASK is already in the prompt;
   send a later TASK through the Mac relay (`mac-relay` skill), or as
   English text for the owner to paste), and tell the owner in one line to close the card on the
   other Mac without starting it: once started, the card stays there and
   `dismiss_task` reports no pending task.
6. If a second TF announces itself for the same card, send it no TASK; tell
   the owner it is a duplicate to close (the TF has not changed anything).
7. If the card becomes unnecessary before it is started, withdraw it with
   `dismiss_task`.
