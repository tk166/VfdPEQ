# KNOW_HOW — VfdPEQ 开发过程中沉淀的可复用知识

> 范围：功能设计、UI 设计、音频算法、系统编程、测试与调试方法。每条尽量写成"下次遇到同类问题可直接套用"的形式。

---

## 1. macOS 音频体系（HAL 虚拟驱动路线）

### 1.1 AudioServerPlugIn（HAL 插件）关键事实
- 虚拟声卡 = `AudioServerPlugIn` bundle，装在 `/Library/Audio/Plug-Ins/HAL/`，由 `coreaudiod` 加载。BlackHole fork 是最成熟的代码基。
- **安装/卸载**：复制/删除 bundle 后必须 `killall coreaudiod`（launchd 会自动拉起）。`launchctl kickstart com.apple.audio.coreaudiod` 在 SIP 开启的机器上**必定失败**（错误 150），不要用。
- **Apple 官方建议：HAL 驱动安装后重启电脑**（BlackHole 0.6.1 changelog 明确 "force a computer reboot as recommended by Apple"）。实测反复 install/uninstall 不重启会让驱动的 IO 状态进入未定义领域——**出货流程必须包含"装完重启"或至少 killall**。
- **驱动里 `DebugMsg` 只在 `#if DEBUG` 下有定义**（syslog LOG_NOTICE）。给驱动加诊断日志需要 `-DDEBUG=1` 重编 + 重装；日志用 `log stream --predicate 'eventMessage CONTAINS "..."'` 实时查看。
- **ring buffer 语义**（BlackHole DoIOOperation）：WriteMix 直接 memcpy 覆盖（非求和，多 writer 互相覆盖）；ReadInput 在 `lastOutputSampleTime - frameSize < inputTime.mSampleTime` 时清零——这是"无写入者"判定。排查"读到全零"先看这个分支。
- ⚠️ **重大实测结论（2026-09，macOS 26.5.2）**：AudioServerPlugIn 型虚拟驱动的**输入流数据通路损坏**——应用输出进不了驱动 ring，驱动 ReadInput 不被调度；官方 BlackHole 0.7.1、device IOProc 与 AUHAL 两条客户端路径、重启、路由方式全试过均复现。**在此系统版本上不要押注这条技术路线**，虚拟设备用官方维护的驱动，产品聚焦上层。

### 1.2 CoreAudio 客户端 API 陷阱清单
- **音量属性 scope**：内建扬声器/VfdPEQ 的 `VolumeScalar` 在 **Output scope**；部分耳机孔设备只在 **Global scope**；Apple Silicon 耳机孔可能只有 `VolumeDecibels`（需读 Range 换算 0–1）。**读取/写入都要做 Output → Global → per-channel → Decibels 的回退链**。
- **静音与音量独立**：设备可能 `mute=1` 且 `vol=0`。用户拖音量条的意图是"要出声"——**写音量时同时清 mute**，并把静音状态显示出来（0% + 提示），否则"调音量没反应"的报障查不到原因。
- **默认输出写入**：`kAudioHardwarePropertyDefaultOutputDevice` 写入返回 ok **不代表路由立即生效**，且卸载驱动时 macOS 会把默认输出切走、重装后**不会切回**。依赖虚拟设备的程序必须在"设备恢复"后主动把默认输出写回。
- **设备枚举有延迟**：coreaudiod 重启/驱动重载后，设备列表要数秒才完整。启动逻辑必须重试（引擎侧枚举重试 + 客户端侧失配去抖），否则"设备存在但找不到"的假失败会出现。
- **失配判定必须去抖**：CoreAudio 的 `kAudioHardwarePropertyDevices` listener **注册时会立即回调一次**，且启动早期枚举不完整。"枚举不到配置的设备"需要持续 1.5s+ 才能判定为真失配，否则刚启动就误清配置。
- **per-app 音频路由**（macOS 13+）：每个 app 可以有独立记住的输出设备。**测试时用 `afplay` 做探针要小心**——它被路由切到别的设备后会一直记在那个设备上，后续所有 afplay 探针全部失效且现象诡异。
- `kAudioDevicePropertyDeviceIsRunning` 是"本进程视角"；`...IsRunningSomewhere` 才是全系统。

