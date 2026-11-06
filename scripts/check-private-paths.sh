#!/bin/bash
# Fails when a built app or zip names the build machine's home folder or
# user: every file of an app (or of a zip, extracted to a temporary folder,
# and the zip's own listing) is searched for $HOME and /Users/<user>, and
# its printable text (runs of 4 or more printable bytes, so compressed image
# data does not match by chance) for the bare user name as a word. The
# approved attribution is not counted: the bundle ID (com.<user>.) and the
# copyright line build.sh writes ("<user>. All rights reserved."). Any file
# that cannot be listed or read fails the check too, as does a missing
# target.
#
#   scripts/check-private-paths.sh <FrameSheet.app | FrameSheet.zip>...
#
# Prints the number of occurrences per file that has any (never the text),
# then a total; exits 1 when the total is not 0 or a file could not be
# checked. Tested by scripts/test-check-private-paths.sh.
set -euo pipefail

user="$(id -un)"
paths=("$HOME")
[ "/Users/$user" = "$HOME" ] || paths+=("/Users/$user")
total=0
errors=0
tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; return 0; }
trap cleanup EXIT

# Occurrences of fixed string $1 in file $2 (grep -w when $3 is "word");
# a read error makes it fail.
occurrences() {
    local status=0 out
    if [ "${3:-}" = word ]; then
        out="$(LC_ALL=C grep -a -o -w -F -- "$1" "$2")" || status=$?
    else
        out="$(LC_ALL=C grep -a -o -F -- "$1" "$2")" || status=$?
    fi
    [ "$status" -le 1 ] || return 1
    [ -n "$out" ] && printf '%s\n' "$out" | wc -l | tr -d ' ' || echo 0
}

# The private paths and user names in one file, less the approved
# attribution; "error" when the file cannot be read.
count_in() {
    local file="$1" n=0 c p text status=0
    [ -r "$file" ] || { echo error; return; }
    for p in "${paths[@]}"; do
        c="$(occurrences "$p" "$file")" || { echo error; return; }
        n=$((n + c))
    done
    text="$(mktemp "${TMPDIR:-/tmp}/framesheet-text.XXXXXX")"
    LC_ALL=C grep -a -o -E '[[:print:]]{4,}' "$file" >"$text" || status=$?
    if [ "$status" -gt 1 ]; then rm -f "$text"; echo error; return; fi
    c="$(occurrences "$user" "$text" word)" || { rm -f "$text"; echo error; return; }
    n=$((n + c))
    # The approved attribution, and the user name inside a path counted above.
    for p in "com.$user." "$user. All rights reserved." "${paths[@]}"; do
        c="$(occurrences "$p" "$text")" || { rm -f "$text"; echo error; return; }
        n=$((n - c))
    done
    rm -f "$text"
    [ "$n" -ge 0 ] || n=0
    echo "$n"
}

check_dir() {
    local root="$1" file n list
    list="$(mktemp "${TMPDIR:-/tmp}/framesheet-files.XXXXXX")"
    if ! find "$root" -type f -print0 >"$list" 2>/dev/null; then
        echo "  cannot list every file"
        errors=$((errors + 1))
    fi
    while IFS= read -r -d '' file; do
        n="$(count_in "$file")"
        if [ "$n" = error ]; then
            echo "  cannot read ${file#"$root"/}"
            errors=$((errors + 1))
        elif [ "$n" != 0 ]; then
            echo "  $n in ${file#"$root"/}"
            total=$((total + n))
        fi
    done <"$list"
    rm -f "$list"
}

[ "$#" -gt 0 ] || { echo "usage: scripts/check-private-paths.sh <app | zip>..." >&2; exit 2; }
for target in "$@"; do
    echo "Private paths in $(basename "$target"):"
    if [ ! -e "$target" ]; then
        echo "  missing"
        errors=$((errors + 1))
        continue
    fi
    case "$target" in
    *.zip)
        listing="$(mktemp "${TMPDIR:-/tmp}/framesheet-listing.XXXXXX")"
        if unzip -Z1 "$target" >"$listing"; then
            n="$(count_in "$listing")"
            if [ "$n" = error ]; then errors=$((errors + 1)); elif [ "$n" != 0 ]; then
                echo "  $n in the zip's listing"
                total=$((total + n))
            fi
        else
            echo "  cannot list the zip"
            errors=$((errors + 1))
        fi
        rm -f "$listing"
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/framesheet-paths.XXXXXX")"
        if ditto -x -k "$target" "$tmp"; then
            check_dir "$tmp"
        else
            echo "  cannot extract the zip"
            errors=$((errors + 1))
        fi
        rm -rf "$tmp"
        tmp=""
        ;;
    *)
        check_dir "$target"
        ;;
    esac
done
echo "Total: $total$([ "$errors" = 0 ] || echo ", $errors not checked")"
[ "$total" = 0 ] && [ "$errors" = 0 ]
