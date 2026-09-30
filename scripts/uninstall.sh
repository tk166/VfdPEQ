#!/bin/bash
# Uninstall VfdPEQ HAL driver (requires sudo) — removes all traces
set -e

DEST="/Library/Audio/Plug-Ins/HAL/VfdPEQ.driver"
AGENT="$HOME/Library/LaunchAgents/dev.vfdpeq.gui.plist"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# 1) 停引擎
pkill -f 'gui/build/peq_engine' 2>/dev/null || true
pkill -f 'engine/build/peq_engine' 2>/dev/null || true

# 2) 卸载并移除 LaunchAgent（开机自启）
if [ -f "$AGENT" ]; then
    /bin/launchctl unload "$AGENT" 2>/dev/null || true
    rm -f "$AGENT"
    echo "Removed $AGENT"
fi

# 3) 移除驱动 bundle
if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
fi

# 4) 移除旧品牌残留
if [ -d "/Library/Audio/Plug-Ins/HAL/SystemPEQ.driver" ]; then
    rm -rf "/Library/Audio/Plug-Ins/HAL/SystemPEQ.driver"
    echo "Removed legacy SystemPEQ.driver"
fi

# 5) 移除 sudoers 白名单（历史版本可能写过）
if [ -f /etc/sudoers.d/vfdpeq ]; then
    rm -f /etc/sudoers.d/vfdpeq
    echo "Removed /etc/sudoers.d/vfdpeq"
fi

echo "Restarting coreaudiod ..."
killall coreaudiod 2>/dev/null || true
echo "Done. VfdPEQ fully removed."
