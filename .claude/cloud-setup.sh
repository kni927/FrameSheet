#!/bin/bash
# Setup script of the Trusted cloud environment, shared by every repository
# (kni927/repo-template, scripts/copy-shared.sh). The environment's Setup
# script field holds one line that runs the first copy it finds:
#   for f in /home/user/*/.claude/cloud-setup.sh; do [ -f "$f" ] && exec bash "$f"; done; true  # rev 3
# (no repository attached: nothing to run, and the session still starts).
# The environment caches its result for about seven days, so it also
# registers a SessionStart hook that runs this file again with --refresh at
# every session start: a change synced to the repositories applies there
# without touching the field. Only a plugin change needs the rev raised,
# because plugins load before the hook runs.
# The repositories are already cloned when it runs, but GitHub is not yet
# reachable. kni927/dotfiles docs/CLOUD_ENVIRONMENTS.md explains each part.
version=2026-11-06.1
refresh=0; [ "${1:-}" = --refresh ] && refresh=1

if [ $refresh = 0 ]; then
    claude plugin marketplace add kni927/fast-jev-compaction
    claude plugin install fast-jev-compaction@fast-jev-compaction
fi

# Merge on a diverged pull, as the repositories' rules require.
git config --global pull.rebase false
# Lint for the repositories' bash scripts; not needed to start a session.
# From PyPI (seconds; apt-get update stalled for minutes in a session).
command -v shellcheck >/dev/null ||
    timeout 120 python3 -m pip install -q --user shellcheck-py >/dev/null 2>&1 || true

mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/context-alert.py <<'PY'
# UserPromptSubmit hook for Trusted cloud sessions (setup script). When a
# step of docs/sessions.md "Context usage" first applies (72.5%: ask for
# /compact; 76%: hand over before Claude Code's automatic compaction at about
# 78%; an automatic compaction happened: hand over), it adds one line with
# the usage and that step; later prompts in the same step stay silent
# (owner, 2026-10-31: the session rail shows usage; thresholds 2026-11-04).
import json, os, sys

