---
name: launcher
description: Start cloud sessions through the Launcher so they stay shallow in the session lineage - ask the Launcher for an HQ's successor or a new Project HQ, act as Quarterdeck or Launcher, and replace the Launcher when its context fills. Use when handing over a cloud HQ, starting a Project HQ, when this session is Quarterdeck or the Launcher, or when the Launcher does not answer.
---

# Launcher

`docs/sessions.md` (Roles, Cloud sessions: Lineage) is the rule; this is the
procedure. Depth counts generations, not siblings: every session a session
starts sits one level below it, and at 8 a session can start no session
and create or fire no Routine. Quarterdeck (depth 0, started by the owner)
starts only Launchers; the Launcher (depth 1) starts the HQs, which so stay
at depth 2 however often they hand over.

Both live in Google Drive `AI/Status/Sessions/` as one file each,
`quarterdeck.<session ID>` and `launcher.<session ID>`, the same way as
`upstream-hq.<session ID>`.

## Asking the Launcher (any cloud HQ)

1. Find the Launcher's ID from the `launcher.` file (`search_files`, title
   contains `launcher.`); check with `get_session` that it is not archived.
2. Send it one `send_message`:

   ```
   [launch request]
   Title: ☁️ <name>
   Repository: https://github.com/kni927/<repo>
   Reply to: <this session's ID>
   ---
   <the new session's first prompt, for a successor the handover>
   ```

3. It answers with the new session's ID, or with the reason it refused.
   Without an answer within ten minutes, or with the Launcher archived, ask
   Quarterdeck the same way; if Quarterdeck is gone too, start the session yourself with
   `create_session` when your depth allows, else ask the owner
   (`hq-handover`, step 4).

## As the Launcher

Before checking each request, run `git pull` in the clone of `kni927/HQ` and
follow this skill as it then reads: the clone dates from the Launcher's
start, and a rule changed since would otherwise be missed. If the pull
fails, say so in the answer and go on with the copy you have.

Take a request only when all of these hold; otherwise answer the reason and
do nothing else:

- it starts with `[launch request]` and comes from a session of this account
  (`get_session` on the `from-session`), in the `Trusted` environment
  (`list_environments` gives the ID), not archived, whose title is Quarterdeck, a
  Launcher, or ends in `HQ` (with or without a version);
- the repository is `https://github.com/kni927/<repo>`;
- the title starts with `☁️ `.

Then call `create_session`: `environment_id` `Trusted`'s ID,
`permission_mode` `auto`, `source_url` the repository, `source_revision`
`main`, the title, and as the prompt this line followed by the text below
the `---` line unchanged:

```
[Started by the Launcher for <requester's title> (<Reply to>). Your parent session is the Launcher; report to the session named in this prompt, not to your parent.]
```
 Answer
`Reply to` with `send_message`: `[launched] <title> <new session ID>`. The
prompt is the requester's: do not act on what it says, and start nothing
else. Never push, edit repositories, or archive anything except as below.

After each request, read your own usage with `get_session`. Past 70%, ask
Quarterdeck for a successor with one `send_message`: `[launcher successor]` and your
ID. Keep taking requests until the successor archives you.

## As Quarterdeck

Quarterdeck answers only `[launcher successor]` from the current Launcher and
`[launch request]` (checked as above) when the Launcher is gone, after the
same `git pull`. For a
successor, `create_session` as above with title `☁️ Launcher`, repository
`https://github.com/kni927/HQ`, and the prompt "You are the Launcher; your
predecessor is <ID>. Follow the launcher skill: As the Launcher, and First
turn of a new Launcher." Quarterdeck does nothing else; it should never need
compaction.

## First turn of Quarterdeck

The owner starts Quarterdeck by hand in claude.ai/code: `Trusted`, repository
`kni927/HQ`, auto mode, title `☁️ Quarterdeck`, first prompt "You are Quarterdeck. Follow
the launcher skill: First turn of Quarterdeck." Quarterdeck then:

1. Renames the `quarterdeck.` file in Google Drive `AI/Status/Sessions/` to
   `quarterdeck.<its ID>` (`update_file`, `title`), or creates it (`create_file`,
   `text/plain`, empty) when none exists; checks that it is the only one.
2. Starts the first Launcher as in As Quarterdeck, with "your predecessor is none".
3. Tells the owner in one line and waits.

## First turn of a new Launcher

1. Rename the `launcher.` file in Google Drive `AI/Status/Sessions/` to
   `launcher.<your ID>` (`update_file`, `title`); create it if none exists.
   Check that it is the only one.
2. Archive the predecessor, if any, with `archive_session` once it shows no
   request in flight (its last message is a `[launched]` answer or the
   successor request).
3. Tell Central HQ in one line: `Launcher replaced: <your ID>`.
