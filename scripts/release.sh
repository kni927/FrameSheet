#!/bin/bash
# Builds, notarizes and staples a FrameSheet release from a clean checkout:
#
#   scripts/release.sh 3.0.0
#
# 1. checks that the working tree is clean and records the commit (the owner
#    tags exactly that commit);
# 2. ./build.sh with FRAMESHEET_VERSION and FRAMESHEET_RELEASE=1 (Developer
#    ID, hardened runtime, secure timestamp);
# 3. zips the app and submits it with `notarytool submit --wait`;
# 4. staples the ticket, re-zips the stapled app as build/FrameSheet-<v>.zip;
# 5. checks it with `stapler validate`, `spctl --assess` and `codesign -dv`.
#
# Credentials: the notarytool keychain profile named by
# FRAMESHEET_NOTARY_PROFILE (default: the profile the owner's other apps
# use). The script never reads or prints the secret itself. It runs outside
# the sandbox (keychain, network) and always asks first (permissions.ask in
# .claude/settings.json). build/ ends with the .app and the release zip only.
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/release.sh X.Y.Z" >&2
    exit 2
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameSheet"
BUILD_DIR="$REPO_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
PROFILE="${FRAMESHEET_NOTARY_PROFILE:-cooViewer-notary}"
LOG="$HOME/Library/Logs/FrameSheet/release.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

echo "=== release $VERSION: checking the checkout ==="
if [ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]; then
    echo "ERROR: uncommitted changes to tracked files; commit them first." >&2
    exit 1
fi
COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "Commit: $COMMIT"

echo "=== build ==="
FRAMESHEET_VERSION="$VERSION" FRAMESHEET_RELEASE=1 "$REPO_DIR/build.sh"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$SHORT" != "$VERSION" ]; then
    echo "ERROR: the app reports $SHORT, not $VERSION." >&2
    exit 1
fi
# build.sh's own zip is replaced by the stapled one.
rm -f "$BUILD_DIR"/*.zip

echo "=== notarize (profile $PROFILE) ==="
SUBMIT="$BUILD_DIR/$APP_NAME-$VERSION-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT"
RESULT="$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait)"
echo "$RESULT"
rm -f "$SUBMIT"
if ! grep -q "status: Accepted" <<<"$RESULT"; then
    ID="$(sed -n 's/^ *id: //p' <<<"$RESULT" | head -1)"
    echo "ERROR: notarization was not accepted. Log: xcrun notarytool log $ID --keychain-profile $PROFILE" >&2
    exit 1
fi

echo "=== staple and zip ==="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "=== checks ==="
spctl --assess --type execute -vv "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Authority=Developer ID Application|Timestamp|Runtime Version|CodeDirectory)"
shasum -a 256 "$ZIP"
ls "$BUILD_DIR"

echo "=== release $VERSION ready ==="
echo "Commit: $COMMIT"
echo "Zip:    $ZIP"
