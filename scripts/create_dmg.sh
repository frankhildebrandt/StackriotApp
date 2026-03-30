#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: bash scripts/create_dmg.sh <app-bundle> <background-png> <readme> <output-dmg>" >&2
  exit 1
fi

APP_BUNDLE="$1"
BACKGROUND_PNG="$2"
README_FILE="$3"
OUTPUT_DMG="$4"

APP_NAME="$(basename "${APP_BUNDLE%.app}")"
VOLUME_NAME="${APP_NAME}"
mkdir -p "$(dirname "$OUTPUT_DMG")"
WORK_DIR="$(cd "$(dirname "$OUTPUT_DMG")" && pwd)"
STAGING_DIR="${WORK_DIR}/${APP_NAME}-dmg-root"
TEMP_DMG="${WORK_DIR}/${APP_NAME}-temp.dmg"
MOUNT_DIR="${WORK_DIR}/${APP_NAME}-mount"
BACKGROUND_DIR="${STAGING_DIR}/.background"
BACKGROUND_NAME="$(basename "$BACKGROUND_PNG")"

for required in "$APP_BUNDLE" "$BACKGROUND_PNG" "$README_FILE"; do
  if [[ ! -e "$required" ]]; then
    echo "missing required input: $required" >&2
    exit 1
  fi
done

rm -rf "$STAGING_DIR" "$TEMP_DMG" "$MOUNT_DIR" "$OUTPUT_DMG"
mkdir -p "$BACKGROUND_DIR" "$MOUNT_DIR"

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
cp "$README_FILE" "$STAGING_DIR/"
cp "$BACKGROUND_PNG" "$BACKGROUND_DIR/"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$TEMP_DMG" >/dev/null

hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" \
  "$TEMP_DMG" >/dev/null

cleanup() {
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

osascript - "$APP_NAME" "$BACKGROUND_NAME" <<'APPLESCRIPT' || true
on run argv
  set appName to item 1 of argv
  set backgroundName to item 2 of argv

  tell application "Finder"
    tell disk appName
      open
      delay 1
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {120, 120, 1020, 660}

      set theIconViewOptions to the icon view options of container window
      set arrangement of theIconViewOptions to not arranged
      set icon size of theIconViewOptions to 128
      set text size of theIconViewOptions to 14
      try
        set background picture of theIconViewOptions to file ".background:" & backgroundName
      end try

      try
        set position of item (appName & ".app") of container window to {190, 250}
      end try
      try
        set position of item "Applications" of container window to {560, 250}
      end try
      try
        set position of item "README.md" of container window to {190, 430}
      end try

      close
      open
      update without registering applications
      delay 2
    end tell
  end tell
end run
APPLESCRIPT

chmod -Rf go-w "$MOUNT_DIR"
sync
hdiutil detach "$MOUNT_DIR" >/dev/null
trap - EXIT

hdiutil convert "$TEMP_DMG" -ov -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG" >/dev/null

rm -rf "$STAGING_DIR" "$TEMP_DMG" "$MOUNT_DIR"