WINDOW = int(os.environ.get("CONTEXT_WINDOW_TOKENS", "1000000"))
try:
    path = json.load(sys.stdin).get("transcript_path") or ""
    compactions, automatic, used = 0, 0, 0
    with open(path, "rb") as f:
        for raw in f:
            if b'"compact_boundary"' in raw:
                try:
                    e = json.loads(raw)
                    if e.get("subtype") == "compact_boundary":
                        compactions, used = compactions + 1, 0
                        if (e.get("compactMetadata") or {}).get("trigger") != "manual":
                            automatic += 1
                        continue
                except ValueError:
                    pass
            if b'"usage"' not in raw or b'"assistant"' not in raw:
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if e.get("type") != "assistant" or e.get("isSidechain"):
                continue
            u = (e.get("message") or {}).get("usage") or {}
            used = sum(u.get(k) or 0 for k in
                       ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")) or used
except Exception:
    sys.exit(0)
pct = used * 100 / WINDOW
if automatic:
    stage = f"auto{automatic}"
    step = ("an automatic compaction replaced earlier detail with a summary: a cloud HQ "
            "hands over at the next natural break")
elif pct >= 76:
    stage = f"handover{compactions}"
    step = ("a cloud HQ hands over at the next natural break, before the automatic "
            "compaction at about 78%")
elif pct >= 72.5:
    stage = f"ask{compactions}"
    step = "a cloud HQ ends its reply with the one-line /compact request"
else:
    sys.exit(0)
mark = path + ".context-alert"
try:
    with open(mark) as f:
        if f.read().strip() == stage:
            sys.exit(0)
except OSError:
    pass
try:
    with open(mark, "w") as f:
        f.write(stage)
except OSError:
    pass
print(f'Context usage: {pct:.1f}% ({used:,} / {WINDOW:,} tokens); {step} '
      '(docs/sessions.md "Context usage").')
PY

# notation-check runs only on the Macs, where it records silently; cloud
# replies are checked afterwards by the Friday cloud dialog count (2026-11-01).
rm -f ~/.claude/hooks/notation-check

# MessageDisplay hook: notation-display, a verbatim copy of kni927/dotfiles
# dot_local/bin/claude-hooks/executable_notation-display (change it there and
# copy it here), so every cloud session shows replies with the owner's notation.
cat > ~/.claude/hooks/notation-display <<'PY'
#!/usr/bin/env python3
"""MessageDisplay hook: show replies with the owner's notation, once.

The Notation rules (custom instructions, AGENTS.md "Language and notation")
say dates are YYYY-MM-DD or M/D and Japanese text has no space next to Latin
letters, digits or inline code. This hook rewrites what is displayed: a
year-less MM-DD date becomes M/D ("11-01" -> "11/1") and such a space is
removed. It is display-only (the transcript and what Claude reads keep the
original), so a reply is shown once, corrected, where a Stop hook could
only add a second display (owner, 2026-11-01).

Claude Code calls it for each batch of newly completed lines of an
assistant message. Fenced code blocks can span batches, so whether a batch
starts inside a fence is kept in a small state file per message. Inline
code, link text, URLs and 「」『』 quotations are left as written; a space
next to inline code is still removed. On a Mac each batch it changed adds a
JSON line to ~/Library/Logs/claude-notation-check.log ("hook": "display").
Any error prints nothing, so the original text is shown.
"""

import json
import os
import re
import sys
import tempfile
import time

JP = "\u3040-\u30ff\u3400-\u9fff"
# Placeholders for protected spans: \ue000..\ue001 stands for inline code and
# counts as Latin for the space rule; \ue002..\ue003 is neutral.
LAT = "A-Za-z0-9`*\ue000\ue001"
SPACE_A = re.compile(rf"([{JP}]) +(?=[{LAT}])")
SPACE_B = re.compile(rf"([{LAT}]) +(?=[{JP}])")
MMDD = re.compile(r"(?<![\d.:/\-])(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?![\d:/\-])")
INLINE = re.compile(r"`[^`\n]*`")
OTHER = re.compile(r"\[[^\]\n]*\]\([^)\s]*\)|https?://\S+|「[^」\n]*」|『[^』\n]*』")
FENCE = re.compile(r"^\s*(```|~~~)")


def fix_line(line, found):
    kept = []

    def hold(kind):
        def sub(m):
            kept.append(m.group(0))
            n = len(kept) - 1
            return f"\ue000{n}\ue001" if kind == "code" else f"\ue002{n}\ue003"
        return sub

    text = INLINE.sub(hold("code"), line)
    text = OTHER.sub(hold("other"), text)

    def date(m):
        found["dates"].append(m.group(0))
        return f"{int(m.group(1))}/{int(m.group(2))}"

    text = MMDD.sub(date, text)
    for rx in (SPACE_A, SPACE_B):
        text, n = rx.subn(r"\1", text)
        found["spaces"] += n
    # A quotation can hold inline code, so a restored span may itself hold a
    # placeholder; restore until none is left.
    ph = re.compile(r"[\ue000\ue002](\d+)[\ue001\ue003]")
    for _ in range(len(kept) + 1):
        if not ph.search(text):
            break
        text = ph.sub(lambda m: kept[int(m.group(1))], text)
    return text


def main():
    try:
        data = json.load(sys.stdin)
        delta = data.get("delta", "")
        msg = re.sub(r"[^A-Za-z0-9-]", "", str(data.get("message_id", "")))[:64]
        final = bool(data.get("final"))
    except Exception:
        return
    if not delta and not final:
        return

    state = os.path.join(tempfile.gettempdir(), f"claude-notation-display.{msg}")
    in_fence = False
    if data.get("index", 0) and os.path.exists(state):
        in_fence = True
    found = {"dates": [], "spaces": 0}
    out = []
    for line in delta.splitlines(keepends=True):
        if FENCE.match(line):
            in_fence = not in_fence
            out.append(line)
        elif in_fence:
            out.append(line)
        else:
            out.append(fix_line(line, found))
    try:
        if in_fence and not final:
            open(state, "w").close()
        elif os.path.exists(state):
            os.remove(state)
    except OSError:
        pass

    shown = "".join(out)
    if shown == delta or re.search("[\ue000-\ue003]", shown):
        return  # unchanged, or a placeholder survived: show the original
    logs = os.path.expanduser("~/Library/Logs")
    if os.path.isdir(logs):
        try:
            with open(os.path.join(logs, "claude-notation-check.log"), "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "hook": "display",
                    "cwd": data.get("cwd", ""),
                    "session": data.get("session_id", ""),
                    "message": msg,
                    "dates": found["dates"],
                    "spaces": found["spaces"],
                }, ensure_ascii=False) + "\n")
        except OSError:
            pass
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "MessageDisplay", "displayContent": shown}}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
PY
chmod 755 ~/.claude/hooks/notation-display

