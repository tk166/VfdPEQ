#!/bin/bash
# VfdPEQ 一键卸载：停引擎 → 卸驱动 → 清 LaunchAgent → 删 /Applications/VfdPEQ.app
echo "==== VfdPEQ 卸载 ===="
echo "将移除：音频驱动 / LaunchAgent / /Applications/VfdPEQ.app"
echo "按回车开始（需要管理员密码）..."
read -r
sudo pkill -f 'VfdPEQengine' 2>/dev/null
sudo pkill -f 'build/peq_engine' 2>/dev/null
sudo /bin/launchctl unload "$HOME/Library/LaunchAgents/dev.vfdpeq.gui.plist" 2>/dev/null
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VfdPEQ.driver
sudo rm -f "$HOME/Library/LaunchAgents/dev.vfdpeq.gui.plist"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/SystemPEQ.driver
sudo rm -f /etc/sudoers.d/vfdpeq
sudo killall coreaudiod 2>/dev/null
sleep 2
sudo rm -rf /Applications/VfdPEQ.app
echo ""
echo "==== 卸载完成 ===="
echo "窗口可关闭。"
