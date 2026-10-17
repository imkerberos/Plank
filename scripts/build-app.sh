#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="dist/Plank.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
sh scripts/build-icon.sh
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/Plank" "$APP/Contents/MacOS/Plank"
rm -rf "$APP/Contents/Resources/Plank_Plank.bundle"
cp -R "$BIN_DIR/Plank_Plank.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Plank</string>
  <key>CFBundleIdentifier</key><string>dev.plank.panel</string>
  <key>CFBundleName</key><string>Plank</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Plank uses System Events for Lock Screen, Sleep, Restart, and Shut Down, and Finder to empty Trash when you confirm.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
