#!/bin/bash
# Keychain Cam auto-import.
#
# Run by launchd on every volume mount (StartOnMount), through a tiny helper app so
# macOS can ask once for permission to read removable volumes and write to the Desktop.
# Exits quietly unless the keychain camera (USB vendor 0x349c) is connected and a card
# with its PHOTO / VIDEO / AUDIO folders is mounted.
#
# Cameras get names. Every unit reports the same USB serial, so the name lives on the
# camera's card (a hidden .keychaincam-name file), with the card's volume UUID kept on
# the Mac as a backup. The first time a new camera shows up you're asked what to call it.
#
# New files are copied to ~/Desktop/Keychain Camera/<day>/<HHMMSS>_<camera>_<name> and
# get a Finder tag with the camera's name (coloured, if the name is a colour).
# .avi videos also get an .mp4 copy (H.264 + AAC) when the avi2mp4 converter sits next
# to this script. Files imported before cameras had names are renamed and tagged the
# next time their camera is plugged in.
#
# After importing you're asked whether to clear the camera. Only files whose copy on
# the Mac matches byte for byte are deleted from the card.

DEST="${KC_DEST:-$HOME/Desktop/Keychain Camera}"
VOLUMES="${KC_VOLUMES:-/Volumes}"
SUPPORT="$HOME/Library/Application Support/Keychain Cam"
NAMES="${KC_NAMES:-$SUPPORT/cameras.txt}"   # lines: <volume uuid><TAB><camera name>
MARKER=".keychaincam-name"
LOG_DIR="$HOME/Library/Logs/Keychain Cam"
LOG="${KC_LOG:-$LOG_DIR/import.log}"
LOCK="${TMPDIR:-/tmp}/keychain-cam-import.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="$SCRIPT_DIR/avi2mp4"
CAMERA_VENDOR_ID=13468   # 0x349c
# KC_TEST=1: no USB check, no notifications/Finder, dialogs answered by
# KC_TEST_NAME and KC_TEST_CLEAR (yes/no).

mkdir -p "$LOG_DIR" "$(dirname "$NAMES")"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() {
  [ -n "$KC_TEST" ] && { log "(notify) $1"; return; }
  osascript -e "display notification \"$1\" with title \"Keychain Cam\" sound name \"Glass\"" 2>/dev/null
}

# dialog <message> <button…>  → prints the button clicked ("" if left unanswered)
dialog() {
  osascript - "$@" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set msg to item 1 of argv
  set btns to rest of argv
  activate
  set r to display dialog msg with title "Keychain Cam" buttons btns default button (last item of btns) giving up after 1800
  if gave up of r then return ""
  return button returned of r
end run
APPLESCRIPT
}

# ask_name <suggestion>  → prints what was typed (the suggestion if left unanswered)
ask_name() {
  if [ -n "$KC_TEST" ]; then echo "${KC_TEST_NAME:-$1}"; return; fi
  osascript - "$1" <<'APPLESCRIPT' 2>/dev/null || echo "$1"
on run argv
  set suggestion to item 1 of argv
  activate
  set r to display dialog "A new keychain camera is plugged in." & return & return & "What should I call it? (e.g. Yellow, Grey, Clear)" default answer suggestion with title "Keychain Cam" buttons {"Save"} default button "Save" giving up after 1800
  if gave up of r then return suggestion
  return text returned of r
end run
APPLESCRIPT
}

clean_name() { printf '%s' "$1" | tr -cd '[:alnum:] _-' | sed 's/^ *//; s/ *$//' | cut -c1-30; }

# Works out (or asks for) the name of the camera whose card is mounted at $1
camera_name() {
  local vol="$1" name uuid n
  name=$(clean_name "$(head -n1 "$vol/$MARKER" 2>/dev/null)")
  uuid=$(diskutil info "$vol" 2>/dev/null | awk -F': *' '/Volume UUID/ {print $2}')
  if [ -z "$name" ] && [ -n "$uuid" ]; then
    name=$(awk -F'\t' -v u="$uuid" '$1 == u {print $2; exit}' "$NAMES" 2>/dev/null)
  fi
  if [ -z "$name" ]; then
    n=$(( $(cat "$NAMES" 2>/dev/null | grep -c .) + 1 ))
    name=$(clean_name "$(ask_name "Camera $n")")
    [ -z "$name" ] && name="Camera $n"
    log "New camera named \"$name\" (card $vol, volume UUID ${uuid:-unknown})"
  fi
  # Remember it in both places
  if [ -n "$uuid" ]; then
    { grep -v "^$uuid	" "$NAMES" 2>/dev/null; printf '%s\t%s\n' "$uuid" "$name"; } > "$NAMES.tmp" && mv "$NAMES.tmp" "$NAMES"
  fi
  if [ "$(head -n1 "$vol/$MARKER" 2>/dev/null)" != "$name" ]; then
    printf '%s\n' "$name" > "$vol/$MARKER" 2>/dev/null || log "Couldn't write the camera name onto $vol"
  fi
  echo "$name"
}

# Finder tag for a camera: its name, coloured when the name contains a colour
tag_hex() {
  local name="$1" color=0 lower tmp
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *grey*|*gray*|*silver*) color=1 ;; *green*) color=2 ;; *purple*|*violet*) color=3 ;;
    *blue*) color=4 ;; *yellow*|*gold*) color=5 ;; *red*|*pink*) color=6 ;; *orange*) color=7 ;;
  esac
  tmp=$(mktemp)
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><array><string>%s\n%s</string></array></plist>\n' "$name" "$color" > "$tmp"
  plutil -convert binary1 "$tmp" && xxd -p "$tmp" | tr -d '\n'
  rm -f "$tmp"
}
tag_file() { [ -n "$TAG" ] && [ -e "$1" ] && xattr -wx com.apple.metadata:_kMDItemUserTags "$TAG" "$1" 2>/dev/null; }

