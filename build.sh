#!/bin/bash
# FrameSheet v3 build: compiles the Swift package in release mode (arm64)
# with its build products outside the repository, then assembles, signs and
# zips build/FrameSheet.app. build/ holds only the .app and the zip.
set -euo pipefail

APP_NAME="FrameSheet"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# SwiftPM products and the iconset stay out of the repository.
SCRATCH_DIR="${FRAMESHEET_SCRATCH_PATH:-$HOME/Library/Caches/FrameSheet/build}"

# Version comes from the latest git tag (vX.Y.Z -> X.Y.Z) so releases
# only need a tag, never a script edit. Build number is the monotonic
# commit count. Fallbacks cover non-git contexts (e.g. a tarball).
VERSION="$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-3.0.0}"
BUILD_NUMBER="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || true)"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
BUILD_DIR="$REPO_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "=== Step 1: Cleaning previous build ==="
# Kill any running instance so the new binary runs on next launch
killall "$APP_NAME" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "=== Step 2: Compiling the Swift package ==="
SWIFT_ARGS=(-c release --arch arm64 --package-path "$REPO_DIR" --scratch-path "$SCRATCH_DIR")
swift build "${SWIFT_ARGS[@]}" --product "$APP_NAME"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "=== Step 3: Creating app icon from assets/AppIcon.png ==="
ICON_PNG="$REPO_DIR/assets/AppIcon.png"
ICONSET_DIR="$SCRATCH_DIR/icon.iconset"
if [ -f "$ICON_PNG" ]; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    for size in 16 32 128 256 512; do
        double=$((size * 2))
        sips -s format png -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        sips -s format png -z "$double" "$double" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/$APP_NAME.icns"
    rm -rf "$ICONSET_DIR"
    echo "App icon generated successfully."
else
    echo "WARNING: assets/AppIcon.png not found. Continuing without icon."
fi

echo "=== Step 3b: Copying fonts from assets/fonts ==="
# IBM Plex Sans and Mono (OFL 1.1, docs/licenses/IBM-Plex-LICENSE), registered
# through ATSApplicationFontsPath in Info.plist.
mkdir -p "$APP_DIR/Contents/Resources/Fonts"
cp "$REPO_DIR"/assets/fonts/* "$APP_DIR/Contents/Resources/Fonts/"

echo "=== Step 4: Creating Info.plist ==="
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Movie</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.kni.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 kni. All rights reserved.</string>
</dict>
</plist>
EOF

echo "=== Step 5: Code-signing Application Bundle ==="
# Sign the whole bundle so it carries a valid CodeResources seal covering
# Contents/Resources.
#
# Debug and release builds both sign with the Developer ID Application
# identity so TCC grants (tied to bundle ID + code signature) survive
# rebuilds — see docs/DECISIONS.md (13). Override with
# FRAMESHEET_SIGN_IDENTITY; when no identity is available (other machines/CI)
# fall back to ad-hoc with a warning. Notarization/stapling remains a
# release-only manual step.
SIGN_IDENTITY="${FRAMESHEET_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: $SIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "WARNING: no Developer ID Application identity found — falling back to ad-hoc signing (TCC grants will not survive rebuilds)."
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

echo "=== Step 6: Packaging Application as Zip ==="
ZIP_NAME="${APP_NAME}-v${VERSION}-macOS.zip"
(cd "$BUILD_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_NAME")
echo "Application ZIP packaged successfully at: $BUILD_DIR/$ZIP_NAME"

echo "=== Build Complete! ==="
echo "Application packaged at: $APP_DIR"
