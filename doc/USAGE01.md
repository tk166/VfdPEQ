# VfdPEQ 用户手册

> **VfdPEQ** — 系统级 10 段参数均衡器 · macOS 12+ · 菜单栏应用
>
> 一句话：**装一次虚拟声卡，之后所有应用的声音都会经过一个 10 段 EQ 再送到你的扬声器/耳机，屏幕上有一块荧光点阵屏实时显示频谱、声量和频响曲线。**
>
> 仓库：https://github.com/tk166/VfdPEQ

---

## 一、安装与启动

1. 打开 `VfdPEQ-<版本>.dmg`，将 **VfdPEQ** 拖入 **Applications** 文件夹。
2. 从 启动台 / Launchpad / Applications 双击打开。
3. 首次启动会弹出系统密码框——输入密码安装音频驱动（仅此一次）。安装后菜单栏出现 VfdPEQ 图标。
4. 系统可能提示"peq_gui 想访问麦克风"——请点击**允许**（VfdPEQ 通过虚拟设备接收系统音频，不使用真实麦克风）。

> 日常使用只需记住一件事：**菜单栏的 VfdPEQ 图标在，声音就经过 EQ**。

## 二、状态栏按钮

菜单栏右侧的 VfdPEQ 图标是全部控制的入口：

- **左键单击**：打开 / 隐藏主窗口
- **右键单击**：弹出控制菜单

菜单内容：

| 菜单项 | 说明 |
|---|---|
| $\boxed{\textsf{√ [On] Core}}$ / $\boxed{\textsf{[Off] Core}}$ | 引擎开关。On = EQ 处理中；Off = 引擎停止（声音不经 EQ 直通）。点击切换 |
| **Device ▸** | 输出设备子菜单：列出全部可用输出设备，当前设备带 √。选择后引擎约 1 秒热切换 |
| **√ [Enabled] Launch at login** / **[Disabled] Launch at login** | 开机自启开关。启用需一次管理员密码 |
| **About** | 版本信息：仓库地址链接 + Debug 日志开关 |
| **Quit** | 停止引擎并退出（驱动保留，下次打开无需重新安装） |

状态栏图标三态：连接稳定 / 正在切换 / 已断开（自动切换）。

---

## 三、主界面

![UI](../assets/peq-gui.png)

所有控件都是点阵屏上的"荧光控件"。**鼠标悬停在任意控件上会出现说明气泡**（告诉你它是什么、属于哪个声道第几个 band）。

---

## 四、顶部按钮排

| 按钮 | 功能 | 操作效果 |
|---|---|---|
| $\boxed{\textsf{PWR}}$ | **EQ 总开关** | 点亮 = EQ 生效；熄灭 = 旁路（声音原样直通，连 Preamp 也跳过） |
| $\boxed{\textsf{RNG}}$ | **频响纵轴量程** | 每按一次在 $\pm 6 \to \pm 12 \to \pm 18 \to \pm 24 \to \pm 36$ dB 循环 |
| $\boxed{\textsf{INP}}$ | **导入配置** | 弹出文件选择框，读取 Equalizer APO / REW 格式的 `.apo/.txt` 预设 |
| $\boxed{\textsf{EXP}}$ | **导出配置** | 保存当前 EQ 为 EQAPO 格式，可被 REW / Equalizer APO 使用 |
| $\boxed{\textsf{HUE}}$ | **配色主题** | 循环切换 7 种荧光配色 |
| $\boxed{\textsf{FLT}}$ | **全部拉平** | 所有 band 增益归零（保留频率/Q/开关设置） |

---

## 五、音量行

- $\boxed{\textsf{IN}}$ —— **VfdPEQ 输入音量**。系统声音进入 EQ 前的总闸，**键盘音量键控制的就是它**。
- $\boxed{\textsf{OUT}}$ —— **真实输出设备音量**（扬声器/耳机/声卡）。
- $\boxed{\textsf{DEVICE>}}$ —— **切换输出设备**。左键单击弹出设备列表，选择后引擎约 1 秒内热切换；也可以右键状态栏图标 → Device 子菜单选择，效果相同。

**音量条操作**：
- **单击**任意位置：音量跳到该点
- **按住拖动**：连续微调
- **双击**：弹出精确调节条

> 若 OUT 显示 N/A：该设备不支持软件音量（部分 USB 声卡），请在设备硬件面板调节。

---

## 六、声道模式：L=R 与 L/R

$\boxed{\textsf{L=R}}$ / $\boxed{\textsf{L/R}}$ 是一个双形态切换按钮：

- **$\boxed{\textsf{L=R}}$（合并模式）**：左右声道共用同一组 EQ 参数。适合大多数场景。
  → 点击切换到 $\boxed{\textsf{L/R}}$ 独立模式，**R 声道自动复制 L 的当前配置作为起点**。
- **$\boxed{\textsf{L/R}}$（独立模式）**：左右声道各自独立。出现 $\boxed{\textsf{L}}$ $\boxed{\textsf{R}}$ 两个声道选择按钮，**点亮的那个是当前编辑目标**。
  → 点击 $\boxed{\textsf{L=R}}$ 合并回单组模式，**保留 L 声道的配置**。

