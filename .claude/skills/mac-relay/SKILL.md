---
name: mac-relay
description: Send a later message from a cloud session to a local session on one of the owner's Macs through the Google Drive inbox that handoff-relay on that Mac delivers, as docs/sessions.md "Messages" (Cloud to Mac) describes. Use when a cloud HQ or TF must reach a Mac's base session, the Gate, or a local TF after it has started, since cloud-to-local send_message is refused.
---

# Message a Mac session through the relay

Why a relay: since about 2026-10-20 the server refuses `send_message` from a
cloud session into a local one (`elevated_session_untrusted_device`,
anthropics/claude-code#103864); Mac to cloud and cloud to cloud still arrive.
A refusal offers a card to let the cloud session "use your computers and
other sessions": never approve it. It cannot be undone, and the session then
asks on every send to the Mac, can no longer exchange messages with other
cloud sessions, and needs a fresh sign-in on the Web. The Friday count probes
whether the refusal is lifted.

1. Write one Markdown file to the Mac's inbox in Google Drive,
   `AI/Handoff/Inbox/` for the server Mac or `AI/Handoff/Inbox/Client/` for
   the client Mac (docs/sessions.md, Roles, says which sessions run where),
   with the connector's `create_file` (`contentMimeType` `text/markdown`,
   `disableConversionToGoogleType` true), named
   `YYYYMMDD-HHMMSS-<topic>.md`.
2. The file holds `To: <the session's name>`, then `From: <your name> (<your
   session ID>)`, a `---` line, then the message.
   - `To:` may list alternatives separated by ` | `, and a trailing `*`
     matches a name prefix. For the Gate, give its title and its server
     name prefix (docs/sessions.md, Roles): `ListAgents` names a server
     session by the server's `--name` or a folder-based name, and
     `set_session_title` from the cloud changes only the claude.ai title,
     never the name on the Mac.
   - A TASK for a TF names its HQ on the `From:` line; the TF accepts it as
     from its HQ (`/tf`, step 4).
3. `handoff-relay` on that Mac (dotfiles `docs/AUTOMATIONS.md`) delivers
   it within about five minutes (a sleeping Mac, when it wakes) with a local
   `SendMessage` and moves the file to `done/` under that inbox; a file it
   cannot deliver goes to `failed/` and the owner gets an alert. The
   receiver replies to your session directly.
4. After ten minutes, check the file's parent with `get_file_metadata` (a
   title search lags behind a move). In `failed/`, or still in the inbox of
   a Mac that is awake: write an English message for the owner to paste. A
   file waiting for a sleeping Mac can stay; say so.
5. Say where it went in one English line (`Sent to: <session name> (relay)`).