### 1.3 虚拟驱动的正确使用姿势（路线教训）
- **自研驱动的维护成本 = 每次 macOS 大版本更新都要重验**。eqMac 等成熟产品都依赖官方 BlackHole 而非自研驱动。**产品的价值在引擎/GUI/管理器，虚拟设备用官方的**是更稳的分工。
- 若必须自研：驱动源码用 git 管理、每次 macOS 更新后跑一遍**最小 IO 环回测试**（writer+reader 两个小工具，见本文 §6）。

---

## 2. 进程生命周期管理（托盘应用模式）

### 2.1 托盘（NSStatusItem）
- 左键/右键区分：`[button sendActionOn: LeftMouseUp | RightMouseUp]`，action 里读 `[NSApp currentEvent].type` 分发。
- 右键菜单用 `popUpMenuPositioningItem:atLocation:inView:`（旧的 `popUpMenu:` 已从 SDK 移除）。
- **MRC（非 ARC）下，工厂方法返回的 NSStatusItem 是 autoreleased**——赋给全局指针不 retain 的话，autorelease pool 排空后就是悬垂指针，**在 app teardown 内存复用后必崩**（症状：`-[NSExtraMIData button]: unrecognized selector`）。要么 retain，要么整体转 ARC。
- 菜单每次展开用 `NSMenuDelegate.menuNeedsUpdate` 重建（设备列表、勾选状态才能实时）。

### 2.2 子进程管理（NSTask）
- `standardInput` 给 `[NSFileHandle fileHandleWithNullDevice]`：子进程读到 EOF 走"无输入"分支，**不会卡在交互提示**。
- 日志重定向到文件（`truncateFileAtOffset:0` 后交给 NSTask），比 pipe + 异步读简单可靠。
- `terminationHandler` 里做状态回收；**注意它跑在任意线程**，回主队列 dispatch。

### 2.3 信号与优雅退出（本项目的血泪三连）
- **信号 handler 里只能做 async-signal-safe 的事**。`dispatch_async` 不安全——实测在 handler 里 dispatch_async 直接 SIGSEGV。标准模式：**self-pipe**（handler 只 `write` 一个字节），主队列挂 `dispatch_source_read` 收信号。
- **不要在 dispatch source 回调里直接 `[NSApp terminate]`**：teardown 与 MTKView 排队中的 draw block 交错执行会踩坏堆（崩溃栈落在毫不相关的绘图代码里）。正确做法：**handler 只置退出标志，帧边界（draw 入口处）检查标志 → 停子进程 → 再 terminate**。
- **teardown 期间所有异步回调必须能"哑火"**：设全局 `g_appTerminating` 标志，回调入口早退；NSTask 的 terminationHandler 在 terminate 前先摘除（`setTerminationHandler:nil`）——否则进程退出过程中引擎退出事件会触发对已释放 AppKit 对象的消息发送。
- 退出期"进程还活着"的检查要用 `ps -o stat=` 看 STAT（Z = 僵尸）：bash 未 reap 的后台子进程会让 `kill -0`/`pgrep` 误报存活。

### 2.4 单实例
- 同一应用的多个实例各自管理同一子进程会**互杀**（A 的 coreOn pkill 掉 B 的 engine，B 的 handler 又重启……）。**flock 一个锁文件，LOCK_EX|LOCK_NB 失败即退出**，五行代码解决。

### 2.5 提权（sudo）
- 驱动装卸这类低频提权：`osascript -e 'do shell script "..." with administrator privileges'` 弹系统密码框，零依赖。
- 开机自启场景需要免密：写 `/etc/sudoers.d/<name>`（`NOPASSWD:` + **精确脚本路径**），执行时先 `sudo -n`（免密尝试）失败再回退 osascript。sudoers 白名单是**精确命令路径匹配**，参数变化会导致不匹配。
- LaunchAgent（`~/Library/LaunchAgents/*.plist` + `RunAtLoad`）适合"用户登录后拉起托盘应用"；裸二进制没有 bundle id 也能用。

---

## 3. UI / 渲染

