# VfdPEQ — 系统级参数均衡器（macOS, 全免费）

类 eqMac 的系统级 PEQ。路线 A：经典 Audio Server Plug-In（HAL 插件）虚拟设备 + C++ PEQ 引擎 + Dear ImGui GUI。

> 开发计划见仓库外 `doc/Plan.md`。

## 结构

```
VfdPEQ/
├── driver/          # HAL 虚拟音频驱动（fork 自 BlackHole, GPL-3.0）
│   ├── src/VfdPEQ.c
│   ├── resources/Info.plist
│   └── Makefile
├── engine/          # (TODO 阶段2) C++ PEQ 引擎：读虚拟设备 → biquad 链 → 输出到真实设备
├── gui/             # (TODO 阶段3) Dear ImGui：频谱/声量/FR 曲线 + 10 段 EQ 控制
└── scripts/         # install.sh / uninstall.sh
```

## 构建与安装驱动

```bash
cd driver && make && make verify     # 编译 + ad-hoc 签名 + 校验
cd .. && sudo ./scripts/install.sh   # 需要密码；会重启 coreaudiod
```

安装后系统设置 → 声音 → 输出 中出现 "VfdPEQ 2ch"。

## 环境要求

- macOS 12+（开发机：macOS 26.5.2, Apple Silicon）
- Command Line Tools（clang 17）即可，无需完整 Xcode
- 本地使用 ad-hoc 签名即可加载；对外分发需 Developer ID + 公证

## 许可

驱动基于 [BlackHole](https://github.com/ExistentialAudio/BlackHole)（GPL-3.0）fork，本项目遵循 GPL-3.0。
