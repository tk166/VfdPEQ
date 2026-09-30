#!/bin/bash
# Install VfdPEQ HAL driver (requires sudo)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$SCRIPT_DIR/../driver/build/VfdPEQ.driver"
DEST="/Library/Audio/Plug-Ins/HAL/VfdPEQ.driver"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: $BUNDLE not found. Run 'make' in driver/ first."
    exit 1
fi

# VfdPEQ：清理旧品牌（SystemPEQ）驱动残留（一次性迁移）
if [ -d "/Library/Audio/Plug-Ins/HAL/SystemPEQ.driver" ]; then
    rm -rf "/Library/Audio/Plug-Ins/HAL/SystemPEQ.driver"
    echo "Removed legacy SystemPEQ.driver"
fi
echo "Copying VfdPEQ.driver to $DEST ..."
rm -rf "$DEST"
cp -R "$BUNDLE" "$DEST"
chown -R root:wheel "$DEST"

echo "Restarting coreaudiod ..."
killall coreaudiod 2>/dev/null || true

sleep 2
echo "Done. Check 'System Settings -> Sound -> Output' for the VfdPEQ device."
