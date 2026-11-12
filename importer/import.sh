#!/bin/bash
# Keychain Cam auto-import.
#
# Run by launchd on every volume mount (StartOnMount), through a tiny helper app so
# macOS can ask once for permission to read removable volumes and write to the Desktop.
# Exits quietly unless the keychain camera (USB vendor 0x349c) is connected and a card
# with its PHOTO / VIDEO / AUDIO folders is mounted. Never deletes anything from the card.
#
# New files are copied to ~/Desktop/Keychain Camera/<day>/<HHMMSS>_<name>.
# .avi videos also get an .mp4 copy (H.264 + AAC) that plays everywhere, when the
# avi2mp4 converter sits next to this script.

DEST="$HOME/Desktop/Keychain Camera"
LOG_DIR="$HOME/Library/Logs/Keychain Cam"
LOG="$LOG_DIR/import.log"
LOCK="${TMPDIR:-/tmp}/keychain-cam-import.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="$SCRIPT_DIR/avi2mp4"
CAMERA_VENDOR_ID=13468   # 0x349c

mkdir -p "$LOG_DIR"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Keychain Cam\" sound name \"Glass\"" 2>/dev/null; }

# Only one run at a time (mount events can fire in bursts)
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK"' EXIT

# Give the volume a moment to finish mounting
sleep 2

# Is the keychain camera plugged in?
ioreg -p IOUSB -l -w0 | grep -q "\"idVendor\" = $CAMERA_VENDOR_ID" || exit 0

copied=0
converted=0
for vol in /Volumes/*; do
  [ -d "$vol/PHOTO" ] && [ -d "$vol/VIDEO" ] && [ -d "$vol/AUDIO" ] || continue
  log "Camera card found at $vol"
  for sub in PHOTO VIDEO AUDIO; do
    if ! err=$(ls "$vol/$sub" 2>&1 >/dev/null); then
      log "Can't read $vol/$sub: $err"
      notify "macOS blocked reading the camera card. Allow it in System Settings → Privacy & Security → Files and Folders."
      continue
    fi
    for f in "$vol/$sub"/*; do
      [ -f "$f" ] || continue
      # Name files by the time the camera saved them, so card renumbering
      # (IMG00000 again after a format) never overwrites earlier imports.
      day=$(stat -f '%Sm' -t '%Y-%m-%d' "$f")
      stamp=$(stat -f '%Sm' -t '%H%M%S' "$f")
      out="$DEST/$day/${stamp}_$(basename "$f")"
      if [ ! -e "$out" ]; then
        mkdir -p "$DEST/$day"
        if cp -p "$f" "$out"; then
          copied=$((copied + 1))
        else
          log "FAILED to copy $f"
          continue
        fi
      fi
      # Convert AVI videos to MP4 (once)
      case "$out" in
        *.avi|*.AVI)
          mp4="${out%.*}.mp4"
          if [ -x "$CONVERTER" ] && [ ! -e "$mp4" ]; then
            if "$CONVERTER" "$out" "$mp4" >> "$LOG" 2>&1; then
              touch -r "$out" "$mp4"
              converted=$((converted + 1))
            else
              log "FAILED to convert $out"
              rm -f "$mp4"
            fi
          fi
          ;;
      esac
    done
  done
done

if [ "$copied" -gt 0 ] || [ "$converted" -gt 0 ]; then
  log "Imported $copied new file(s), converted $converted video(s)"
  msg="$copied new file(s) copied to Desktop › Keychain Camera"
  [ "$converted" -gt 0 ] && msg="$msg, $converted video(s) converted to MP4"
  notify "$msg"
  open "$DEST"
else
  log "Nothing new to import"
fi
