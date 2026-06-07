#!/bin/bash
# MoviePrint SwiftUI Wrapper Build Script
set -e

APP_NAME="FrameSheet"
VERSION="0.2.1"
BUILD_NUMBER="3"
SCRATCH_DIR="/Users/kni/.gemini/antigravity/scratch/MoviePrintWrapper"
BUILD_DIR="$SCRATCH_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "=== Step 1: Cleaning previous build ==="
# Kill any running instances to ensure the new binary runs on next launch
killall "$APP_NAME" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Check if static vcsi binary is already built in build_assets
STATIC_VCSI_SRC="$SCRATCH_DIR/build_assets/vcsi"
if [ ! -f "$STATIC_VCSI_SRC" ]; then
    echo "=== Step 1.5: Building standalone vcsi binary via PyInstaller ==="
    mkdir -p "$SCRATCH_DIR/build_assets"
    
    # Create simple wrapper python script
    cat <<EOF > "$SCRATCH_DIR/build_assets/vcsi_main.py"
import sys
from vcsi.vcsi import main
if __name__ == '__main__':
    sys.exit(main())
EOF
    
    # Run PyInstaller to bundle vcsi and dependencies (Pillow, numpy, Jinja2, etc.)
    # Build to a temp folder inside build so we don't dirty scratch
    mkdir -p "$BUILD_DIR/pyinstaller_work"
    /Users/kni/miniforge3/bin/pyinstaller --onefile \
      --add-data "/Users/kni/miniforge3/lib/python3.9/site-packages/vcsi/VERSION:vcsi" \
      --workpath "$BUILD_DIR/pyinstaller_work" \
      --distpath "$SCRATCH_DIR/build_assets" \
      --name vcsi \
      "$SCRATCH_DIR/build_assets/vcsi_main.py"
      
    # Clean up temporary PyInstaller files
    rm -f "$SCRATCH_DIR/build_assets/vcsi_main.py"
    rm -f "$SCRATCH_DIR/build_assets/vcsi.spec"
    rm -rf "$BUILD_DIR/pyinstaller_work"
    echo "Standalone vcsi binary generated successfully at: $STATIC_VCSI_SRC"
fi

# Copy standalone vcsi into App Bundle Resources/bin
mkdir -p "$APP_DIR/Contents/Resources/bin"
cp "$STATIC_VCSI_SRC" "$APP_DIR/Contents/Resources/bin/vcsi"

echo "=== Step 2: Creating app icon from AppIcon.png ==="
ICON_PNG="$SCRATCH_DIR/AppIcon.png"
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
swiftc -sdk $(xcrun --show-sdk-path) -parse-as-library \
  "$SCRATCH_DIR/main.swift" \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "=== Step 4: Creating Info.plist ==="
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
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

echo "=== Step 5: Packaging Application as Zip ==="
ZIP_NAME="${APP_NAME}-v${VERSION}.zip"
rm -f "$BUILD_DIR/$ZIP_NAME"
cd "$BUILD_DIR"
zip -r -q "$ZIP_NAME" "$APP_NAME.app"
cd "$SCRATCH_DIR"
echo "Application ZIP packaged successfully at: $BUILD_DIR/$ZIP_NAME"

echo "=== Build Complete! ==="
echo "Application packaged at: $APP_DIR"
