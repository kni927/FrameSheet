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
version=2026-11-01.7
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
# step of docs/sessions.md "Context usage" first applies (70% before any
# compaction, 75% after one, each later compaction), it adds one line with
# the usage, the compaction count, and that step; later prompts in the same
# step stay silent (owner, 2026-10-31: the session rail shows usage).
import json, os, sys

WINDOW = int(os.environ.get("CONTEXT_WINDOW_TOKENS", "1000000"))
try:
    path = json.load(sys.stdin).get("transcript_path") or ""
    compactions, used = 0, 0
    with open(path, "rb") as f:
        for raw in f:
            if b'"compact_boundary"' in raw:
                try:
                    if json.loads(raw).get("subtype") == "compact_boundary":
                        compactions, used = compactions + 1, 0
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
pct = used * 100 // WINDOW
if compactions == 0 and pct >= 70:
    step = ("no compaction yet: a cloud HQ ends its reply with the one-line /compact "
            "request and does not hand over")
elif compactions == 1 and pct >= 75:
    step = "compacted once: a cloud HQ hands over at the next natural break"
elif compactions >= 2:
    step = f"compacted {compactions} times: a cloud HQ hands over at the next natural break"
else:
    sys.exit(0)
stage, mark = str(min(compactions, 99)), path + ".context-alert"
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
print(f'Context usage: {pct}% ({used:,} / {WINDOW:,} tokens); {step} '
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
    return re.sub(r"[\ue000\ue002](\d+)[\ue001\ue003]", lambda m: kept[int(m.group(1))], text)


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
    if shown == delta:
        return
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

python3 - <<'PY'
import json, os

p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("pluginConfigs", {})["fast-jev-compaction@fast-jev-compaction"] = {"options": {"compactAtPercent": 78}}
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
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"), indent=2)
PY

# Which copy ran last, for checking a session.
echo "$version $(date -u +%FT%TZ) refresh=$refresh" > ~/.claude/cloud-setup.version
