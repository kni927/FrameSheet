#!/bin/bash
# Tests scripts/check-private-paths.sh: it must fail (exit non-zero) on a
# missing path, an unreadable file, a file with the home path and a file
# with the bare user name, and pass on a clean app and on the approved
# attribution (bundle ID, copyright). Runs inside the sandbox.
#
#   scripts/test-check-private-paths.sh
set -uo pipefail

CHECK="$(cd "$(dirname "$0")" && pwd)/check-private-paths.sh"
USER_NAME="$(id -un)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-private-paths-test.XXXXXX")"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
failures=0

app() {
    local dir="$WORK/$1/FrameSheet.app/Contents"
    mkdir -p "$dir/MacOS"
    printf 'plain binary bytes\n' >"$dir/MacOS/FrameSheet"
    echo "$WORK/$1/FrameSheet.app"
}

expect() {
    local want="$1" name="$2"
    shift 2
    "$CHECK" "$@" >/dev/null 2>&1
    local status=$?
    if { [ "$want" = fail ] && [ "$status" != 0 ]; } || { [ "$want" = pass ] && [ "$status" = 0 ]; }; then
        echo "ok   $name (exit $status)"
    else
        echo "FAIL $name: expected to $want, exit $status"
        failures=$((failures + 1))
    fi
}

clean="$(app clean)"
expect pass "a clean app" "$clean"

expect fail "a missing path" "$WORK/missing/FrameSheet.app"

unreadable="$(app unreadable)"
printf 'x' >"$unreadable/Contents/MacOS/locked"
chmod 000 "$unreadable/Contents/MacOS/locked"
expect fail "an unreadable file" "$unreadable"

home="$(app home)"
printf 'path %s/Projects\n' "$HOME" >>"$home/Contents/MacOS/FrameSheet"
expect fail "the home path" "$home"

bare="$(app bare)"
printf 'built by %s here\n' "$USER_NAME" >>"$bare/Contents/MacOS/FrameSheet"
expect fail "the bare user name" "$bare"

approved="$(app approved)"
printf '<string>com.%s.FrameSheet</string>\n<string>Copyright © 2026 %s. All rights reserved.</string>\n' \
    "$USER_NAME" "$USER_NAME" >"$approved/Contents/Info.plist"
expect pass "the bundle ID and copyright" "$approved"

[ "$failures" = 0 ] && echo "All passed" || echo "$failures failed"
[ "$failures" = 0 ]
