#!/bin/bash
# Uninstall SystemPEQ HAL driver (requires sudo)
set -e

DEST="/Library/Audio/Plug-Ins/HAL/SystemPEQ.driver"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
fi

echo "Restarting coreaudiod ..."
launchctl kickstart -k system/com.apple.audio.coreaudiod
echo "Done. SystemPEQ device removed."
