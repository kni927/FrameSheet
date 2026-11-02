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
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_DIR="${FRAMESHEET_SCRATCH_PATH:-$HOME/Library/Caches/FrameSheet/build}"
MODE="${1:-}"

if [ "$MODE" = "launch" ]; then
    open "$HOME/Applications/FrameSheet.app"
    echo "Launched: ~/Applications/FrameSheet.app"
    exit 0
fi

if [ "$MODE" != "build" ]; then
    echo "=== swift test ==="
    swift test --package-path "$REPO_DIR" --scratch-path "$SCRATCH_DIR"
fi

echo "=== build.sh ==="
"$REPO_DIR/build.sh"

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