same_size() { [ "$(stat -f %z "$1" 2>/dev/null)" = "$(stat -f %z "$2" 2>/dev/null)" ]; }
plural() { [ "$1" -eq 1 ] && echo "$1 $2" || echo "$1 ${2}s"; }

# Only one run at a time (mount events can fire in bursts)
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK"' EXIT

if [ -z "$KC_TEST" ]; then
  # Give the volume a moment to finish mounting
  sleep 2
  # Is the keychain camera plugged in?
  ioreg -p IOUSB -l -w0 | grep -q "\"idVendor\" = $CAMERA_VENDOR_ID" || exit 0
fi

for vol in "$VOLUMES"/*; do
  [ -d "$vol/PHOTO" ] && [ -d "$vol/VIDEO" ] && [ -d "$vol/AUDIO" ] || continue
  log "Camera card found at $vol"
  cam=$(camera_name "$vol")
  TAG=$(tag_hex "$cam")
  copied=0 converted=0 relabelled=0 blocked=0
  card_files=() mac_files=()

  for sub in PHOTO VIDEO AUDIO; do
    if ! err=$(ls "$vol/$sub" 2>&1 >/dev/null); then
      log "Can't read $vol/$sub: $err"
      blocked=1
      continue
    fi
    for f in "$vol/$sub"/*; do
      [ -f "$f" ] || continue
      # Name files by the time the camera saved them, so card renumbering
      # (IMG00000 again after a format) never overwrites earlier imports.
      day=$(stat -f '%Sm' -t '%Y-%m-%d' "$f")
      stamp=$(stat -f '%Sm' -t '%H%M%S' "$f")
      base=$(basename "$f")
      out="$DEST/$day/${stamp}_${cam}_${base}"
      # Imported before cameras had names? Rename it to say which camera.
      old="$DEST/$day/${stamp}_${base}"
      if [ ! -e "$out" ] && [ -e "$old" ] && same_size "$old" "$f"; then
        mv "$old" "$out" && tag_file "$out" && relabelled=$((relabelled + 1))
        [ -e "${old%.*}.mp4" ] && [ ! -e "${out%.*}.mp4" ] && mv "${old%.*}.mp4" "${out%.*}.mp4" && tag_file "${out%.*}.mp4"
      fi
      if [ ! -e "$out" ]; then
        mkdir -p "$DEST/$day"
        if cp -p "$f" "$out"; then
          tag_file "$out"
          copied=$((copied + 1))
        else
          log "FAILED to copy $f"
          continue
        fi
      fi
      card_files+=("$f")
      mac_files+=("$out")
      # Convert AVI videos to MP4 (once)
      case "$out" in
        *.avi|*.AVI)
          mp4="${out%.*}.mp4"
          if [ -x "$CONVERTER" ] && [ ! -e "$mp4" ]; then
            if "$CONVERTER" "$out" "$mp4" >> "$LOG" 2>&1; then
              touch -r "$out" "$mp4"
              tag_file "$mp4"
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

  if [ "$blocked" -eq 1 ]; then
    notify "macOS blocked reading the camera card. Allow it in System Settings → Privacy & Security → Files and Folders."
    continue
  fi
  [ "$relabelled" -gt 0 ] && log "Labelled $relabelled earlier import(s) as $cam"
  if [ "$copied" -gt 0 ] || [ "$converted" -gt 0 ]; then
    log "$cam: imported $copied new file(s), converted $converted video(s)"
    msg="Bam! Imported $(plural "$copied" "new file") from $cam to Desktop › Keychain Camera."
    [ "$converted" -gt 0 ] && msg="$msg $(plural "$converted" video) converted to MP4."
    [ -z "$KC_TEST" ] && open "$DEST"
  else
    log "$cam: nothing new to import"
    msg="Nothing new on $cam."
  fi

  total=${#card_files[@]}
  [ "$total" -eq 0 ] && continue   # card already empty: nothing to ask

  # Offer to clear the camera
  msg="$msg"$'\n\n'"All $(plural "$total" file) on $cam are safely on your Mac. Clear the camera?"
  if [ -n "$KC_TEST" ]; then
    [ "$KC_TEST_CLEAR" = yes ] && answer="Clear camera" || answer="Keep on camera"
  else
    answer=$(dialog "$msg" "Keep on camera" "Clear camera")
  fi
  [ "$answer" = "Clear camera" ] || { log "$cam: kept files on the camera"; continue; }

  cleared=0 kept=0
  for i in "${!card_files[@]}"; do
    f="${card_files[$i]}" m="${mac_files[$i]}"
    if cmp -s "$f" "$m" && rm -f "$f"; then
      cleared=$((cleared + 1))
    else
      log "Kept $f on the camera: its copy on the Mac doesn't match"
      kept=$((kept + 1))
    fi
  done
  log "$cam: cleared $cleared file(s), kept $kept"
  if [ "$kept" -gt 0 ]; then
    notify "Cleared $(plural "$cleared" file) from $cam. Kept $kept that didn't match the copy on your Mac."
  elif [ -z "$KC_TEST" ] && diskutil eject "$vol" >/dev/null 2>&1; then
    notify "$cam is cleared ($(plural "$cleared" file)) and ejected. Safe to unplug."
  else
    notify "$cam is cleared ($(plural "$cleared" file))."
  fi
done
