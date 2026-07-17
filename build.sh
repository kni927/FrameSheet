#!/bin/bash
# MoviePrint SwiftUI Wrapper Build Script
set -e

APP_NAME="FrameSheet"
VERSION="2.0.0"
BUILD_NUMBER="4"
# Build from the directory this script lives in (the repo checkout)
SCRATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRATCH_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "=== Step 1: Cleaning previous build ==="
# Kill any running instances to ensure the new binary runs on next launch
killall "$APP_NAME" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "=== Step 2: Creating app icon from AppIcon.png ==="
ICON_PNG="$SCRATCH_DIR/assets/AppIcon.png"
ICONSET_DIR="$BUILD_DIR/icon.iconset"

if [ -f "$ICON_PNG" ]; then
    mkdir -p "$ICONSET_DIR"
    
    # Resize PNG for standard icon sizes
    sips -s format png -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png"
    sips -s format png -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"
    sips -s format png -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png"
    sips -s format png -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"
    sips -s format png -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png"
    sips -s format png -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png"
    sips -s format png -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png"
    sips -s format png -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png"
    sips -s format png -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png"
    sips -s format png -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png"
    
    # Compile iconset to .icns file
    iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/$APP_NAME.icns"
    rm -rf "$ICONSET_DIR"
    echo "App icon generated successfully."
else
    echo "WARNING: AppIcon.png not found. Continuing without icon."
fi

echo "=== Step 3: Compiling Swift Code ==="
# Source lives in multiple files under the repo root and Views/ (see
# docs/UI_AUDIT.md §4); collect them all rather than naming one entrypoint.
SWIFT_SOURCES=$(find "$SCRATCH_DIR" -maxdepth 3 -name "*.swift" -not -path "$BUILD_DIR/*" | sort)
swiftc -sdk $(xcrun --show-sdk-path) -parse-as-library \
  $SWIFT_SOURCES \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

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
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.gemini.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 kni. All rights reserved.</string>
</dict>
</plist>
EOF

echo "=== Step 5: Code-signing Application Bundle ==="
# Ad-hoc sign the whole bundle so it carries a valid CodeResources seal
# covering Contents/Resources. Without this, a linker-only ad-hoc signature
# on the executable causes "code has no resources but signature indicates
# they must be present" after the app is zipped/unzipped on another machine.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "=== Step 6: Packaging Application as Zip ==="
ZIP_NAME="${APP_NAME}-v${VERSION}-macOS.zip"
rm -f "$BUILD_DIR/$ZIP_NAME"
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_NAME"
cd "$SCRATCH_DIR"
echo "Application ZIP packaged successfully at: $BUILD_DIR/$ZIP_NAME"

echo "=== Build Complete! ==="
echo "Application packaged at: $APP_DIR"
