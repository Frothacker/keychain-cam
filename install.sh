#!/bin/bash
# Installs Keychain Cam for the current user:
#   • ~/Applications/Keychain Cam.app      live view, photos, video, time-lapse
#   • auto-import when the camera is plugged in as a drive (LaunchAgent)
# Run again any time to update. Undo with ./uninstall.sh.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/Keychain Cam"
HELPER="$SUPPORT/Keychain Cam Importer.app"
LABEL="com.keychaincam.import"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ARCH="$(uname -m)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Install Apple's command line tools first:"
  echo "    xcode-select --install"
  exit 1
fi

echo "› Building Keychain Cam.app"
./app/build.sh

echo "› Installing the auto-importer"
mkdir -p "$SUPPORT"
cp importer/import.sh "$SUPPORT/import.sh"
chmod +x "$SUPPORT/import.sh"
swiftc -O -target "$ARCH-apple-macos14.0" importer/avi2mp4.swift -o "$SUPPORT/avi2mp4"

# A tiny app wraps the script: macOS only shows "allow access to removable volumes /
# Desktop" prompts for apps, and silently blocks plain background scripts.
rm -rf "$HELPER"
osacompile -o "$HELPER" -e "do shell script \"/bin/bash \" & quoted form of \"$SUPPORT/import.sh\""
plutil -replace LSUIElement -bool true "$HELPER/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.keychaincam.importer "$HELPER/Contents/Info.plist"
codesign -f -s - "$HELPER" 2>/dev/null

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-g</string>
    <string>$HELPER</string>
  </array>
  <key>StartOnMount</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<'DONE'

✓ Installed.

  • Open "Keychain Cam" (in ~/Applications, or search Spotlight) and set the camera
    to PC CAMERA for live view, photos, video and time-lapse.
  • Plug the camera in as MEMORY and new photos/videos are copied to
    Desktop › Keychain Camera automatically (AVI videos get an MP4 copy).

  The first time, macOS asks for camera/microphone access (Keychain Cam) and for
  access to removable volumes and the Desktop (Keychain Cam Importer) — click Allow.
DONE
