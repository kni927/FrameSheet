#!/bin/bash
# Runs everything a change needs outside the Claude Code sandbox in one go:
# `swift test`, then ./build.sh, then (with "install") a copy of the app to
# ~/Applications. SwiftPM cannot build inside the sandbox (nested
# sandbox-exec, XCBuildData writes), so batching avoids a dialog per step.
#
#   scripts/check.sh            test + build
#   scripts/check.sh install    test + build + install to ~/Applications
#                               and launch the installed copy
#   scripts/check.sh build      build only (skip tests)
#   scripts/check.sh launch     launch ~/Applications/FrameSheet.app by path
#                               (by name, macOS may pick /Applications instead)
#   scripts/check.sh stop       stop a running check.sh and the processes it
#                               started (the sandbox cannot stop them)
#
# The last run's full output is in ~/Library/Logs/FrameSheet/check.log.
#
# A run stops itself after FRAMESHEET_CHECK_TIMEOUT seconds (default 900).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_DIR="${FRAMESHEET_SCRATCH_PATH:-$HOME/Library/Caches/FrameSheet/build}"
TIMEOUT="${FRAMESHEET_CHECK_TIMEOUT:-900}"
MODE="${1:-}"

# The whole run also goes to a log, so a failure is readable when a caller
# shows only part of the output.
LOG="$HOME/Library/Logs/FrameSheet/check.log"
if [ "$MODE" != "stop" ] && [ "$MODE" != "launch" ]; then
    mkdir -p "$(dirname "$LOG")"
    exec > >(tee "$LOG") 2>&1
fi

# Prints the process IDs below $1, deepest first. Uses ps, which works
# inside the Claude Code sandbox too (pgrep cannot list processes there).
descendants() {
    local child
    for child in $(ps -A -o pid=,ppid= | awk -v p="$1" '$2 == p { print $1 }'); do
        descendants "$child"
        echo "$child"
    done
}

# Prints the process IDs whose command line contains $1.
matching() {
    ps -A -o pid=,command= | awk -v s="$1" 'index($0, s) { print $1 }'
}

# Stops $1 and everything below it.
stop_tree() {
    local pids
    pids="$(descendants "$1") $1"
    kill -TERM $pids 2>/dev/null || true
    sleep 2
    kill -KILL $pids 2>/dev/null || true
}

if [ "$MODE" = "stop" ]; then
    # This stop run and the shells above it also name check.sh: skip them.
    keep=" $$ "
    pid=$$
    while [ "$pid" -gt 1 ]; do
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ -n "$pid" ] || break
        keep="$keep$pid "
    done
    found=0
    for pid in $(matching "scripts/check.sh"); do
        case "$keep" in *" $pid "*) continue ;; esac
        # Skip this run's own (already finished) subshells.
        [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$$" ] && continue
        kill -0 "$pid" 2>/dev/null || continue
        echo "Stopping check.sh $pid and its processes"
        stop_tree "$pid"
        found=1
    done
    # SwiftPM processes left behind by an earlier run on this scratch path.
    for pid in $(matching "--scratch-path $SCRATCH_DIR"); do
        kill -0 "$pid" 2>/dev/null || continue
        echo "Stopping $pid ($(ps -o comm= -p "$pid" 2>/dev/null || echo gone))"
        stop_tree "$pid"
        found=1
    done
    [ "$found" = 1 ] || echo "Nothing to stop"
    exit 0
fi

if [ "$MODE" = "launch" ]; then
    open "$HOME/Applications/FrameSheet.app"
    echo "Launched: ~/Applications/FrameSheet.app"
    exit 0
fi

# A hung test or build stops after TIMEOUT seconds instead of blocking the
# caller: each long step runs in its own process group, which is stopped as a
# whole (swift-test and its testing helper included) when the deadline passes.
DEADLINE=$((SECONDS + TIMEOUT))
STEP_PID=""
trap '[ -n "$STEP_PID" ] && kill -TERM -- "-$STEP_PID" 2>/dev/null; exit 130' INT TERM

run_step() {
    set -m
    "$@" &
    STEP_PID=$!
    set +m
    while kill -0 "$STEP_PID" 2>/dev/null; do
        if [ "$SECONDS" -ge "$DEADLINE" ]; then
            echo "check.sh: timed out after ${TIMEOUT} s in: $*; stopping" >&2
            kill -TERM -- "-$STEP_PID" 2>/dev/null || true
            sleep 2
            kill -KILL -- "-$STEP_PID" 2>/dev/null || true
            exit 124
        fi
        sleep 1
    done
    local status=0
    wait "$STEP_PID" || status=$?
    STEP_PID=""
    return "$status"
}

if [ "$MODE" != "build" ]; then
    echo "=== swift test ==="
    run_step swift test --package-path "$REPO_DIR" --scratch-path "$SCRATCH_DIR"
fi

echo "=== build.sh ==="
run_step "$REPO_DIR/build.sh"

echo "=== build/ contents ==="
ls -1 "$REPO_DIR/build"

if [ "$MODE" = "install" ]; then
    echo "=== install to ~/Applications ==="
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/FrameSheet.app"
    ditto "$REPO_DIR/build/FrameSheet.app" "$HOME/Applications/FrameSheet.app"
    echo "Installed: ~/Applications/FrameSheet.app"
    open "$HOME/Applications/FrameSheet.app"
    echo "Launched: ~/Applications/FrameSheet.app"
fi