**频响曲线对应关系**：
- **亮线** = 当前编辑声道的 EQ 合成曲线
- **暗线** = 另一声道的 EQ 曲线（L/R 模式下用于对比；L=R 模式下暗线与亮线重叠）

---

## 七、Preamp

$\boxed{\textsf{PRE}}$ 滑条（±12dB）控制 EQ 后的整体增益，作用于声音但**不反映在频响曲线上**。

- **单击**跳到该位置 / **按住拖动**微调 / **双击**弹窗输入精确值
- L/R 模式下左右声道各自独立

---

## 八、10 行 Band 控件（核心 EQ 区）

每行一个滤波器，五列：

| 列 | 含义 | 操作 |
|---|---|---|
| ☑ 开关 | 该 band 是否生效 | 点按切换 |
| $\boxed{\textsf{PK}}$ | 滤波器类型 | 点按循环：$\textsf{PK}$(峰值) → $\textsf{HS}$(高频架) → $\textsf{LS}$(低频架) |
| 频率滑条 | 20Hz–20kHz 对数 | 拖动 / 双击输入精确值 |
| 增益滑条 | −12 ～ +12 dB | 同上 |
| Q 滑条 | 0.1 – 10（对数） | Q 越大频带越窄 |

**双击编辑**：双击频率/增益/Q 滑条弹出输入框（内容全选），直接键入精确值，**回车确认**生效。

- 悬停任意控件，气泡标明声道与 band 序号
- 修改后约 **0.3 秒写入配置、1 秒内引擎生效**
- L/R 模式下编辑的是点亮的那一边

---

## 九、频响区读法

- **亮线**：当前编辑声道的最终频响（合成曲线）
- **暗线**：L/R 模式下另一声道的频响
- **横轴** 20Hz–20kHz 对数，**纵轴** $-\mathrm{R} \sim +\mathrm{R}$（由 $\boxed{\textsf{RNG}}$ 决定）
- 悬停图形区：贯穿竖线 + 气泡显示**该位置频率与 EQ 增减量**
- 悬停声量计：显示 VU 均值与峰值

---

## 十、导入 / 导出

**导出（EXP）**：当前 EQ 状态保存为 Equalizer APO 格式的 `.txt` 文件。

**导入（INP）**：读取 EQAPO / REW 格式的预设文件。

**文件格式**：

L=R 模式：
```
# L=R
Preamp: -1.8 dB
Filter 1: ON PK Fc 1000 Hz Gain 3.5 dB Q 1.40
```

L/R 模式（声道分段）：
```
# L/R
Channel: L
Preamp: -1.8 dB
Filter 1: ON PK Fc 1000 Hz Gain 3.5 dB Q 1.40

Channel: R
Preamp: -1.0 dB
Filter 1: ON PK Fc 1000 Hz Gain -2.0 dB Q 1.40
```

声道模式由文件头 `# L=R` 或 `# L/R` 注释决定，无注释默认 L=R。

---

## 十一、About 与 Debug 日志

状态栏右键菜单 → **About**：

- **仓库地址**：点击跳转到 https://github.com/tk166/VfdPEQ
- **Enable Debug Logging File**：勾选后调试日志写入 `~/.vfdpeq_gui.debug.log`；取消后日志丢弃。状态持久化，重启保留。

**遇到问题时**：勾选 Debug Logging → 复现问题 → 将 `~/.vfdpeq_gui.debug.log` 附在 GitHub Issue 中。

---

## 十二、配置文件

所有状态保存在 `~/.config/vfdpeq/peq.conf`（热加载）。**卸载软件不会删除此文件**——重装后配置自动恢复。

conf 文件格式（手动编辑后自动热加载）：
```
# L/R
bypass 0
preamp -1.8
preampR -1.8
output_name DX1 II
hue 0
rng 1
debug_logging 0
channel L
...
```

---

## 十三、常见问题

| 现象 | 处理 |
|---|---|
| 没声音 | ① 状态栏图标是否为连接状态；② 系统设置→声音→输出是否为 VfdPEQ 2ch；③ IN/OUT 音量是否为 0%；④ $\boxed{\textsf{PWR}}$ 是否熄灭 |
| 声音发闷/音调不对 | 输出设备采样率与系统不匹配——托盘 Device 菜单重新选择输出设备（引擎自动对齐采样率） |
| 频谱不动 | 确认系统输出指向 VfdPEQ 且正在播放 |
| OUT 显示 N/A | 该设备不支持软件音量，请在设备硬件面板调 |
| 导入预设没反应 | 检查文件是否为 EQAPO Filter 行格式；声道模式由文件头 `# L/R` 决定 |
| 右键菜单后鼠标暂时不灵 | 已内置自动恢复（0.5 秒），如持续异常请报告 |

---

## 十四、卸载

运行 DMG 中的 **Uninstall VfdPEQ.command**，或在终端执行：
```bash
sudo /Applications/VfdPEQ.app/Contents/Resources/scripts/uninstall.sh
```

> 卸载**不会删除** `~/.config/vfdpeq/` 中的用户配置——重装后自动恢复。
> 如需连配置一起清除：`rm -rf ~/.config/vfdpeq`

---

*VfdPEQ v0.2.1 · https://github.com/tk166/VfdPEQ · Issue 反馈请附 `~/.vfdpeq_gui.debug.log`*