### 3.1 点阵荧光屏（LUT 配色）
- 配色 = 一张"强度→RGB"的 512 项 LUT。**灰阶主题与彩色主题的设计逻辑不同**：
  - 彩色（绿/琥珀）：靠**色相**提供区分度，低端近黑、高端饱和；
  - 灰阶（白）：没有色相，必须靠**大亮度反差**（背景 ≤4%、数据 100%），泛光/余辉要单独压暗——否则中低强度域的泛光、余辉全部变成"雾"。
- **LUT 的"元素本位对齐"**：把背景/网格/轴/文字/数据的各自强度值查表后应落在设计亮度上；**新增主题节点数变了必须同步 count**（本项目踩过：节点数写死导致高端全部钳位在 52% 灰——"怎么调都不亮"的真凶）。
- 泛光在**格域**做两级 box blur（比像素域快 16 倍），间隙透过率单独控制"点阵颗粒感 vs 辉光弥散"。
- 磷光余辉 = 逐像素一阶 IIR（`beta = 1-exp(-dt/tau)`，帧率无关）；**仪表/控件区跳过余辉**（读数要即时清晰），"悬停亮度惯量"由控件自己的 glow 变量实现（快起 τ≈60ms、慢落 τ≈280ms）。

### 3.2 ImGui（Metal 后端）
- **ID 冲突**：循环里的 popup/输入控件必须 PushID 或唯一 id；同帧同 ID 的两个可见控件会触发 "N visible items with conflicting ID" 断言/告警。
- **`ImGuiInputTextFlags_EnterReturnsTrue` 在 InputScalar 里是 IM_ASSERT 崩溃**（1.89+）。提交判断用 `IsItemDeactivatedAfterEdit`。
- **`ImGui_ImplOSX` 挂全局鼠标监听**：模态 sheet/其他窗口打开时 ImGui 仍会收到全系统的点击坐标——**热区必须用 "attachedSheet != nil" 之类的门闸冻结**，否则文件对话框里的点击会穿透触发底层控件（实测穿透触发音量条）。
- **错误码速查**：`-10877 = InvalidElement`（AUHAL 的 EnableIO 输入总线 element 是 1 不是 0）；AudioUnitRender 必须传回调收到的 timestamp 且流格式必须 **non-interleaved**；AudioServerPlugIn `-50`/`kAudioUnitErr_InvalidParameter` 多为 ASBD interleaved。
- Objective-C++ **MRC 下所有工厂方法（非 alloc/init）返回 autoreleased 对象**，跨池持有必须 retain——这是托盘段错误案的根因。

### 3.3 交互设计沉淀
- 滑条三合一交互（**单击定位 + 拖动微调 + 双击精确输入**）比单一拖动手感好得多；拖动方向统一"右/上增、左/下减"，delta 归一化用 `(dx - dy) / 控件宽度`。
- 每个控件配悬停说明（含所属上下文，如"R CH · Band 3 · gain"）成本极低、收益极高。
- 布局对齐用**共享的列边界常量**（band 行五列的分割线同时约束音量行/preamp 行的控件几何），视觉一致性自动成立。

---

## 4. 音频 DSP

- **L/R 独立 EQ**：级联状态按 `[channel][band]` 组织（不要 `[band][channel]`——两声道 band 数可不同）；系数表 per-channel，bypass 用"恒等系数"占位最简单（`BiquadCoeffs{}` 默认即直通）。
- **Preamp** = 级联前的每声道线性增益（`10^(dB/20)`），天然不反映在频响曲线里（曲线只画滤波器）。
- **频响计算**：z 域单位圆采样 `H(z) = (b0+b1z⁻¹+b2z⁻²)/(1+a1z⁻¹+a2z⁻²)`，220 点对数频率轴足够画图。
- **热加载**：配置文件 mtime 轮询（IOProc 里每 ~1s 一次）+ `shared_ptr<const Config>` 整体替换 + mutex 读写——比逐字段锁简单且无撕裂。
- **采样率对齐**：虚拟设备的 nominal rate 写入可能返回 noErr 但**值未生效**（HAL 异步/客户端清理时序），必须**设置后回读验证 + 带间隔重试**；且**改 rate 前必须停掉设备的 IOProc**，IO 运行中设置会被拒绝。

---

## 5. 配置与数据格式

