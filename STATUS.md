# VfdPEQ 状态报告

## 最终状态：✅ 已通关（重启电脑后全部功能正常）

- coreaudiod: 4.6% 稳定
- VfdPEQ 驱动: /Library/Audio/Plug-Ins/HAL/VfdPEQ.driver 已安装
- 引擎: 运行中，192k 固定采集 + SRC 转换到 DX1 II @ 48k
- LaunchAgent: ~/Library/LaunchAgents/dev.vfdpeq.gui.plist（开机自启）
- 配置: ~/.config/vfdpeq/peq.conf

## 已解决的问题 ✓

1. 192kHz 固定采样率 + Core Audio SRC（AudioConverter 拉取模式）—— 切换丝滑、声音正常、underrun=0
2. 驱动常驻架构 —— Core 开关只管引擎启停；驱动按需安装（启动时检测）；卸载走 uninstall.sh
3. NSMenu 模态跟踪吞右键 UP → 0.5s hover 自恢复（注入"全键释放 + leave/re-enter"事件对）
4. About 窗口（ImGui 模态弹窗）—— 仓库链接（Selectable + NSWorkspace openURL）+ Debug 开关（NSSwitch 持久化 conf）
5. 配置路径 ~/.config/vfdpeq/（双模式 dev/bundle 统一；App Support 旧位置自动迁移）
6. Launch at login（plist 写 /tmp → privileged script 安装到 ~/Library/LaunchAgents → 用户身份 launchctl load）
7. Quit 零密码（驱动常驻后无卸载，退出只停引擎）
8. 密码框 prompt 带中文说明（osascript prompt 前置语序修复）
9. App 形态：Accessory（Dock 隐藏）+ 窗口无三键 + 状态栏全权控制
10. 状态栏 SVG 图标三态（Swift NSImage 渲染 alpha 保留 → template 模式）
11. DMG 打包（Applications 快捷方式 + 一键卸载 .command）
12. coreOn 安装驱动后等待 coreaudiod 就绪（轮询 + 3s 稳定延迟）

## 曾关闭的 P0

### coreaudiod spin 死循环（已通过重启电脑解决）
- **现象**：VfdPEQ 驱动加载后 coreaudiod 进入 100%+ CPU spin
- **隔离实验实锤**：移走 VfdPEQ → coreaudiod 恢复 0%；装回 → 复发
- **根因层**：Apple 的 AudioServerPlugIn 框架在 macOS 26.5.2 上不稳定
  - `HALS_IOContext_Legacy_Impl::IOWorkLoopDeinit` 后 spin
  - `HALS_Object::Activate/ReleaseObject` churn
  - OverloadReporter 队列积压
  - TCC 拒绝无 NSMicrophoneUsageDescription 的 app（已修复：Info.plist 加 key）
- **上游关联**：BlackHole #904（macOS 27 同类）、#889（macOS 26 已关闭）
- **解决**：重启电脑清除 coreaudiod 深层状态；TCC 修复后不再复发
- **遗留**：如频繁装卸驱动后复发，重启电脑即可恢复；长期方案是 DriverKit 迁移

## 关键文件

| 文件 | 说明 |
|---|---|
| `driver/src/VfdPEQ.c` | 驱动（= BlackHole HEAD + 符号改名，零功能差异） |
| `engine/main.cpp` | 引擎（192k 固定 + SRC + 热加载 + 设备管理 + 确认制编辑） |
| `gui/main.mm` | GUI（托盘 + ImGui/Metal + About 弹窗 + 全部生命周期管理） |
| `common/peq_conf.hpp` | 配置解析（含 debug_logging 字段） |
| `common/dbglog.h` | 统一日志（运行时开关 + 驱动/O2 兼容） |
| `package.sh` | 一键构建+打包（--build 参数全组件重编 → .app → DMG） |
| `scripts/uninstall.command` | DMG 一键卸载（双击运行） |
| `scripts/uninstall.sh` | 手动彻底清痕 |
| `tools/svg2png.swift` | SVG→PNG 渲染工具（Swift NSImage，alpha 保留） |

## 构建与安装

```bash
./package.sh --build 0.2.1   # 全组件重编 + .app + DMG
sudo scripts/uninstall.sh    # 彻底卸载（清全部痕迹）
```
