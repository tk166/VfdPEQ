#!/bin/bash
# Install SystemPEQ HAL driver (requires sudo)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$SCRIPT_DIR/../driver/build/SystemPEQ.driver"
DEST="/Library/Audio/Plug-Ins/HAL/SystemPEQ.driver"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: $BUNDLE not found. Run 'make' in driver/ first."
    exit 1
fi

echo "Copying SystemPEQ.driver to $DEST ..."
rm -rf "$DEST"
cp -R "$BUNDLE" "$DEST"
chown -R root:wheel "$DEST"

echo "Restarting coreaudiod ..."
launchctl kickstart -k system/com.apple.audio.coreaudiod

sleep 2
echo "Done. Check 'System Settings -> Sound -> Output' for the SystemPEQ device."
