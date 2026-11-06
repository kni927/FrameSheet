#!/bin/bash
# Fails when a built app or zip names the build machine's home folder or
# user folder: every file of an app (or of a zip, extracted to a temporary
# folder, and the zip's own listing) is searched for $HOME and /Users/$USER.
# The bare user name is not searched: it is also the bundle ID's and the
# copyright's owner name.
#
#   scripts/check-private-paths.sh <FrameSheet.app | FrameSheet.zip>...
#
# Prints the number of occurrences per file that has any, then a total;
# exits 1 when the total is not 0.
set -euo pipefail

patterns=("$HOME")
[ "/Users/$(id -un)" = "$HOME" ] || patterns+=("/Users/$(id -un)")
total=0
tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; return 0; }
trap cleanup EXIT

count_in() {
    local file="$1" n=0 c p
    for p in "${patterns[@]}"; do
        c="$({ LC_ALL=C grep -a -o -F -- "$p" "$file" || true; } | wc -l | tr -d ' ')"
        n=$((n + c))
    done
    echo "$n"
}

check_dir() {
    local file n
    while IFS= read -r -d '' file; do
        n="$(count_in "$file")"
        if [ "$n" != 0 ]; then
            echo "  $n in ${file#"$1"/}"
            total=$((total + n))
        fi
    done < <(find "$1" -type f -print0)
}

for target in "$@"; do
    echo "Private paths in $(basename "$target"):"
    case "$target" in
    *.zip)
        listing="$(unzip -Z1 "$target")"
        n=0
        for p in "${patterns[@]}"; do
            c="$({ LC_ALL=C grep -o -F -- "$p" <<<"$listing" || true; } | wc -l | tr -d ' ')"
            n=$((n + c))
        done
        if [ "$n" != 0 ]; then echo "  $n in the zip's listing"; total=$((total + n)); fi
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/framesheet-paths.XXXXXX")"
        ditto -x -k "$target" "$tmp"
        check_dir "$tmp"
        rm -rf "$tmp"
        tmp=""
        ;;
    *)
        check_dir "$target"
        ;;
    esac
done
echo "Total: $total"
[ "$total" = 0 ]