- **单配置文件双端共用**（引擎 C 解析器 + GUI 解析器同步实现）时要写一份格式注释放在文件头，且两端解析器行为对齐（未知行跳过 = 向后兼容）。全局开关行（`bypass`/`preamp`/`output_name`/`hue`/`rng`）与分节行（`channel L/R`）分开处理。
- **带空格的值**（设备名）必须整行读取 + trim，不能 sscanf %s。
- **EQAPO 兼容格式**：`# L=R` / `# L/R` 注释头表达声道模式；`Channel: L/R` 分段；段内 `Preamp:` 行独立。导入时 `Low Shelf`/`High Shelf` 带空格变体要先压缩成短码（**memmove 左移剩余内容**，memcpy 会让尾部残留旧字符导致后续 sscanf 失配——实测踩过）。
- **没有注释 = 默认值**的向后兼容规则让旧配置永不失效。

---

## 6. 测试与调试方法论（正面做法）

1. **崩溃报告（.ips）解析**：`~/Library/Logs/DiagnosticReports/` 最新 .ips 是 JSON（首行 meta + body），faultingThread 的 frames 给 imageOffset——`atos -o binary -l <imageBase> <addr>` 逐帧符号化。**崩溃栈与"自以为的问题"不符时，信栈**。
2. **寄存器取证**：objc_msgSend 崩溃时看 x0（receiver）。receiver 是合法堆地址但 isa 烂 = use-after-free；直接看类名 `po (char*)object_getClassName((void*)$x0)`。
3. **lldb 活体抓捕**比事后报告多给运行时对象状态，但 batch 模式崩溃后的命令不一定执行——报告 + lldb 双管齐下。
4. **Guard Malloc**（`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib MALLOC_PROTECT_BEFORE=1`）：越界写当场崩在写入现场。注意它**只保护活分配**，free 后 freelist 元数据被踩会在**下一次 malloc** 才炸（栈在无辜代码处）。
5. **ASan 构建后要 clean**（普通 .o 混进 ASan 链接会 undefined symbols）；ASan 改变时序，race 类问题可能不复现——**ASan 干净 ≠ 无 bug**，要配合长时运行。
6. **O0 + atos**：O2 内联让 block 符号全部归到外层函数（误导），O0 栈每一帧都是真实函数名——疑难崩溃先降 O0。
7. **驱动/syslog**：`log stream --predicate 'eventMessage CONTAINS "..."'` 实时过滤；插桩字符串要先 `strings binary | grep` 验证真的编进去了（宏条件编译会静默吞掉日志代码）。
8. **僵尸进程识别**：bash 后台任务不 reap，`kill -0`/`pgrep` 对僵尸返回真——存活检查用 `ps -o stat=`（STAT 含 Z 即僵尸）。
9. **对照实验先行**：验证"X 坏了"之前先验证"已知良好的场景还通不通"（本项目最后靠用户的现场演示才纠正方向）。**自定义测试探针（直接设备 IO 写）的数据行为与真实应用（系统路由）不同，不能互相当金标准**。
10. **git worktree 隔离实验**：`git worktree add /tmp/v11test <commit>` 可以在不污染当前工作区的前提下构建运行任意历史版本做 A/B 对照。

---

## 7. 架构决策记录（ADR 摘要）

| 决策 | 选择 | 理由 |
|---|---|---|
| 托盘载体 | 单进程复用 GUI（NSStatusItem） | 复用 CoreAudio/conf/日志全套基础设施；引擎本就是独立子进程，隔离性已满足 |
| 提权 | osascript 密码框 + sudoers 白名单（自启场景） | 零依赖；SMJobBless 样板成本不成比例 |
| 配置 | 单 conf 文件双端解析（引擎+GUI） | 热加载天然同步两端；未知行跳过保证向后兼容 |
| L/R 状态机 | L=R→L/R 复制 L；L/R→L=R 保留 L | 符合"先分后合"的直觉，合并不丢数据 |
| 失配策略 | 清空设备配置回退 Off（带 1.5s 去抖） | 状态机无死锁；去抖防"枚举未就绪"误伤 |
| 退出 | 信号 → 标志 → 帧边界执行 | 避免 teardown 与渲染交错踩堆 |

---

*整理自 2026-09-29 ～ 09-30 的开发实录（Stage1 → tmp01）。*
