#!/bin/bash
# Builds ~/Applications/Keychain Cam.app from KeychainCam.swift
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Keychain Cam.app"
BUILD="$(pwd)/build"
rm -rf "$BUILD" && mkdir -p "$BUILD"

# Icon
swift make-icon.swift "$BUILD/icon-1024.png"
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

# Binary
swiftc -O -target "$(uname -m)-apple-macos14.0" KeychainCam.swift -o "$BUILD/KeychainCam"

# Bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/KeychainCam" "$APP/Contents/MacOS/"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Keychain Cam</string>
  <key>CFBundleDisplayName</key><string>Keychain Cam</string>
  <key>CFBundleIdentifier</key><string>com.keychaincam.app</string>
  <key>CFBundleExecutable</key><string>KeychainCam</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Keychain Cam shows the live picture from your keychain camera and saves photos.</string>
  <key>NSMicrophoneUsageDescription</key><string>Keychain Cam records sound from your keychain camera's microphone with videos.</string>
</dict>
</plist>
PLIST
codesign -f -s - "$APP"
echo "Built $APP"