# work-timer: a verbatim copy of kni927/dotfiles
# dot_local/bin/claude-hooks/executable_work-timer (change it there and copy it
# here). Logs each turn's elapsed time and the time spent on dialogs.
cat > ~/.claude/hooks/work-timer <<'PY'
#!/usr/bin/env python3
"""Hook: measure a session's working time apart from time spent waiting on the owner.

Registered on UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure
and Stop. A turn runs from the prompt to Stop; time between turns is the
owner's and is never counted. Inside a turn, a tool call that waited on a
permission dialog shows up as a gap: PostToolUse's `duration_ms` excludes the
time spent in permission prompts, so the wait is
(PostToolUse time - PreToolUse time) - duration_ms. Overlapping waits
(parallel calls, subagents) are merged so no second is counted twice.

A turn started by a background-task notification (a build or test run with
run_in_background finished) counts the gap since the previous Stop as
working time (`background_s`): the session was working, not the owner. A
turn started by another session's message counts its gap as waiting on that
session (`peer_wait_s`). Only a gap before the owner's own prompt stays
uncounted. The kind comes from the prompt text, or from the transcript's
last user entry (`origin.kind`) when the text does not tell.

Each finished turn appends one JSON line to the log, with any `Estimate:`
or `Took:` line of the turn's last reply, so estimates can be compared with
the measured time. Prints nothing and
always exits 0, so it never changes a decision or blocks a turn.

    work-timer --report [--since ISO-TIME] [--session ID | --cwd DIR]

sums the logged turns: elapsed, waited on the owner, and working time.
"""

import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
MAC_LOGS = HOME / "Library" / "Logs"
LOG = (MAC_LOGS if MAC_LOGS.is_dir() else HOME / ".claude") / "claude-work-time.log"
STATE_DIR = HOME / ".claude" / "work-timer"
MIN_WAIT = 1.0  # seconds; smaller gaps are hook overhead, not a dialog


def iso(t):
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def merged_length(intervals):
    total, end = 0.0, None
    for a, b in sorted(intervals):
        if end is None or a > end:
            total += b - a
            end = b
        elif b > end:
            total += b - end
            end = b
    return total


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def tagged_lines(text):
    return [l.strip() for l in (text or "").splitlines()
            if l.strip().startswith(("Estimate:", "Took:"))][:4]


