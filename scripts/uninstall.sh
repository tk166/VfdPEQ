#!/bin/bash
# Uninstall VfdPEQ HAL driver (requires sudo)
set -e

DEST="/Library/Audio/Plug-Ins/HAL/VfdPEQ.driver"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
fi

echo "Restarting coreaudiod ..."
killall coreaudiod 2>/dev/null || true
echo "Done. VfdPEQ device removed."
