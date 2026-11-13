#!/bin/bash
# Removes Keychain Cam and the auto-importer. Your photos and videos are left alone.
LABEL="com.keychaincam.import"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/Keychain Cam"   # includes cameras.txt (camera names)
rm -rf "$HOME/Applications/Keychain Cam.app"
echo "✓ Removed Keychain Cam. Photos in Desktop › Keychain Camera were kept."
echo "  Logs are in ~/Library/Logs/Keychain Cam (delete them if you like)."
