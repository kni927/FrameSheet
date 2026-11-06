#!/bin/bash
# Builds, notarizes and staples a FrameSheet release from a clean snapshot of
# the current commit:
#
#   scripts/release.sh 3.0.0            the release
#   scripts/release.sh 3.0.0 --dry-run  every step but notarizing and
#                                       stapling; leaves no release zip
#
# 1. checks that tracked files have no changes and records the commit (the
#    owner tags exactly that commit);
# 2. checks out that commit into a temporary worktree (untracked files of the
#    checkout cannot reach the build) and runs its build.sh there with
#    FRAMESHEET_VERSION and FRAMESHEET_RELEASE=1 (Developer ID, hardened
#    runtime, secure timestamp) and a fresh build folder;
# 3. checks the app for private paths (scripts/check-private-paths.sh);
# 4. submits it with `notarytool submit --wait` and staples the ticket;
# 5. zips it to a temporary name, extracts the zip and checks the extracted
#    app (signature, Developer ID authority, hardened runtime, secure
#    timestamp, staple, Gatekeeper, private paths); only then moves the zip
#    to build/FrameSheet-<v>.zip.
# Any failure stops the script; the temporary worktree and archives are
# removed on exit, so a failed run leaves no release-named zip.
#
# Credentials: the notarytool keychain profile, named by
# FRAMESHEET_NOTARY_PROFILE or by the first line of
# ~/.config/framesheet/notary-profile (local, not in the repository). Its
# name is not printed; the script never reads or prints the secret itself.
# It runs outside the sandbox (keychain, network) and always asks first
# (permissions.ask in .claude/settings.json). build/ ends with the .app and
# the release zip only.
set -euo pipefail

VERSION="${1:-}"
DRY_RUN=0
if [ "${2:-}" = "--dry-run" ]; then DRY_RUN=1; elif [ -n "${2:-}" ]; then VERSION=""; fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/release.sh X.Y.Z [--dry-run]" >&2
    exit 2
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameSheet"
BUILD_DIR="$REPO_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
LOG="$HOME/Library/Logs/FrameSheet/release.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "=== release $VERSION$([ "$DRY_RUN" = 1 ] && echo " (dry run)"): checking the checkout ==="
PROFILE="${FRAMESHEET_NOTARY_PROFILE:-}"
PROFILE_FILE="$HOME/.config/framesheet/notary-profile"
if [ -z "$PROFILE" ] && [ -f "$PROFILE_FILE" ]; then
    PROFILE="$(head -1 "$PROFILE_FILE" | tr -d '[:space:]')"
fi
if [ -n "$PROFILE" ]; then
    echo "Notary profile: configured (name not shown)"
elif [ "$DRY_RUN" = 1 ]; then
    echo "Notary profile: not configured (the release would stop here)"
else
    fail "no notarytool keychain profile: set FRAMESHEET_NOTARY_PROFILE, or write its name to ~/.config/framesheet/notary-profile."
fi
if [ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]; then
    fail "uncommitted changes to tracked files; commit them first."
fi
COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "Commit: $COMMIT"

WORK="$(mktemp -d)"
SNAPSHOT="$WORK/snapshot"
cleanup() {
    git -C "$REPO_DIR" worktree remove --force "$SNAPSHOT" >/dev/null 2>&1 || true
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== snapshot of $COMMIT ==="
git -C "$REPO_DIR" worktree add --detach "$SNAPSHOT" "$COMMIT" >/dev/null || fail "could not check out $COMMIT."
[ "$(git -C "$SNAPSHOT" rev-parse HEAD)" = "$COMMIT" ] || fail "the snapshot is not at $COMMIT."
[ -z "$(git -C "$SNAPSHOT" status --porcelain --ignored)" ] || fail "the snapshot is not clean."
echo "Snapshot: clean, at $COMMIT"

echo "=== build ==="
FRAMESHEET_VERSION="$VERSION" FRAMESHEET_RELEASE=1 FRAMESHEET_SCRATCH_PATH="$WORK/scratch" \
    "$SNAPSHOT/build.sh" || fail "the build failed."
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SNAPSHOT/build/$APP_NAME.app/Contents/Info.plist")"
[ "$SHORT" = "$VERSION" ] || fail "the app reports $SHORT, not $VERSION."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ditto "$SNAPSHOT/build/$APP_NAME.app" "$APP"
"$REPO_DIR/scripts/check-private-paths.sh" "$APP" || fail "the app contains private paths."

if [ "$DRY_RUN" = 1 ]; then
    echo "=== notarize and staple: skipped (dry run) ==="
else
    echo "=== notarize ==="
    SUBMIT="$WORK/$APP_NAME-$VERSION-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT"
    RESULT="$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait)" || true
    echo "$RESULT"
    if ! grep -q "status: Accepted" <<<"$RESULT"; then
        ID="$(sed -n 's/^ *id: //p' <<<"$RESULT" | head -1)"
        fail "notarization was not accepted. Log: xcrun notarytool log ${ID:-<id>} --keychain-profile <profile>"
    fi
    echo "=== staple ==="
    xcrun stapler staple "$APP"
fi

echo "=== zip and check the extracted app ==="
STAGED="$WORK/$APP_NAME-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED"
EXTRACTED="$WORK/extracted"
ditto -x -k "$STAGED" "$EXTRACTED"
CHECKED="$EXTRACTED/$APP_NAME.app"
codesign --verify --deep --strict "$CHECKED" || fail "the extracted app's signature does not verify."
SIGNATURE="$(codesign -dv --verbose=4 "$CHECKED" 2>&1)"
grep -q "^Authority=Developer ID Application: " <<<"$SIGNATURE" || fail "not signed with a Developer ID Application identity."
grep -q "^Runtime Version=" <<<"$SIGNATURE" || fail "the hardened runtime is not enabled."
grep -q "^Timestamp=" <<<"$SIGNATURE" || fail "the signature has no secure timestamp."
grep -E "^(Identifier|Authority=Developer ID Application|Timestamp|Runtime Version)" <<<"$SIGNATURE"
if [ "$DRY_RUN" = 1 ]; then
    echo "Staple and Gatekeeper: skipped (dry run, not notarized)"
else
    xcrun stapler validate "$CHECKED" || fail "the extracted app has no valid ticket."
    spctl --assess --type execute -vv "$CHECKED" || fail "Gatekeeper rejects the extracted app."
fi
"$REPO_DIR/scripts/check-private-paths.sh" "$STAGED" || fail "the zip contains private paths."

if [ "$DRY_RUN" = 1 ]; then
    echo "=== dry run: checks passed; the zip would be moved to $(basename "$ZIP") ==="
    ls "$BUILD_DIR"
    echo "Commit: $COMMIT"
    exit 0
fi
mv "$STAGED" "$ZIP"
shasum -a 256 "$ZIP"
ls "$BUILD_DIR"

echo "=== release $VERSION ready ==="
echo "Commit: $COMMIT"
echo "Zip:    $ZIP"