def prompt_kind(data):
    text = (data.get("prompt") or "").lstrip()
    if text.startswith("<task-notification>"):
        return "task-notification"
    if text.startswith(("<cross-session-message", "Another Claude session sent a message")):
        return "peer"
    try:  # the transcript's last user entry carries origin.kind
        with open(data.get("transcript_path") or "", "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 262144))
            tail = f.read().decode("utf-8", "ignore").splitlines()
        for raw in reversed(tail):
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if e.get("type") == "user" and isinstance(e.get("origin"), dict):
                return e["origin"].get("kind") or "human"
    except OSError:
        pass
    return "human"


def close_turn(state, end, session_id, how, reply=None):
    waits = state.get("waits", [])
    line = {
        "time": iso(end),
        "session_id": session_id,
        "cwd": state.get("cwd"),
        "start": iso(state["start"]),
        "elapsed_s": round(end - state["start"]),
        "waited_s": round(merged_length(waits)),
        "dialogs": len(waits),
        "end": how,
    }
    for key in ("background_s", "peer_wait_s"):
        if state.get(key):
            line[key] = round(state[key])
    tags = tagged_lines(reply)
    if tags:
        line["lines"] = tags
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")


def hook():
    try:
        data = json.loads(sys.stdin.read())
    except ValueError:
        return
    now = time.time()
    event = data.get("hook_event_name")
    session_id = data.get("session_id") or "unknown"
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = STATE_DIR / f"{session_id}.json"
    state = load(path)

    if event == "UserPromptSubmit":
        if state:  # the last turn never reached Stop (interrupted)
            close_turn(state, state.get("last", state["start"]), session_id, "interrupted")
        state = {"start": now, "last": now, "cwd": data.get("cwd"), "pre": {}, "waits": []}
        stopped = load(STATE_DIR / f"{session_id}.stop")
        if stopped and stopped.get("t") and now > stopped["t"]:
            gap = now - stopped["t"]
            kind = prompt_kind(data)
            if kind == "task-notification":
                state["background_s"] = gap
            elif kind == "peer":
                state["peer_wait_s"] = gap
    elif state is None:
        # A turn that did not start with a prompt (a message from another
        # session, a scheduled task): start it at the first event we see.
        state = {"start": now, "last": now, "cwd": data.get("cwd"), "pre": {}, "waits": []}

    if event == "PreToolUse" and data.get("tool_use_id"):
        state["pre"][data["tool_use_id"]] = now
    elif event in ("PostToolUse", "PostToolUseFailure"):
        started = state["pre"].pop(data.get("tool_use_id"), None)
        duration = (data.get("duration_ms") or 0) / 1000
        if started is not None and (now - started) - duration >= MIN_WAIT:
            state["waits"].append([started, now - duration])

    state["last"] = now
    if event == "Stop":
        close_turn(state, now, session_id, "stop", data.get("last_assistant_message"))
        path.unlink(missing_ok=True)
        (STATE_DIR / f"{session_id}.stop").write_text(json.dumps({"t": now}))
    else:
        path.write_text(json.dumps(state))


def report(args):
    since = session = cwd = None
    it = iter(args)
    for a in it:
        if a == "--since":
            since = datetime.fromisoformat(next(it)).astimezone()
        elif a == "--session":
            session = next(it)
        elif a == "--cwd":
            cwd = os.path.realpath(next(it))
    elapsed = waited = dialogs = turns = background = peer = 0
    try:
        lines = LOG.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    for raw in lines:
        try:
            t = json.loads(raw)
        except ValueError:
            continue
        if session and t.get("session_id") != session:
            continue
        if cwd and os.path.realpath(t.get("cwd") or "") != cwd:
            continue
        if since and datetime.fromisoformat(t["start"]) < since:
            continue
        turns += 1
        elapsed += t.get("elapsed_s", 0)
        waited += t.get("waited_s", 0)
        dialogs += t.get("dialogs", 0)
        background += t.get("background_s", 0)
        peer += t.get("peer_wait_s", 0)

    def mins(s):
        return f"{round(s / 60)} min" if s >= 60 else f"{s} s"

    print(
        f"turns {turns}, elapsed {mins(elapsed)}, waited on the owner {mins(waited)} "
        f"({dialogs} dialogs), background {mins(background)}, "
        f"working {mins(elapsed - waited + background)}, "
        f"waited on other sessions {mins(peer)}"
    )


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--report"]:
            report(sys.argv[2:])
        else:
            hook()
    except Exception:  # a hook must never break the session
        pass
    sys.exit(0)
PY
chmod 755 ~/.claude/hooks/work-timer

# pre-commit for public repositories, a verbatim copy of kni927/dotfiles
# dot_config/git/public-hooks/executable_pre-commit (change it there and copy it
# here). Clones whose AGENTS.md has "## Public Repository" use it; a clone added
# later in the session gets it at the next refresh.
mkdir -p ~/.claude/git-hooks
cat > ~/.claude/git-hooks/pre-commit <<'PY'
#!/usr/bin/env python3
"""pre-commit for public repositories: stop personal details before they publish.

A repository whose AGENTS.md has a "## Public Repository" section (cooViewer,
FrameSheet) must not commit absolute home-directory paths, machine models,
hostnames, session IDs, or local session-transcript paths. A push cannot be
taken back, so this checks the lines a commit adds before it exists (owner,
2026-11-01). chezmoi (Macs) and cloud-setup.sh (cloud sessions) point
`core.hooksPath` of each such clone here.

Files copied verbatim from kni927/repo-template (.claude/, docs/sessions.md)
are not checked: they are reviewed there and copy-shared.sh commits them.
"""

import re
import subprocess
import sys

SKIP = re.compile(r"^(\.claude/|docs/sessions\.md$)")
CHECKS = [
    ("home-directory path", re.compile(
        r"/Users/(?!\.\.\.|<|Shared\b)[A-Za-z0-9._-]+|/home/(?!user/|<)[a-z][a-z0-9_-]*/|/var/folders/")),
    ("session-transcript path", re.compile(r"\.claude/projects/-")),
    ("session ID", re.compile(r"session_01[A-Za-z0-9]{16,}")),
    ("hostname", re.compile(r"[A-Za-z0-9-]+\.ts\.net\b|(?<![\w.*])[A-Za-z0-9-]+\.local(?![.\w-])")),
    ("machine model", re.compile(r"\b(Mac ?mini|MacBook( Air| Pro)?|iMac|Mac Studio|Mac Pro)\b")),
]


def main():
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--diff-filter=ACMR"],
        capture_output=True, text=True, errors="replace").stdout
    found, path, line_no = [], None, 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            continue
        if line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            line_no = int(m.group(1)) if m else 0
            continue
        if not line.startswith("+") or path is None:
            continue
        text = line[1:]
        if not SKIP.match(path):
            for kind, rx in CHECKS:
                m = rx.search(text)
                if m:
                    found.append(f"  {path}:{line_no}: {kind}: {m.group(0)}")
        line_no += 1
    if not found:
        return 0
    print("pre-commit: this is a public repository (AGENTS.md, Public Repository).", file=sys.stderr)
    print("These added lines would publish personal details:", file=sys.stderr)
    print("\n".join(found[:20]), file=sys.stderr)
    if len(found) > 20:
        print(f"  ... and {len(found) - 20} more", file=sys.stderr)
    print("Rewrite them (repository-relative paths, ~/..., generic names). If a match "
          "is a false positive, ask the owner; do not commit with --no-verify.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never block a commit because the check itself broke
        print(f"pre-commit: check skipped ({e})", file=sys.stderr)
        sys.exit(0)
PY
chmod 755 ~/.claude/git-hooks/pre-commit
for repo in /home/user/*/; do
  repo="${repo%/}"
  [ -e "$repo/.git" ] && [ -f "$repo/AGENTS.md" ] || continue
  grep -q '^## Public Repository' "$repo/AGENTS.md" || continue
  [ -z "$(git -C "$repo" config --local core.hooksPath)" ] || continue
  git -C "$repo" config --local core.hooksPath ~/.claude/git-hooks
done

python3 - <<'PY'
import json, os

p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}
# The plugin cannot start a compaction in a session run through the SDK, which
# cloud and desktop sessions are; only /compact reaches it (2026-11-04).
d.setdefault("pluginConfigs", {})["fast-jev-compaction@fast-jev-compaction"] = {"options": {"compactAtPercent": 100}}
d["attribution"] = {"commit": "", "pr": "", "sessionUrl": True}
allow = d.setdefault("permissions", {}).setdefault("allow", [])
# A connector appears under its readable name or under its UUID (a session
# that starts before the names resolve gets the UUID), so allow both.
connectors = [
    (["mcp__Google_Drive__", "mcp__ca13bbc7-3ace-4182-a80a-b7d9af123922__"],
     ["search_files", "read_file_content", "get_file_metadata", "download_file_content",
      "list_recent_files", "create_file", "copy_file", "update_file"]),
    (["mcp__Google_Sheets__", "mcp__2d95d009-6258-4f5b-abda-f43840ca0f1e__"],
     ["get_spreadsheet", "get_values", "update_values", "append_values",
      "insert_dimension", "update_formulas", "update_spreadsheet"]),
    (["mcp__Google_Docs__", "mcp__103325ab-b59c-4104-8fa2-2268c2d45ec3__"],
     ["read_doc", "update_doc"]),
    (["mcp__Dropbox__", "mcp__66031e7b-6d10-46d4-8e1b-9e116400fb26__"],
     ["list_folder", "search", "fetch", "get_file_metadata", "create_file", "create_folder"]),
]
for t in ["mcp__claude-code-remote__add_repo", "mcp__claude-code-remote__archive_session",
          "mcp__claude-artifacts__db_write"] + [
    pre + tool for prefixes, tools in connectors for pre in prefixes for tool in tools
]:
    if t not in allow:
        allow.append(t)
# Connectors (kni927/dotfiles DECISIONS 2026-10-23). With a kni927/dotfiles
# clone, its connector-guard hook and lists decide Gmail send and the AI
# calendar, as on the Macs. Without one, send is denied and a calendar delete
# asks. Reply and forward are denied either way.
src = "/home/user/dotfiles"
guard_src = f"{src}/dot_local/bin/claude-hooks/executable_connector-guard"
guarded = os.path.isfile(guard_src)
guard = os.path.expanduser("~/.claude/hooks/connector-guard")
if guarded:
    import shutil
    shutil.copyfile(guard_src, guard)
    os.chmod(guard, 0o755)
    conf = os.path.expanduser("~/.config/claude-hooks")
    os.makedirs(conf, exist_ok=True)
    for name in ("mail-recipients", "ai-calendars"):
        shutil.copyfile(f"{src}/dot_config/claude-hooks/{name}", f"{conf}/{name}")
perms = d["permissions"]
gmail = ["mcp__Gmail__", "mcp__2e96074d-f9a9-46b6-ba7f-03f3f1fd2fe5__"]
calendar = ["mcp__Google_Calendar__", "mcp__3a55ff32-6a11-4191-bb2c-b9c58d7989e9__"]
for key, tools, wanted in [
    ("deny", [g + t for g in gmail for t in ("reply", "forward")], True),
    ("deny", [g + "send_message" for g in gmail], not guarded),
    ("ask", [c + "delete_event" for c in calendar], not guarded),
    # Exa's agent_run is metered (up to $5 a run by default); search and fetch stay free of a dialog.
    ("ask", ["mcp__Exa__agent_run"], True),
]:
    rules = perms.setdefault(key, [])
    for tool in tools:
        if wanted and tool not in rules:
            rules.append(tool)
        if not wanted and tool in rules:
            rules.remove(tool)
pre = d.setdefault("hooks", {}).setdefault("PreToolUse", [])
pre[:] = [g for g in pre if guard not in json.dumps(g)]
if guarded:
    pre.append({"matcher": "mcp__.*__(send_message|reply|forward|create_event|update_event|delete_event)",
                "hooks": [{"type": "command", "command": guard, "timeout": 10}]})
ask_src = f"{src}/dot_local/bin/claude-hooks/executable_owner-ask-check"
ask_check = os.path.expanduser("~/.claude/hooks/owner-ask-check")
stop = d.setdefault("hooks", {}).setdefault("Stop", [])
stop[:] = [g for g in stop if ask_check not in json.dumps(g)]
# owner-ask-check records only on the Macs; the Friday cloud dialog count
# scans cloud transcripts with it instead (2026-11-01).
if os.path.exists(ask_check):
    os.remove(ask_check)
display = os.path.expanduser("~/.claude/hooks/notation-display")
shown = d.setdefault("hooks", {}).setdefault("MessageDisplay", [])
shown[:] = [g for g in shown if display not in json.dumps(g)]
shown.append({"hooks": [{"type": "command", "command": display, "timeout": 5}]})
notation = os.path.expanduser("~/.claude/hooks/notation-check")
stop[:] = [g for g in stop if notation not in json.dumps(g)]
refresh = ('for f in /home/user/*/.claude/cloud-setup.sh; do [ -f "$f" ] && '
           'exec bash "$f" --refresh >/dev/null 2>&1; done; true')
for event, hook in [
    ("UserPromptSubmit", {"type": "command", "command": "python3 -I ~/.claude/hooks/context-alert.py", "timeout": 10}),
    ("SessionStart", {"type": "command", "command": refresh, "timeout": 120}),
]:
    groups = d.setdefault("hooks", {}).setdefault(event, [])
    if not any(hook in g.get("hooks", []) for g in groups):
        groups.append({"hooks": [hook]})
timer = os.path.expanduser("~/.claude/hooks/work-timer")
for event, matcher in [("UserPromptSubmit", None), ("PreToolUse", "*"), ("PostToolUse", "*"),
                       ("PostToolUseFailure", "*"), ("Stop", None)]:
    groups = d.setdefault("hooks", {}).setdefault(event, [])
    groups[:] = [g for g in groups if timer not in json.dumps(g)]
    entry = {"hooks": [{"type": "command", "command": timer, "timeout": 5}]}
    if matcher:
        entry = {"matcher": matcher, **entry}
    groups.append(entry)
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"), indent=2)
PY

# Which copy ran last, for checking a session.
echo "$version $(date -u +%FT%TZ) refresh=$refresh" > ~/.claude/cloud-setup.version
