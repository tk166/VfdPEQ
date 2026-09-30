// VfdPEQ GUI — Dear ImGui (Metal) + 全点阵 VFD 界面
//
//   整个 UI 是一块点阵大屏（图形区 + 控件区同屏等宽）：
//     顶部   L/R 声量计
//     中部   PEQ FR 曲线（左侧竖排 PWR/RNG/HUE/FLT 按钮）
//     共享频率轴
//     中下部 频谱（比旧版加高 ~50%）
//     底部   2 行音量条 + 10 行 PEQ 控件（开关/类型/频率/幅值/Q）
//
//   交互：按住左滑/下滑减小、右滑/上滑增大；悬停高亮带亮度惯量；
//         双击滑条弹出数值输入框。EQ 改动 0.3s 后写 peq.conf（引擎 ~1s 热加载）。
//   Run the engine first:  cd ../engine && ./build/peq_engine
#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "imgui.h"
#include "imgui_internal.h"   // debug: popup 栈深访问（hover 失效定位）
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include <CoreAudio/CoreAudio.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "peq_state.hpp"
#include "../common/peq_conf.hpp"
#include "../common/shm_ring.hpp"
#include "vfd/vfd_dsp.h"
#include "../common/dbglog.h"   // debug
#include "vfd/vfd_render.h"

// debug: 设备切换权威期与选择回调的前置声明（refreshEngineStatus @L269 先于定义使用）
static bool g_editFocusQueued = false;   // debug: 双击弹窗打开后自动聚焦+全选
static double g_confAuthorityUntil = 0.0;
static void deviceSelect(NSString* name);

// ---------------------------------------------------------------- state
static peqconf::Conf g_conf;                 // 全部持久状态（bypass/preamp/lrMode/output/bands）
static int   g_curCh = 0;                    // L/R 模式下正在编辑的声道（0=L 1=R）
static std::string g_confPath = "peq.conf";
static bool   g_dirtySave = false;
static double g_lastSave  = 0;
static FRData g_fr;
static FRData g_frOther;                         // L/R 模式：另一声道的频响（暗线）
static bool   g_frDirty = true;
static int    g_hoverCol = -1;               // FR/频谱悬停列（-1 = 无）

// L=R 模式下编辑/绘制的都是 L（ch[0]）
static std::vector<peqconf::Band>& editBands() {
    return g_conf.ch[g_conf.lrMode ? g_curCh : 0];
}
static float& editPreamp() {
    return g_conf.preampDb[g_conf.lrMode ? g_curCh : 0];
}

static shmring::ShmFrameRing* g_shm = nullptr;
static bool shmAttachLogged = false;
static vfddsp::Analyzer  g_analyzer;
static vfddsp::MeterBank g_meters;
static vfdrender::Screen* g_screen = nullptr;   // 组合大屏：图形区 + 控件区
static int  g_appliedRate = 0;
static std::vector<uint8_t> g_rgb, g_rgba;
static std::vector<float>   g_mono, g_pull;
static constexpr int kPullFrames = 16384;

static id<MTLTexture> g_screenTex = nil;
static double g_lastFrame = 0;

struct DevCtl {
    AudioDeviceID dev = kAudioObjectUnknown;
    std::string   name;
    float         vol = 1.0f;
    bool          has = false;
    bool          muted = false;
};
static DevCtl g_inCtl, g_outCtl;
static double g_lastStatusRead = 0;
static double g_lastVolPoll    = 0;
static bool   g_volEditing     = false;

// ---- control geometry / hover glow ----
struct CtlGlow { float v = 0.f; };               // 0..1，悬停亮度惯量
static CtlGlow g_glowSide[vfdrender::Screen::kTopButtons];
static CtlGlow g_glowVol[7];   // [0]=IN [1]=OUT [2]=> [3]=mode [4]=L [5]=R [6]=preamp
static CtlGlow g_glowBand[vfdrender::Screen::kBandRows][5];  // on/type/freq/gain/q
static ImVec2  g_imgOrigin;                      // 点阵屏在窗口中的位置（点）
static const float kFrRanges[] = {6, 12, 18, 24, 36};
static int g_frRangeIdx = 3;                     // 默认 ±24dB（conf 持久化）
static int g_themeIdx = 0;                       // 磷光主题索引（conf 持久化）
static double g_deviceSwitchingUntil = 0;        // debug: 设备切换进行中的乐观 UI 窗口
static NSWindow* g_window = nil;                 // 导入/导出对话框的 sheet 挂靠窗口

// project paths, resolved relative to the executable (gui/build/peq_gui -> project root)
static std::string g_statusPath;
static void resolveProjectPaths() {
    char buf[4096];
    uint32_t sz = sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0) return;
    std::string p = buf;
    const size_t s1 = p.find_last_of('/');          // .../gui/build
    if (s1 == std::string::npos) return;
    const size_t s2 = p.rfind('/', s1 - 1);         // .../gui
    if (s2 == std::string::npos) return;
    const size_t s3 = p.rfind('/', s2 - 1);         // project root
    if (s3 == std::string::npos) return;
    const std::string root = p.substr(0, s3);
    g_confPath   = root + "/engine/peq.conf";
    g_statusPath = root + "/engine/engine.status";
}

// ---------------------------------------------------------------- CoreAudio helpers
// debug: CoreAudio 设备缓存——主线程零 CoreAudio 枚举调用（设备变化期 CoreAudio 内部锁
// 会让枚举调用秒级阻塞主线程，导致鼠标点击全部丢失）。缓存由后台队列刷新。
struct CachedDevice { AudioDeviceID id; std::string name; };
static std::vector<CachedDevice> g_devCache;
static bool g_devCacheValid = false;
static void refreshDeviceCacheAsync();

static std::string deviceName(AudioDeviceID d) {
    for (auto& c : g_devCache) if (c.id == d) return c.name;
    AudioObjectPropertyAddress pa = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    CFStringRef cfn = nullptr;
    UInt32 sz = sizeof(cfn);
    std::string out;
    if (AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &cfn) == noErr && cfn) {
        char buf[128] = {0};
        CFStringGetCString(cfn, buf, sizeof(buf), kCFStringEncodingUTF8);
        CFRelease(cfn);
        out = buf;
    }
    return out;
}

static std::vector<AudioDeviceID> outputDevices() {
    AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    std::vector<AudioDeviceID> out;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &pa, 0, nullptr, &size) != noErr)
        return out;
    std::vector<AudioDeviceID> devs(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &pa, 0, nullptr, &size, devs.data()) != noErr)
        return out;
    for (auto d : devs) {
        AudioObjectPropertyAddress sa = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                                         kAudioObjectPropertyElementMain};
        UInt32 sz = 0;
        if (AudioObjectGetPropertyDataSize(d, &sa, 0, nullptr, &sz) == noErr && sz > 0) out.push_back(d);
    }
    return out;
}

// debug: 设备查找走缓存（主线程零 CoreAudio 枚举），缓存由 refreshDeviceCacheAsync 后台刷新
static AudioDeviceID findDeviceByName(const std::string& name) {
    for (auto& d : g_devCache)
        if (d.name == name) return d.id;
    return kAudioObjectUnknown;
}

// VolumeDecibels <-> 0..1 标量换算（Apple Silicon 耳机孔等设备只有 dB 接口、无 Scalar）
static bool getVolumeDecibels(AudioDeviceID d, AudioObjectPropertyScope scope, Float32& out) {
    AudioObjectPropertyAddress pr = {kAudioDevicePropertyVolumeRangeDecibels, scope,
                                     kAudioObjectPropertyElementMain};
    Float32 rng[2] = {0, 0};
    UInt32 rsz = sizeof(rng);
    if (AudioObjectGetPropertyData(d, &pr, 0, nullptr, &rsz, rng) != noErr || rng[1] <= rng[0])
        return false;
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyVolumeDecibels, scope,
                                     kAudioObjectPropertyElementMain};
    Float32 db = 0;
    UInt32 sz = sizeof(db);
    if (AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &db) != noErr) return false;
    out = (db - rng[0]) / (rng[1] - rng[0]);
    return true;
}

static bool setVolumeDecibels(AudioDeviceID d, AudioObjectPropertyScope scope, Float32 v) {
    AudioObjectPropertyAddress pr = {kAudioDevicePropertyVolumeRangeDecibels, scope,
                                     kAudioObjectPropertyElementMain};
    Float32 rng[2] = {0, 0};
    UInt32 rsz = sizeof(rng);
    if (AudioObjectGetPropertyData(d, &pr, 0, nullptr, &rsz, rng) != noErr || rng[1] <= rng[0])
        return false;
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyVolumeDecibels, scope,
                                     kAudioObjectPropertyElementMain};
    Float32 db = rng[0] + v * (rng[1] - rng[0]);
    return AudioObjectSetPropertyData(d, &pa, 0, nullptr, sizeof(db), &db) == noErr;
}

static bool isMuted(AudioDeviceID d) {
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 m = 0; UInt32 sz = sizeof(m);
    return AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &m) == noErr && m != 0;
}

// 拖音量条的意图就是要出声：写音量的同时解除静音（实测 macOS 26 扬声器常见 mute=1 & vol=0）
static void clearMute(AudioDeviceID d) {
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 zero = 0;
    AudioObjectSetPropertyData(d, &pa, 0, nullptr, sizeof(zero), &zero);
    pa.mScope = kAudioObjectPropertyScopeGlobal;
    AudioObjectSetPropertyData(d, &pa, 0, nullptr, sizeof(zero), &zero);
}

static bool getVolumeScalar(AudioDeviceID d, Float32& out) {
    // 回退链：Output Scalar -> Global Scalar -> Output dB -> Global dB -> Output per-channel
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 sz = sizeof(Float32);
    Float32 v = 0;
    if (AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &v) == noErr) { out = v; return true; }
    pa.mScope = kAudioObjectPropertyScopeGlobal;
    if (AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &v) == noErr) { out = v; return true; }
    if (getVolumeDecibels(d, kAudioObjectPropertyScopeOutput, out))  return true;
    if (getVolumeDecibels(d, kAudioObjectPropertyScopeGlobal, out))  return true;
    pa.mScope = kAudioObjectPropertyScopeOutput;
    // fallback: average per-channel volumes (built-in devices)
    Float32 sum = 0; int cnt = 0;
    for (UInt32 el = 1; el <= 2; ++el) {
        pa.mElement = el;
        Float32 c = 0; sz = sizeof(c);
        if (AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &c) == noErr) { sum += c; ++cnt; }
    }
    if (cnt) { out = sum / cnt; return true; }
    return false;
}

static void setVolumeScalar(AudioDeviceID d, Float32 v) {
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 sz = sizeof(v);
    if (AudioObjectSetPropertyData(d, &pa, 0, nullptr, sz, &v) == noErr) return;
    pa.mScope = kAudioObjectPropertyScopeGlobal;
    if (AudioObjectSetPropertyData(d, &pa, 0, nullptr, sz, &v) == noErr) return;
    if (setVolumeDecibels(d, kAudioObjectPropertyScopeOutput, v)) return;
    if (setVolumeDecibels(d, kAudioObjectPropertyScopeGlobal, v)) return;
    pa.mScope = kAudioObjectPropertyScopeOutput;
    for (UInt32 el = 1; el <= 2; ++el) {
        pa.mElement = el;
        AudioObjectSetPropertyData(d, &pa, 0, nullptr, sz, &v);
    }
}

// read engine.status -> bind the OUT volume device
static void refreshEngineStatus() {
    FILE* f = fopen(g_statusPath.c_str(), "r");
    if (!f) return;
    char line[256];
    std::string outName;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "output_name=", 12) == 0) {
            line[strcspn(line, "\r\n")] = 0;
            outName = line + 12;
        }
    }
    fclose(f);
    // 引擎实际绑定与配置不一致（引擎失联自动降级后）→ 配置跟随引擎实际状态
    // debug: 权威期内跳过——deviceSelect 后引擎 status 落后于 conf 是 rebind 进行中的正常现象，
    // 此窗口内同步会把用户选择覆盖回旧设备（实测切换"失败"的根因）
    if (ImGui::GetTime() < g_confAuthorityUntil) {
        peq_dbg("sync deferred: within user-authority window");   // debug
    } else if (!outName.empty() && outName != g_conf.outputName && g_conf.outputName != "OFF") {
        g_conf.outputName = outName;
        g_dirtySave = true;
        fprintf(stderr, "[gui] output device config synced to engine: '%s'\n", outName.c_str());
    }
    if (!outName.empty() && outName != g_outCtl.name) {
        AudioDeviceID d = findDeviceByName(outName);
        fprintf(stderr, "[gui] engine.status: '%s' -> dev=0x%x\n", outName.c_str(), d);
        if (d != kAudioObjectUnknown) {
            g_outCtl.dev = d;
            g_outCtl.name = outName;
            g_outCtl.has = getVolumeScalar(d, g_outCtl.vol);
            fprintf(stderr, "[gui] OUT bind: has=%d vol=%.2f\n", (int)g_outCtl.has, g_outCtl.vol);
        }
    }
}

// device binding + volume polling
// debug: CoreAudio 读取全部在后台队列执行——设备变化期 CoreAudio 内部锁会让主线程的
// 枚举调用秒级阻塞，主线程阻塞窗口内的鼠标点击会全部丢失（实测"拔设备后 UI 长时间
// 不响应鼠标"）。结果通过主队列 block 应用，DevCtl 仅主线程读写，无需锁。
struct VolSnapshot { bool inHas, outHas, inMuted, outMuted; float inVol, outVol;
                     AudioDeviceID inDev, outDev; bool inRebound, outRebound; };

static void pollAudioStateAsync() {
    static std::atomic<bool> busy{false};
    bool expect = false;
    if (!busy.compare_exchange_strong(expect, true)) return;   // 上一轮未完成则跳过
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        VolSnapshot snap{};
        snap.inDev = g_inCtl.dev; snap.outDev = g_outCtl.dev;
        if (g_inCtl.dev != kAudioObjectUnknown) {
            snap.inHas = getVolumeScalar(g_inCtl.dev, snap.inVol);
            if (!snap.inHas) {                                   // 睡眠唤醒后设备 ID 变化 → 按名字重绑
                const AudioDeviceID nd = findDeviceByName(g_inCtl.name);
                if (nd != kAudioObjectUnknown) { g_inCtl.dev = nd; snap.inHas = getVolumeScalar(nd, snap.inVol); snap.inRebound = true; }
            }
            snap.inMuted = isMuted(g_inCtl.dev);
        }
        if (g_outCtl.dev != kAudioObjectUnknown) {
            snap.outHas = getVolumeScalar(g_outCtl.dev, snap.outVol);
            if (!snap.outHas) {
                const AudioDeviceID nd = findDeviceByName(g_outCtl.name);
                if (nd != kAudioObjectUnknown) { g_outCtl.dev = nd; snap.outHas = getVolumeScalar(nd, snap.outVol); snap.outRebound = true; }
            }
            snap.outMuted = isMuted(g_outCtl.dev);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            busy.store(false);
            g_inCtl.has = snap.inHas; g_inCtl.vol = snap.inVol; g_inCtl.muted = snap.inMuted;
            if (snap.inRebound) g_inCtl.dev = snap.inDev;
            g_outCtl.has = snap.outHas; g_outCtl.vol = snap.outVol; g_outCtl.muted = snap.outMuted;
            if (snap.outRebound) g_outCtl.dev = snap.outDev;
            if (snap.outMuted) g_outCtl.vol = 0.0f;
        });
    });
}

static void ensureVolumeBindings() {
    static bool inLogged = false;
    if (g_inCtl.dev == kAudioObjectUnknown) {
        g_inCtl.dev = findDeviceByName("VfdPEQ 2ch");
        g_inCtl.name = "VfdPEQ 2ch";
        if (g_inCtl.dev != kAudioObjectUnknown) {
            g_inCtl.has = getVolumeScalar(g_inCtl.dev, g_inCtl.vol);
            if (!inLogged) {
                inLogged = true;
                peq_dbg("IN bind: dev=0x%x has=%d vol=%.2f",   // debug
                        g_inCtl.dev, (int)g_inCtl.has, g_inCtl.vol);
            }
        }
    }
    // 首帧立刻读 engine.status，避免 OUT 音量条在启动头 2 秒显示 N/A
    static bool firstRun = true;
    const bool due = firstRun || ImGui::GetTime() - g_lastStatusRead > 2.0;
    if (due) {
        firstRun = false;
        g_lastStatusRead = ImGui::GetTime();
        refreshEngineStatus();
    }
    if (ImGui::GetTime() - g_lastVolPoll > 0.5 && !g_volEditing) {
        g_lastVolPoll = ImGui::GetTime();
        pollAudioStateAsync();   // debug: 后台轮询（主线程零 CoreAudio 调用）
    }
}

// ---------------------------------------------------------------- per-frame audio -> VFD feed
void drawControls();   // 点阵控件绘制（定义在本文件后部；vfdStep 每帧调用）

static void rebuildAnalyzer(int rate) {
    vfddsp::Config cfg;                      // 分析器默认参数（多分辨率、粉噪倾斜）
    g_analyzer.prepare((double)rate, cfg);
    vfddsp::MeterConfig mcfg;                // 声量计默认参数（-60dBFS、VU 0.3s）
    g_meters.prepare((double)rate, mcfg);
    g_appliedRate = rate;
    fprintf(stderr, "[gui] spectrum: %d Hz, FFT %d -> %d bands\n", rate, g_analyzer.fftSize(),
            (int)g_analyzer.numBands());
}

static void vfdStep(double dt) {
    // lazy init
    if (!g_screen) {
        // 空隙 cell:gap = 3:1（点更小、文字更小）；220 列 × 3px = 660px（≈旧 508px 的 130%）
        // 241 行：声量计 + 按钮排 + FR(61 行) + 频谱(50 行) + 控件区（2 音量行 + 10 band 行）
        g_screen = new vfdrender::Screen(220, 241, 3, 2, -78.0f, 0.0f);
        g_screen->configureDual(true);   // 组合屏：顶部声量计 + 按钮排 + FR + 频谱 + 控件区
        g_screen->setTheme((vfdrender::Theme)std::clamp(g_themeIdx, 0, vfdrender::kThemeCount - 1));
        g_screen->setFrRange(kFrRanges[std::clamp(g_frRangeIdx, 0, 4)]);
    }
    if (!g_shm) {
        g_shm = shmring::ShmFrameRing::open("/vfdpeq_audio");
        if (g_shm && g_shm->ok() && !shmAttachLogged) {
            shmAttachLogged = true;
            fprintf(stderr, "[gui] shm attached (%u Hz)\n", g_shm->sampleRate());
        }
    }
    if (g_shm && !g_shm->ok()) { g_shm->destroy(); g_shm = nullptr; }
    // 引擎重启会 unlink+重建 shm：head 停滞超过 2s 则重挂新对象
    if (g_shm && g_shm->ok()) {
        static uint64_t lastHead = 0;
        static double lastAdv = 0;
        const uint64_t h = g_shm->headSeq();
        if (h != lastHead) { lastHead = h; lastAdv = ImGui::GetTime(); }
        else if (ImGui::GetTime() - lastAdv > 2.0) {
            fprintf(stderr, "[gui] shm stale (head frozen), re-attaching\n");
            g_shm->destroy();
            g_shm = nullptr;
            lastAdv = ImGui::GetTime();
        }
    }
    if (g_shm && g_shm->sampleRate() > 0 && g_shm->sampleRate() != (uint32_t)g_appliedRate)
        rebuildAnalyzer((int)g_shm->sampleRate());
    if (g_appliedRate == 0) rebuildAnalyzer(48000); // engine offline: idle decay @48k

    g_pull.resize((size_t)kPullFrames * 2);
    g_mono.resize(kPullFrames);

    // drain ALL available frames (must not fall behind, see VfdSpecturm notes)
    int got = 0;
    for (int round = 0; round < 64; ++round) {
        int n = 0;
        if (g_shm && g_shm->ok())
            n = (int)g_shm->read(g_pull.data(), kPullFrames);
        if (n <= 0) break;
        for (int i = 0; i < n; ++i)
            g_mono[i] = 0.5f * (g_pull[(size_t)i * 2] + g_pull[(size_t)i * 2 + 1]);
        g_analyzer.push(g_mono.data(), n);
        g_meters.pushInterleaved(g_pull.data(), n, 2);
        got += n;
    }

    // no audio -> pad silence so bars/peaks decay normally
    if (got == 0) {
        const int pad = std::max(1, std::min(kPullFrames, (int)std::lround(dt * g_appliedRate)));
        std::fill_n(g_mono.data(), pad, 0.0f);
        g_analyzer.push(g_mono.data(), pad);
        std::fill_n(g_pull.data(), (size_t)pad * 2, 0.0f);
        g_meters.pushInterleaved(g_pull.data(), pad, 2);
    }

    g_analyzer.process(dt);
    g_meters.process(dt);

    g_screen->clearDynamic();
    drawControls();                                    // 控件区（框/滑块/点阵文字/辉光）
    if (g_hoverCol >= 0)                               // 悬停贯穿竖线（FR+轴+频谱，半亮度）
        for (int r = g_screen->frTopRow(); r <= g_screen->specBottomRow(); ++r)
            g_screen->dotDyn(g_hoverCol, r, 0.28f);
    if (g_analyzer.numBands() > 0) {
        g_screen->drawBars(g_analyzer.bands(), g_analyzer.numBands());
        g_screen->drawPeaks(g_analyzer.peaks(), g_analyzer.numBands());
        g_screen->drawMeters(g_meters.vuNorm(), g_meters.peakNorm(), g_meters.channels());
    }

    // FR 子区：亮线 = 当前编辑声道；L/R 模式另画暗线 = 另一声道（带磷光余辉）
    if (g_frDirty) {
        computeFR(editBands(), g_appliedRate > 0 ? g_appliedRate : 48000, g_fr);
        if (g_conf.lrMode)
            computeFR(g_conf.ch[1 - g_curCh], g_appliedRate > 0 ? g_appliedRate : 48000, g_frOther);
        g_frDirty = false;
    }
    const int pw = g_screen->plotWidth();
    auto plotLine = [&](const std::vector<float>& comp, float intensity) {
        const int N = (int)comp.size();
        if (N <= 1) return;
        for (int c = 0; c < pw; ++c) {
            const float u = (float)c / (float)(pw - 1);
            const float x = u * (float)(N - 1);
            const int i0 = (int)x;
            const int i1 = std::min(N - 1, i0 + 1);
            const float fr = x - (float)i0;
            float dbc = comp[i0] * (1.0f - fr) + comp[i1] * fr;
            if (g_conf.bypass) dbc = 0.0f;                  // 总开关旁路：0dB 平线
            g_screen->frDotDb(u, dbc, intensity);
        }
    };
    if (g_conf.lrMode) plotLine(g_frOther.comp, 0.35f);     // 暗线：另一声道
    plotLine(g_fr.comp, 1.0f);                              // 亮线：当前编辑声道

    g_screen->applyPersistence((float)std::min(dt, 0.25), 0.07f);
    g_screen->render(g_rgb);
}

static void vfdUploadTexture(id<MTLDevice> device, vfdrender::Screen* scr, id<MTLTexture>& tex,
                             std::vector<uint8_t>& rgb, std::vector<uint8_t>& rgba) {
    const int w = scr->width(), h = scr->height();
    if (!tex || tex.width != w || tex.height != h) {
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:w height:h mipmapped:NO];
        tex = [device newTextureWithDescriptor:d];
    }
    rgba.resize(rgb.size() / 3 * 4);
    for (size_t i = 0, j = 0; j < rgba.size(); i += 3, j += 4) {
        rgba[j + 0] = rgb[i + 0];
        rgba[j + 1] = rgb[i + 1];
        rgba[j + 2] = rgb[i + 2];
        rgba[j + 3] = 255;
    }
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba.data()
              bytesPerRow:w * 4];
}

// ---------------------------------------------------------------- 点阵控件（绘制 + 交互）
//
// 几何与渲染器严格对应（格坐标）。视觉全部写入点阵动态层；ImGui 只提供
// 不可见热区（InvisibleButton）来捕获鼠标：悬停辉光、拖动方向、双击输入。

struct CtlRect { int x0, y0, x1, y1; };              // 格坐标（含边框，闭区间）
                                                     //（避开 Cocoa 的 QuickDraw ::Rect）

static int cellPx() { return g_screen->cellPx(); }
static int glyphW(const std::string& s) { return (int)s.size() * 4 - 1; }   // scale=1

static CtlRect topButtonRect(int i) {
    CtlRect r; int x0, y0, x1, y1;
    g_screen->topButtonRect(i, x0, y0, x1, y1);
    r = {x0, y0, x1, y1};
    return r;
}

// band 行内各控件的水平分割（控件区占满全宽：ctlX0..ctlX1）
static void bandCellRects(int i, CtlRect& on, CtlRect& type, CtlRect& freq, CtlRect& gain, CtlRect& q) {
    int y0, y1;
    g_screen->bandRowRect(i, y0, y1);
    const int x0 = g_screen->ctlX0(), x1 = g_screen->ctlX1();
    on   = {x0,      y0, x0 + 6,    y1};
    type = {x0 + 9,  y0, x0 + 16,   y1};
    freq = {x0 + 19, y0, x0 + 83,   y1};
    gain = {x0 + 86, y0, x0 + 150,  y1};
    q    = {x0 + 153,y0, x1,        y1};
}

static const float kBoxBase  = 0.145f;   // 框常态亮度（V_GRID_MAJOR）
static const float kBoxHot   = 0.85f;    // 悬停/按住亮度
static const float kTextBase = 0.52f;    // 数值文字常态（V_LABEL）
static const float kFillOn   = 0.34f;    // 开关/按钮"开"状态的内部填充

static void drawCtlBox(const CtlRect& r, float glow, bool filled) {
    const float v = kBoxBase + glow * (kBoxHot - kBoxBase);
    g_screen->boxDyn(r.x0, r.y0, r.x1, r.y1, v);
    if (filled)
        for (int y = r.y0 + 2; y <= r.y1 - 2; ++y)
            g_screen->hLineDyn(r.x0 + 2, r.x1 - 2, y, kFillOn + glow * 0.25f);
}

// 白主题文字亮度归一：lut 在 0.80 提前饱和后，常态文字（0.52）落在饱和点之前
// 呈 ~225 灰、悬停文字 255，同屏落差刺眼——正常文字统一送入满白区，暗态保持暗
static float txtV(float v) {
    if (g_screen && g_screen->theme() == vfdrender::Theme::white)
        return v >= 0.45f ? 0.85f : v;
    return v;
}

static void drawCtlText(const CtlRect& r, const std::string& s, float v, bool centered = true) {
    v = txtV(v);
    int tx;
    if (centered) tx = r.x0 + ((r.x1 - r.x0 + 1) - glyphW(s)) / 2;
    else          tx = r.x1 + 1 - glyphW(s);                        // 右对齐（框外）
    g_screen->textDyn(tx, r.y0 + 1, s, v);
}

// 滑条：框 + 数值文字（居中）；thumb=true 时画竖条滑块（音量条保留，band 滑条只用文字）
static void drawCtlSlider(const CtlRect& r, float frac01, const std::string& label, float glow,
                          bool thumb) {
    drawCtlBox(r, glow, false);
    if (thumb) {
        frac01 = std::min(1.0f, std::max(0.0f, frac01));
        const int inner0 = r.x0 + 1, inner1 = r.x1 - 1;
        const int sx = inner0 + (int)std::lround(frac01 * (float)(inner1 - inner0 - 2));
        for (int y = r.y0 + 1; y <= r.y1 - 1; ++y) {
            g_screen->dotDyn(sx, y, 1.0f);
            g_screen->dotDyn(sx + 1, y, 0.55f);
        }
    }
    drawCtlText(r, label, kTextBase + glow * 0.3f);
}

// 热区：更新悬停辉光 + 通用拖动量（左/下滑减小，右/上滑增大），返回归一化 d∈约[-1,1]
// debug: hover 命中追踪
static const char* g_lastHoverName = "(none)";
static bool g_mainBeginOk = false;   // debug: Begin 返回值（false = 窗口被 skip，全部交互失效）
static bool ctlHotzone(const char* id, const CtlRect& r, CtlGlow& g, double dt, float& dnorm,
                       bool& active) {
    const float c = (float)cellPx();
    const ImVec2 p0(g_imgOrigin.x + r.x0 * c, g_imgOrigin.y + r.y0 * c);
    const ImVec2 sz((r.x1 - r.x0 + 1) * c, (r.y1 - r.y0 + 1) * c);
    ImGui::SetCursorScreenPos(p0);
    ImGui::InvisibleButton(id, sz);
    if (ImGui::IsItemHovered()) g_lastHoverName = id;   // debug
    if (ImGui::IsItemClicked(0)) peq_dbg("click: %s at (%.0f,%.0f)", id, ImGui::GetIO().MousePos.x, ImGui::GetIO().MousePos.y);   // debug
    active = ImGui::IsItemActive();
    const bool hovered = ImGui::IsItemHovered();
    const float target = (hovered || active) ? 1.0f : 0.0f;
    const float tau = (target > g.v) ? 0.06f : 0.28f;                // 亮起快、回落慢
    g.v += (target - g.v) * (1.0f - std::exp(-(float)dt / tau));
    dnorm = 0.0f;
    if (active) {
        const ImGuiIO& io = ImGui::GetIO();
        dnorm = (io.MouseDelta.x - io.MouseDelta.y) / std::max(1.0f, sz.x);
    }
    return hovered;
}

// 双击弹出数值输入（"double-click to type"）：打开即聚焦+全选，回车（或失焦）确认提交
// pid 必须每控件唯一（同 band 的 freq/gain/Q 共用 id 会触发 ImGui ID 冲突告警）
// 注意：InputScalar 不支持 EnterReturnsTrue（1.89+ 会 IM_ASSERT 崩溃），
// 提交用 IsItemDeactivatedAfterEdit 判定；SetKeyboardFocusHere 让弹窗打开即处于可输入状态。
// debug: 确认制——编辑期间 *v 实时变化但【不】回写参数（半成品数值不生效），
// 回车（或失焦）确认时返回 true，调用方此时才写回。避免逐字符输入污染 EQ
// （实测打 "134" 的过程中 EQ 依次跳 1→13→134 Hz）。
static bool ctlEditPopup(const char* pid, float* v, const char* fmt) {
    bool confirmed = false;
    if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) {
        ImGui::OpenPopup(pid);
        ImGui::SetNextWindowPos(ImGui::GetMousePos(), ImGuiCond_Appearing);   // 弹在鼠标附近
        g_editFocusQueued = true;                                            // 打开后自动聚焦+全选
    }
    if (ImGui::BeginPopup(pid)) {
        if (g_editFocusQueued) {
            ImGui::SetKeyboardFocusHere(0);       // 打开即键盘聚焦（可输入）
            g_editFocusQueued = false;
        }
        ImGui::InputFloat("##in", v, 0, 0, fmt, ImGuiInputTextFlags_AutoSelectAll);
        const bool enter = ImGui::IsKeyPressed(ImGuiKey_Enter) || ImGui::IsKeyPressed(ImGuiKey_KeypadEnter);
        if (enter || ImGui::IsItemDeactivatedAfterEdit()) {
            confirmed = true;                     // 回车（或失焦）= 确认，调用方写回
            ImGui::CloseCurrentPopup();
        }
        ImGui::EndPopup();
    }
    return confirmed;
}

static const char* typeName(FilterType t) {
    return t == FilterType::LowShelf ? "LS" : t == FilterType::HighShelf ? "HS" : "PK";
}

// ---------------------------------------------------------------- EQAPO / REW 配置导入导出
// 格式（Equalizer APO / REW 通用）：
//   # L=R | # L/R            首行注释区分声道模式（无注释 = L=R）
//   Preamp: -6.0 dB          L=R 模式：全局 preamp；L/R 模式：各 Channel 段内独立
//   Filter 1: ON PK Fc 1000 Hz Gain 3.5 dB Q 1.4
//   Channel: L | Channel: R  L/R 模式的分段（EQAPO Channel Selection 风格）
static void writeFilters(FILE* f, const std::vector<peqconf::Band>& bands) {
    int n = 0;
    for (const auto& b : bands) {
        ++n;
        fprintf(f, "Filter %d: %s %s Fc %.0f Hz Gain %.1f dB Q %.2f\n", n,
                b.enabled ? "ON" : "OFF", typeName(b.type), b.freq, b.gainDB, b.q);
    }
}

static bool exportEqapo(const char* path) {
    FILE* f = fopen(path, "w");
    if (!f) return false;
    fprintf(f, "# %s\n", g_conf.lrMode ? "L/R" : "L=R");
    if (!g_conf.lrMode) {
        fprintf(f, "Preamp: %.1f dB\n", g_conf.preampDb[0]);
        writeFilters(f, g_conf.ch[0]);
    } else {
        // EQAPO Channel Selection 风格：每段 = 声道声明 + 该声道 preamp + 该声道 PEQ
        fprintf(f, "Channel: L\n");
        fprintf(f, "Preamp: %.1f dB\n", g_conf.preampDb[0]);
        writeFilters(f, g_conf.ch[0]);
        fprintf(f, "\nChannel: R\n");
        fprintf(f, "Preamp: %.1f dB\n", g_conf.preampDb[1]);
        writeFilters(f, g_conf.ch[1]);
    }
    fclose(f);
    return true;
}

static bool importEqapo(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return false;
    peqconf::Conf c;
    int cur = 0;
    bool any = false;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "# L/R", 5) == 0) { c.lrMode = true;  continue; }
        if (strncmp(line, "# L=R", 5) == 0) { c.lrMode = false; continue; }
        char side[16] = "";
        if (sscanf(line, "Channel: %15s", side) == 1) {
            cur = (side[0] == 'R' || side[0] == 'r') ? 1 : 0;
            any = true;
            continue;
        }
        float pre = 0;
        if (sscanf(line, "Preamp: %f", &pre) == 1) { c.preampDb[cur] = pre; continue; }
        // 容错：REW 变体 "Low Shelf"/"High Shelf" 带空格，压成短码（注意左移剩余内容）
        for (char* s; (s = strstr(line, "Low Shelf"))  != nullptr; ) {
            memmove(s + 2, s + 9, strlen(s + 9) + 1);
            memcpy(s, "LS", 2);
        }
        for (char* s; (s = strstr(line, "High Shelf")) != nullptr; ) {
            memmove(s + 2, s + 10, strlen(s + 10) + 1);
            memcpy(s, "HS", 2);
        }
        char on[16] = "", ty[32] = "";
        double fc = 0, gain = 0, q = 1.0;
        if (sscanf(line, "Filter %*d: %15s %31s Fc %lf Hz Gain %lf dB Q %lf",
                   on, ty, &fc, &gain, &q) != 5) continue;
        peqconf::Band b;
        b.enabled = (strcmp(on, "ON") == 0);
        b.freq    = fc > 0 ? fc : 1000.0;
        b.gainDB  = gain;
        b.q       = q > 0.05 ? q : 0.05;
        if      (strcmp(ty, "LS") == 0 || strcmp(ty, "LowShelf") == 0)  b.type = FilterType::LowShelf;
        else if (strcmp(ty, "HS") == 0 || strcmp(ty, "HighShelf") == 0) b.type = FilterType::HighShelf;
        else                                                            b.type = FilterType::Peaking;
        c.ch[cur].push_back(b);
        any = true;
    }
    fclose(f);
    if (!any || c.ch[0].empty()) return false;
    if (!c.lrMode) c.ch[1] = c.ch[0];
    g_conf.lrMode = c.lrMode;
    g_conf.preampDb[0] = c.preampDb[0];
    g_conf.preampDb[1] = c.preampDb[1];
    g_conf.ch[0] = c.ch[0];
    g_conf.ch[1] = c.ch[1];
    g_curCh = 0;
    g_dirtySave = g_frDirty = true;
    return true;
}

static void exportDialog() {
    NSSavePanel* p = [NSSavePanel savePanel];
    p.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"apo"],
                              [UTType typeWithFilenameExtension:@"txt"]];
    p.nameFieldStringValue = @"peq.apo";
    p.directoryURL = [NSURL fileURLWithPath:@(g_confPath.substr(0, g_confPath.find_last_of('/')).c_str())];
    [p beginSheetModalForWindow:g_window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) {
            const bool ok = exportEqapo(p.URL.path.fileSystemRepresentation);
            fprintf(stderr, "[gui] EQAPO export -> %s : %s\n", p.URL.path.UTF8String,
                    ok ? "ok" : "FAILED");
        }
    }];
}

static void importDialog() {
    NSOpenPanel* p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"apo"],
                              [UTType typeWithFilenameExtension:@"txt"]];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    [p beginSheetModalForWindow:g_window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URLs.count > 0) {
            const bool ok = importEqapo(p.URLs.firstObject.path.fileSystemRepresentation);
            fprintf(stderr, "[gui] EQAPO import <- %s : %s (L=%zu R=%zu lr=%d)\n",
                    p.URLs.firstObject.path.UTF8String, ok ? "ok" : "FAILED",
                    g_conf.ch[0].size(), g_conf.ch[1].size(), (int)g_conf.lrMode);
        }
    }];
}

// —— 绘制（每帧，写点阵动态层；在 vfdStep 的 clearDynamic 之后调用）——
void drawControls() {
    char buf[24];

    // 顶部按钮排（声量计与 FR 之间）：PWR RNG INP EXP HUE FLT
    const CtlRect rB[6] = {topButtonRect(0), topButtonRect(1), topButtonRect(2),
                           topButtonRect(3), topButtonRect(4), topButtonRect(5)};
    drawCtlBox(rB[0], g_glowSide[0].v, !g_conf.bypass);
    drawCtlText(rB[0], "PWR", g_conf.bypass ? 0.18f : (kTextBase + g_glowSide[0].v * 0.4f));
    snprintf(buf, sizeof(buf), "%gD", kFrRanges[g_frRangeIdx]);
    drawCtlBox(rB[1], g_glowSide[1].v, false);
    drawCtlText(rB[1], buf, kTextBase + g_glowSide[1].v * 0.4f);
    drawCtlBox(rB[2], g_glowSide[2].v, false);
    drawCtlText(rB[2], "INP", kTextBase + g_glowSide[2].v * 0.4f);
    drawCtlBox(rB[3], g_glowSide[3].v, false);
    drawCtlText(rB[3], "EXP", kTextBase + g_glowSide[3].v * 0.4f);
    drawCtlBox(rB[4], g_glowSide[4].v, false);
    drawCtlText(rB[4], "HUE", kTextBase + g_glowSide[4].v * 0.4f);
    drawCtlBox(rB[5], g_glowSide[5].v, false);
    drawCtlText(rB[5], "FLT", kTextBase + g_glowSide[5].v * 0.4f);

    // 音量行（单行）：IN 滑条与频率框右缘对齐 | OUT 与 gain 左缘对齐、与 IN 等长 |
    // 余量全给 [DEVICE>]；各边界与 bandCellRects 严格对应（freq 右缘 85、gain 左缘 88）
    int vy0, vy1; g_screen->volRowRect(0, vy0, vy1);
    const int x0 = g_screen->ctlX0(), x1 = g_screen->ctlX1();
    const CtlRect slIn  = {x0 + 12,  vy0, x0 + 83,  vy1};
    const CtlRect slOut = {x0 + 99,  vy0, x0 + 170, vy1};
    const CtlRect rDev  = {x0 + 173, vy0, x1,       vy1};
    g_screen->textDyn(x0,      vy0 + 1, "IN",  txtV(kTextBase));
    g_screen->textDyn(x0 + 86, vy0 + 1, "OUT", txtV(kTextBase));
    if (g_inCtl.has) {
        snprintf(buf, sizeof(buf), "%d%%", (int)std::lround(g_inCtl.vol * 100.0f));
        drawCtlSlider(slIn, g_inCtl.vol, buf, g_glowVol[0].v, true);
    } else {
        drawCtlBox(slIn, g_glowVol[0].v, false);
        drawCtlText(slIn, "N/A", 0.20f);
    }
    if (g_outCtl.has) {
        snprintf(buf, sizeof(buf), "%d%%", (int)std::lround(g_outCtl.vol * 100.0f));
        drawCtlSlider(slOut, g_outCtl.vol, buf, g_glowVol[1].v, true);
    } else {
        drawCtlBox(slOut, g_glowVol[1].v, false);
        drawCtlText(slOut, "N/A", 0.20f);
    }
    drawCtlBox(rDev, g_glowVol[2].v, false);
    // debug: 切换进行中的乐观反馈（点击设备后 2.5s 窗口）
    if (ImGui::GetTime() < g_deviceSwitchingUntil)
        drawCtlText(rDev, "SWITCHING", kTextBase + g_glowVol[2].v * 0.4f);
    else
        drawCtlText(rDev, "DEVICE>", kTextBase + g_glowVol[2].v * 0.4f);

    // Preamp + 声道模式行：声道组合压缩到 freq 右缘（x0+83）为止，PRE 标签与 OUT 对齐
    int py0, py1; g_screen->preampRowRect(py0, py1);
    const CtlRect rMode = {x0,      py0, x0 + 83, py1};   // L=R 模式：单钮占满声道区
    const CtlRect rSw   = {x0,      py0, x0 + 27, py1};   // L/R 模式：三钮同占声道区
    const CtlRect rChL  = {x0 + 30, py0, x0 + 55, py1};
    const CtlRect rChR  = {x0 + 58, py0, x0 + 83, py1};
    const CtlRect slPre = {x0 + 99, py0, x1,      py1};   // 与 OUT 滑条同几何（拉长）
    if (g_conf.lrMode) {
        drawCtlBox(rSw, g_glowVol[3].v, false);
        drawCtlText(rSw, "L/R", kTextBase + g_glowVol[3].v * 0.4f);
        drawCtlBox(rChL, g_glowVol[4].v, g_curCh == 0);
        drawCtlText(rChL, "L", g_curCh == 0 ? kTextBase + 0.3f : 0.30f);
        drawCtlBox(rChR, g_glowVol[5].v, g_curCh == 1);
        drawCtlText(rChR, "R", g_curCh == 1 ? kTextBase + 0.3f : 0.30f);
    } else {
        drawCtlBox(rMode, g_glowVol[3].v, false);
        drawCtlText(rMode, "L=R", kTextBase + g_glowVol[3].v * 0.4f);
    }
    g_screen->textDyn(x0 + 86, py0 + 1, "PRE", txtV(kTextBase));  // 与 OUT 标签对齐
    snprintf(buf, sizeof(buf), "%+.1fDB", editPreamp());
    drawCtlSlider(slPre, (editPreamp() + 12.0f) / 24.0f, buf, g_glowVol[6].v, false);

    // band 行（前 10 个 band）：滑条只保留文字（无滑块）
    const int n = (int)std::min(editBands().size(), (size_t)vfdrender::Screen::kBandRows);
    for (int i = 0; i < n; ++i) {
        const auto& b = editBands()[i];
        CtlRect rOn, rType, rFreq, rGain, rQ;
        bandCellRects(i, rOn, rType, rFreq, rGain, rQ);
        drawCtlBox(rOn, g_glowBand[i][0].v, b.enabled);
        drawCtlBox(rType, g_glowBand[i][1].v, false);
        drawCtlText(rType, typeName(b.type), b.enabled ? kTextBase : 0.22f);
        snprintf(buf, sizeof(buf), "%.0fHZ", b.freq);
        drawCtlSlider(rFreq, 0, buf, g_glowBand[i][2].v, false);
        snprintf(buf, sizeof(buf), "%+.1fDB", b.gainDB);
        drawCtlSlider(rGain, 0, buf, g_glowBand[i][3].v, false);
        snprintf(buf, sizeof(buf), "%.2f", b.q);
        drawCtlSlider(rQ, 0, buf, g_glowBand[i][4].v, false);
    }
}

// —— 交互（每帧，ImGui 热区；在 drawFrame 的 Image 之后调用）——
static void drawControlInteractions(double dt) {
    const CtlRect rB[6] = {topButtonRect(0), topButtonRect(1), topButtonRect(2),
                           topButtonRect(3), topButtonRect(4), topButtonRect(5)};

    // PWR：EQ 总开关
    {
        float d; bool act;
        ctlHotzone("pwr", rB[0], g_glowSide[0], dt, d, act);
        // debug: 命中测试探针（2s 限频，鼠标在窗口内才打）——hovered=0 而鼠标在热区内 = 坐标系错位
        static double lastProbe = 0;
        const double nowT = ImGui::GetTime();
        const ImGuiIO& mio = ImGui::GetIO();
        const bool mouseInWindow = mio.MousePos.x > -10000;   // FLT_MAX = 鼠标不在窗口
        if (nowT - lastProbe > 2.0 && mouseInWindow) {
            lastProbe = nowT;
            const float c = (float)cellPx();
            const ImVec2 hz0(g_imgOrigin.x + rB[0].x0 * c, g_imgOrigin.y + rB[0].y0 * c);
            const ImVec2 hz1(hz0.x + (rB[0].x1 - rB[0].x0 + 1) * c, hz0.y + (rB[0].y1 - rB[0].y0 + 1) * c);
            peq_dbg("hit-test: mouse=(%.0f,%.0f) hotzone=(%.0f,%.0f)-(%.0f,%.0f) hovered=%d origin=(%.0f,%.0f) display=%.0fx%.0f",   // debug
                    mio.MousePos.x, mio.MousePos.y, hz0.x, hz0.y, hz1.x, hz1.y,
                    (int)ImGui::IsItemHovered(), g_imgOrigin.x, g_imgOrigin.y,
                    mio.DisplaySize.x, mio.DisplaySize.y);
        }
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("PWR - EQ master bypass (audio passes through untouched)");
        if (ImGui::IsItemClicked(0)) {
            g_conf.bypass = !g_conf.bypass; g_dirtySave = g_frDirty = true;
            peq_dbg("ui: PWR clicked -> bypass=%d", (int)g_conf.bypass);   // debug
        }
    }
    // RNG：FR 纵轴 ±6/12/18/24/36 循环
    {
        float d; bool act;
        ctlHotzone("rng", rB[1], g_glowSide[1], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("RNG - FR y-axis range, cycles +/-6/12/18/24/36 dB");
        if (ImGui::IsItemClicked(0)) {
            g_frRangeIdx = (g_frRangeIdx + 1) % 5;
            g_conf.rngIdx = g_frRangeIdx;
            g_dirtySave = true;
            g_screen->setFrRange(kFrRanges[g_frRangeIdx]);
            peq_dbg("ui: RNG clicked -> range +-%g dB", kFrRanges[g_frRangeIdx]);   // debug
        }
    }
    // INP：导入 EQAPO/REW 配置
    {
        float d; bool act;
        ctlHotzone("inp", rB[2], g_glowSide[2], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("INP - import EQAPO/REW config file");
        if (ImGui::IsItemClicked(0)) importDialog();
    }
    // EXP：导出 EQAPO/REW 配置
    {
        float d; bool act;
        ctlHotzone("exp", rB[3], g_glowSide[3], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("EXP - export EQAPO/REW config file");
        if (ImGui::IsItemClicked(0)) exportDialog();
    }
    // HUE：配色循环
    {
        float d; bool act;
        ctlHotzone("hue", rB[4], g_glowSide[4], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("HUE - cycle phosphor color theme");
        if (ImGui::IsItemClicked(0)) {
            g_screen->nextTheme();
            g_conf.hueIdx = (int)g_screen->theme();
            g_dirtySave = true;
        }
    }
    // FLT：全部拉平
    {
        float d; bool act;
        ctlHotzone("flt", rB[5], g_glowSide[5], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("FLT - flatten all band gains to 0 dB");
        if (ImGui::IsItemClicked(0)) {
            for (auto& b : editBands()) b.gainDB = 0;
            g_dirtySave = g_frDirty = true;
        }
    }

    // 音量行（单行）+ [DEVICE>] 设备菜单 + Preamp/声道行
    int vy0, vy1; g_screen->volRowRect(0, vy0, vy1);
    int py0, py1; g_screen->preampRowRect(py0, py1);
    const int x0 = g_screen->ctlX0(), x1 = g_screen->ctlX1();
    const CtlRect slIn  = {x0 + 12,  vy0, x0 + 83,  vy1};
    const CtlRect slOut = {x0 + 99,  vy0, x0 + 170, vy1};
    const CtlRect rDev  = {x0 + 173, vy0, x1,       vy1};
    const CtlRect rMode = {x0,       py0, x0 + 83,  py1};
    const CtlRect rSw   = {x0,       py0, x0 + 27,  py1};
    const CtlRect rChL  = {x0 + 30,  py0, x0 + 55,  py1};
    const CtlRect rChR  = {x0 + 58,  py0, x0 + 83,  py1};
    const CtlRect slPre = {x0 + 99,  py0, x1,       py1};
    const char* chName = g_conf.lrMode ? (g_curCh == 0 ? "L" : "R") : "L=R";
    // 点击定位：单击滑条任意位置直接把音量设到该点（拖动从该点继续微调）
    auto clickSetVol = [](const CtlRect& r, DevCtl& ctl) {
        const float c = (float)cellPx();
        const float left = g_imgOrigin.x + r.x0 * c;
        const float wpx = std::max(1.0f, (r.x1 - r.x0 + 1) * c);
        float u = (ImGui::GetIO().MousePos.x - left) / wpx;
        u = std::min(1.0f, std::max(0.0f, u));
        ctl.vol = u;
        clearMute(ctl.dev);
        setVolumeScalar(ctl.dev, ctl.vol);
    };
    if (g_inCtl.has) {
        float d; bool act;
        ctlHotzone("volin", slIn, g_glowVol[0], dt, d, act);
        g_volEditing = act;
        if (ImGui::IsItemClicked(0)) clickSetVol(slIn, g_inCtl);
        if (act && d != 0) {
            g_inCtl.vol = std::min(1.0f, std::max(0.0f, g_inCtl.vol + d));
            clearMute(g_inCtl.dev); setVolumeScalar(g_inCtl.dev, g_inCtl.vol);
            peq_dbg("ui: IN volume drag -> %.0f%%", g_inCtl.vol * 100);   // debug
        }
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("VfdPEQ input volume (click to set, drag to fine-tune)");
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) ImGui::OpenPopup("edin");
        if (ImGui::BeginPopup("edin")) {
            float pct = g_inCtl.vol * 100.0f;
            if (ImGui::SliderFloat("##v", &pct, 0.f, 100.f, "%.0f %%")) {
                g_inCtl.vol = pct / 100.0f;
                clearMute(g_inCtl.dev); setVolumeScalar(g_inCtl.dev, g_inCtl.vol);
            }
            ImGui::EndPopup();
        }
    }
    if (g_outCtl.has) {
        float d; bool act;
        ctlHotzone("volout", slOut, g_glowVol[1], dt, d, act);
        g_volEditing = act || g_volEditing;
        if (ImGui::IsItemClicked(0)) clickSetVol(slOut, g_outCtl);
        if (act && d != 0) {
            g_outCtl.vol = std::min(1.0f, std::max(0.0f, g_outCtl.vol + d));
            clearMute(g_outCtl.dev); setVolumeScalar(g_outCtl.dev, g_outCtl.vol);
            peq_dbg("ui: OUT volume drag -> %.0f%%", g_outCtl.vol * 100);   // debug
        }
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Output device volume (%s)%s", g_outCtl.name.c_str(),
                              g_outCtl.muted ? " - MUTED (clicking unmutes)" : "");
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) ImGui::OpenPopup("edout");
        if (ImGui::BeginPopup("edout")) {
            float pct = g_outCtl.vol * 100.0f;
            if (ImGui::SliderFloat("##v", &pct, 0.f, 100.f, "%.0f %%")) {
                g_outCtl.vol = pct / 100.0f;
                clearMute(g_outCtl.dev); setVolumeScalar(g_outCtl.dev, g_outCtl.vol);
            }
            ImGui::EndPopup();
        }
    }
    // [>]：弹出可用输出设备菜单；选择后写 conf，引擎 ~1s 热切换
    {
        static std::vector<std::pair<AudioDeviceID, std::string>> devList;
        static double devListAt = 0;
        float d; bool act;
        ctlHotzone("devpick", rDev, g_glowVol[2], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("Pick output device (engine hot-switches)");
        if (ImGui::IsItemClicked(0)) {
            if (ImGui::GetTime() - devListAt > 2.0) {
                devList.clear();
                for (auto dev : outputDevices()) {
                    const std::string n = deviceName(dev);
                    if (n.find("VfdPEQ") != std::string::npos) continue;  // 引擎输入通道，选它会死循环
                    devList.emplace_back(dev, n);
                }
                devListAt = ImGui::GetTime();
            }
            ImGui::OpenPopup("devmenu");
            peq_dbg("ui: DEVICE> menu opened (%zu devices)", devList.size());   // debug
        }
        if (ImGui::BeginPopup("devmenu")) {
            // debug: BeginPopup 成功即记录一次（打开状态可见）
            static bool devMenuLogged = false;
            if (!devMenuLogged) { devMenuLogged = true; peq_dbg("ui: devmenu popup ACTIVE");   // debug
            }
            for (auto& kv : devList) {
                if (ImGui::MenuItem(kv.second.c_str())) {
                    deviceSelect([NSString stringWithUTF8String:kv.second.c_str()]);   // debug: 统一路径（SWITCHING/权威期/Core 拉起全套）
                }
            }
            ImGui::EndPopup();
        }
    }
    // 模式按钮：L=R <-> L/R（进 L/R 时 R 复制 L；回 L=R 时保留 L）
    {
        float d; bool act;
        ctlHotzone(g_conf.lrMode ? "chsw" : "chmode",
                   g_conf.lrMode ? rSw : rMode, g_glowVol[3], dt, d, act);
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip(g_conf.lrMode ? "Click: merge to L=R (keep L)"
                                            : "Click: split to L/R (copy L to R)");
        if (ImGui::IsItemClicked(0)) {
            if (!g_conf.lrMode) {          // -> L/R
                g_conf.lrMode = true;
                g_conf.ch[1] = g_conf.ch[0];
                g_conf.preampDb[1] = g_conf.preampDb[0];
            } else {                       // -> L=R（保留 L）
                g_conf.lrMode = false;
                g_curCh = 0;
                g_conf.ch[1] = g_conf.ch[0];
                g_conf.preampDb[1] = g_conf.preampDb[0];
            }
            g_dirtySave = g_frDirty = true;
            peq_dbg("ui: channel mode -> %s", g_conf.lrMode ? "L/R" : "L=R");   // debug
        }
    }
    if (g_conf.lrMode) {
        float d; bool act;
        ctlHotzone("chL", rChL, g_glowVol[4], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("Edit channel L");
        if (ImGui::IsItemClicked(0)) { g_curCh = 0; g_frDirty = true; }
        ctlHotzone("chR", rChR, g_glowVol[5], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("Edit channel R");
        if (ImGui::IsItemClicked(0)) { g_curCh = 1; g_frDirty = true; }
    }
    // Preamp 滑条（±12dB，L/R 模式下独立）：
    {
        float d; bool act;
        ctlHotzone("preamp", slPre, g_glowVol[6], dt, d, act);
        if (act && d != 0) {
            editPreamp() = std::min(12.0f, std::max(-12.0f, editPreamp() + d * 24.0f));
            g_dirtySave = true;
            peq_dbg("ui: %s preamp drag -> %+.2f dB", chName, editPreamp());   // debug
        }
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Preamp %s (dB) - affects audio, not the FR plot", chName);
        float pv = editPreamp();
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) ImGui::OpenPopup("edpre");
        if (ImGui::BeginPopup("edpre")) {
            ImGui::InputFloat("##pre", &pv, 0, 0, "%.2f");
            if (ImGui::IsItemDeactivatedAfterEdit()) {
                editPreamp() = std::min(12.0f, std::max(-12.0f, pv));
                g_dirtySave = true;
            }
            ImGui::EndPopup();
        }
    }

    // band 行：开关 / 类型 / 频率 / 幅值 / Q（tooltip 注明声道与 band 序号）
    const char* chTag = g_conf.lrMode ? (g_curCh == 0 ? "L" : "R") : "L=R";
    const int n = (int)std::min(editBands().size(), (size_t)vfdrender::Screen::kBandRows);
    for (int i = 0; i < n; ++i) {
        auto& b = editBands()[i];
        CtlRect rOn, rType, rFreq, rGain, rQ;
        bandCellRects(i, rOn, rType, rFreq, rGain, rQ);
        char tt[96];
        ImGui::PushID(i);
        {
            float d; bool act;
            ctlHotzone("on", rOn, g_glowBand[i][0], dt, d, act);
            snprintf(tt, sizeof(tt), "%s CH - Band %d - enable/disable", chTag, i + 1);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tt);
            if (ImGui::IsItemClicked(0)) {
                b.enabled = !b.enabled; g_dirtySave = g_frDirty = true;
                peq_dbg("ui: %s CH band %d enable -> %d", chTag, i + 1, (int)b.enabled);   // debug
            }
        }
        {
            float d; bool act;
            ctlHotzone("type", rType, g_glowBand[i][1], dt, d, act);
            snprintf(tt, sizeof(tt), "%s CH - Band %d - type LS/PK/HS", chTag, i + 1);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tt);
            if (ImGui::IsItemClicked(0)) {
                b.type = b.type == FilterType::LowShelf ? FilterType::Peaking
                       : b.type == FilterType::Peaking  ? FilterType::HighShelf
                                                        : FilterType::LowShelf;
                g_dirtySave = g_frDirty = true;
                peq_dbg("ui: %s CH band %d type -> %s", chTag, i + 1, typeName(b.type));   // debug
            }
        }
        {
            float d; bool act;
            ctlHotzone("freq", rFreq, g_glowBand[i][2], dt, d, act);
            snprintf(tt, sizeof(tt), "%s CH - Band %d - frequency (Hz), drag or double-click", chTag, i + 1);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tt);
            if (act && d != 0) {
                double u = std::log10(std::max(b.freq, 20.0) / 20.0) / 3.0 + d;
                u = std::min(1.0, std::max(0.0, (double)u));
                b.freq = 20.0 * std::pow(10.0, 3.0 * u);
                g_dirtySave = g_frDirty = true;
                peq_dbg("ui: %s CH band %d freq drag -> %.1f Hz", chTag, i + 1, b.freq);   // debug
            }
            float f = (float)b.freq;
            if (ctlEditPopup("editf", &f, "%.1f")) {   // debug: 确认制——回车才写回
                if (f > 0 && (double)f != b.freq) {
                    b.freq = f; g_dirtySave = g_frDirty = true;
                    peq_dbg("ui: %s CH band %d freq confirmed -> %.1f Hz", chTag, i + 1, b.freq);   // debug
                }
            }
        }
        {
            float d; bool act;
            ctlHotzone("gain", rGain, g_glowBand[i][3], dt, d, act);
            snprintf(tt, sizeof(tt), "%s CH - Band %d - gain (dB)", chTag, i + 1);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tt);
            if (act && d != 0) {
                b.gainDB = std::min(12.0, std::max(-12.0, b.gainDB + (double)d * 24.0));
                g_dirtySave = g_frDirty = true;
                peq_dbg("ui: %s CH band %d gain drag -> %+.2f dB", chTag, i + 1, b.gainDB);   // debug
            }
            float g = (float)b.gainDB;
            if (ctlEditPopup("editg", &g, "%.2f")) {   // debug: 确认制
                if ((double)g != b.gainDB) {
                    b.gainDB = g; g_dirtySave = g_frDirty = true;
                    peq_dbg("ui: %s CH band %d gain confirmed -> %+.2f dB", chTag, i + 1, b.gainDB);   // debug
                }
            }
        }
        {
            float d; bool act;
            ctlHotzone("q", rQ, g_glowBand[i][4], dt, d, act);
            snprintf(tt, sizeof(tt), "%s CH - Band %d - Q factor", chTag, i + 1);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tt);
            if (act && d != 0) {
                double u = std::log10(std::max(b.q, 0.1) / 0.1) / 2.0 + d;
                u = std::min(1.0, std::max(0.0, (double)u));
                b.q = 0.1 * std::pow(10.0, 2.0 * u);
                g_dirtySave = g_frDirty = true;
                peq_dbg("ui: %s CH band %d Q drag -> %.3f", chTag, i + 1, b.q);   // debug
            }
            float q = (float)b.q;
            ctlEditPopup("editq", &q, "%.3f");
            if (q > 0 && (double)q != b.q) { b.q = q; g_dirtySave = g_frDirty = true; }
        }
        ImGui::PopID();
    }
}

// ================================================================ tray
// 状态栏图标 + driver/engine 生命周期管理（单进程方案）：
//   左键   显示/隐藏主窗口
//   右键   Core 总开关（装/卸 driver + 起/停 engine）· Device（off + 系统设备）· 开机启动 · Quit
//   RAII   engine 进程存在即杀掉、由托盘持有的 NSTask 重新启动；退出时统一收尸
//          设备失配（output_name 指向的设备消失）→ 清空设备配置回退 off
static NSStatusItem* g_statusItem = nil;
static NSTask*       g_engineTask = nil;
static bool          g_coreBusy = false;
static bool          g_appTerminating = false;
static volatile bool g_quitRequested = false;   // 信号置位，帧边界执行退出
static bool g_devicesChangedFlag = false;       // 设备变化置位，主线程节流处理
// debug: g_confAuthorityUntil 见文件头声明——权威期内引擎 status 落后于 conf 是
// rebind 进行中的正常现象，禁止 status→conf 同步（否则覆盖用户选择，实测切换"失败"根因）
static double g_lastDeviceCheck = 0;
// debug: CoreAudio 设备缓存——主线程零 CoreAudio 枚举调用（设备变化期 CoreAudio 内部锁
// 会让枚举调用秒级阻塞主线程，导致鼠标点击全部丢失）。缓存由后台队列刷新。
static void refreshDeviceCacheAsync() {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        std::vector<CachedDevice> list;
        AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        UInt32 sz = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &pa, 0, NULL, &sz) != noErr) return;
        std::vector<AudioDeviceID> devs(sz / sizeof(AudioDeviceID));
        sz = devs.size() * sizeof(AudioDeviceID);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &pa, 0, NULL, &sz, devs.data()) != noErr) return;
        for (size_t i = 0; i < devs.size(); ++i) {
            AudioObjectPropertyAddress pn = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain};
            CFStringRef nm = NULL; UInt32 nsz = sizeof(nm);
            if (AudioObjectGetPropertyData(devs[i], &pn, 0, NULL, &nsz, &nm) == noErr && nm) {
                char buf[128] = {0};
                CFStringGetCString(nm, buf, sizeof(buf), kCFStringEncodingUTF8);
                CFRelease(nm);
                list.push_back({devs[i], buf});
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            g_devCache = std::move(list);
            g_devCacheValid = true;
        });
    });
}
// 缓存版查找：主线程安全（零 CoreAudio 调用）
static AudioDeviceID findDeviceByNameCached(const std::string& name) {
    for (auto& d : g_devCache) if (d.name == name) return d.id;
    return kAudioObjectUnknown;
}
static volatile int g_enginePid = 0;            // debug: 引擎 pid（信号 handler 应急停止用，kill 是 signal-safe 的）   // 终止中的回调一律早退（NSStatusItem 已被 teardown）

static void ensureSystemOutputIsPEQ();   // 前置声明（terminationHandler 里调用）
static void deviceSelect(NSString* name);   // debug: 前置声明（DEVICE popup 选择回调）
static void startDrvLogStream();          // debug
static void stopDrvLogStream();           // debug

static NSString* projRoot() {
    const size_t a = g_confPath.find_last_of('/');        // .../engine
    std::string eng = (a == std::string::npos) ? g_confPath : g_confPath.substr(0, a);
    const size_t b = eng.find_last_of('/');
    return [NSString stringWithUTF8String:(b == std::string::npos ? "." : eng.substr(0, b).c_str())];
}

static bool driverInstalled() {
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/Audio/Plug-Ins/HAL/VfdPEQ.driver"];
}

// debug: 引擎存活只查托盘管理的 NSTask——system("pgrep ...") 的 fork+exec+wait
// 在主线程被频繁调用（trayUpdateIcon/menuNeedsUpdate/deviceSelect），是 UI 卡死的根源。
// RAII 语义下托盘是唯一管理者：外部 engine 会被 pkill 后由 NSTask 重启，无需检测。
static bool engineAlive() {
    return g_engineTask && [g_engineTask isRunning];
}

// debug: 状态栏图标三态（SVG→PNG，template 模式自动适配菜单栏明暗）
// disconnected=停 / connected-stable=工作中 / performing=切换中（对应原 unicode 🇻🅅🆅）
static NSImage* trayStatusImage(const char* state) {
    NSString* rel = [NSString stringWithFormat:@"assets/status-png/vfdpeq-status-%s.png", state];
    NSString* path = [projRoot() stringByAppendingPathComponent:rel];
    NSImage* img = [[NSImage alloc] initWithContentsOfFile:path];
    if (!img) { peq_dbg("status icon missing: %s", state); return nil; }
    img.size = NSMakeSize(18, 18);   // 菜单栏显示尺寸（44px @2x 数据自动高清）
    [img setTemplate:YES];              // AppKit 自动按菜单栏明暗反色
    return [img autorelease];
}
static NSImage* trayStatusImageCached(const char* state) {
    static NSDictionary* cache = nil;
    if (!cache) {
        // ⚠️ MRC：@{} 字面量返回 autoreleased 对象，赋给 static 指针不 retain——
        // pool drain 后 cache 悬垂，状态切换时访问即 doesNotRecognizeSelector 崩溃
        // （BAD_CASES A8 的复发变体：这次是新增的 status icon cache）。永久缓存显式 retain。
        NSImage* disconnected     = trayStatusImage("disconnected");
        NSImage* connectedStable  = trayStatusImage("connected-stable");
        NSImage* performing       = trayStatusImage("performing");
        NSDictionary* built = @{ @"disconnected": disconnected ?: [NSNull null],
                                 @"connected-stable": connectedStable ?: [NSNull null],
                                 @"performing": performing ?: [NSNull null] };
        cache = [built retain];   // MRC: app 生命周期缓存，永不释放
    }
    NSImage* img = cache[[NSString stringWithUTF8String:state]];
    return [img isKindOfClass:[NSImage class]] ? img : nil;
}

static void trayUpdateIcon() {
    if (!g_statusItem || g_appTerminating) return;
    // 状态图标（SVG→PNG 三态）：connected-stable 工作中 / disconnected 停止 / performing 切换中
    const char* state = g_coreBusy ? "performing" : (engineAlive() ? "connected-stable" : "disconnected");
    peq_dbg("trayIcon: state=%s", state);   // debug
    NSImage* img = trayStatusImageCached(state);
    peq_dbg("trayIcon: img=%p", img);   // debug
    if (img) {
        g_statusItem.button.image = img;
        peq_dbg("trayIcon: image set");   // debug
        g_statusItem.button.title = @"";
    } else {
        const char* fallback = g_coreBusy ? "🆅" : (engineAlive() ? "🅅" : "🇻");   // 图标缺失兜底
        g_statusItem.button.image = nil;
        g_statusItem.button.title = [NSString stringWithUTF8String:fallback];
    }
}

// 同步跑一个任务，返回退出码
static int runTask(NSString* launchPath, NSArray* args) {
    NSTask* t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:launchPath];
    t.arguments = args;
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError* err = nil;
    if (![t launchAndReturnError:&err]) return -1;
    [t waitUntilExit];
    return (int)[t terminationStatus];
}

// driver 装卸等特权操作：先试 sudo -n（免密），失败再弹系统密码框。
// prompt 为密码框的说明文字（告知用户本次授权的目的）。
// debug: macOS 26 osascript 语法变化——prompt 必须在 administrator privileges 之前
// （旧语序 "with administrator privileges prompt ..." 被解析器拒绝 -2741）
static bool runPrivilegedScript(NSString* scriptPath, NSString* prompt) {
    if (runTask(@"/usr/bin/sudo", @[@"-n", scriptPath]) == 0) return true;
    NSString* oa = [NSString stringWithFormat:
        @"do shell script \"sh %@\" with prompt \"%@\" with administrator privileges",
        scriptPath, prompt];
    return runTask(@"/usr/bin/osascript", @[@"-e", oa]) == 0;
}
// 兼容旧调用（默认提示）
static bool runPrivilegedScript(NSString* scriptPath) {
    return runPrivilegedScript(scriptPath, @"VfdPEQ needs administrator privileges");
}

static void stopEngineManaged() {
    g_enginePid = 0;
    if (g_engineTask) {
        [g_engineTask setTerminationHandler:nil];   // 退出过程中不再派发（防野指针回调）
        if ([g_engineTask isRunning]) { [g_engineTask terminate]; [g_engineTask waitUntilExit]; }
        g_engineTask = nil;
    }
    system("pkill -f 'engine/build/peq_engine' 2>/dev/null");
    // 引擎状态文件随引擎死亡而失效，删除防止旧 output_name 回灌配置
    NSString* statusPath = [NSString stringWithFormat:@"%s/engine.status",
                            g_confPath.substr(0, g_confPath.find_last_of('/')).c_str()];
    [[NSFileManager defaultManager] removeItemAtPath:statusPath error:nil];
}

static bool startEngineManaged() {
    peq_dbg("startEngineManaged: begin");   // debug
    stopEngineManaged();                            // RAII：存在就杀掉，由托盘启动
    NSString* enginePath = [projRoot() stringByAppendingPathComponent:@"engine/build/peq_engine"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:enginePath]) {
        fprintf(stderr, "[tray] engine binary missing: %s\n", enginePath.UTF8String);
        return false;
    }
    NSTask* t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:enginePath];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];    // 非交互：失配时引擎自动退出
    NSString* logPath = @"/tmp/vfdpeq_engine.log";
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath])
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle* log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [log seekToEndOfFile];                      // debug: 追加模式（统一日志不截断）
    t.standardOutput = log; t.standardError = log;
    t.terminationHandler = ^(NSTask* task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_appTerminating) return;
            const bool wasManaged = (g_engineTask == task);
            if (wasManaged) g_engineTask = nil;
            // Core 开启状态下 engine 意外退出（如 coreaudiod 重启后设备枚举延迟）：
            // 退避自动重启，连续失败 5 次放弃
            if (wasManaged && !g_coreBusy && driverInstalled()) {
                static int attempts = 0;
                if (attempts < 5) {
                    const int delay = 2 << attempts;              // 2/4/8/16/32 秒
                    ++attempts;
                    fprintf(stderr, "[tray] engine exited unexpectedly, restarting in %ds (attempt %d)\n",
                            delay, attempts);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
                                   dispatch_get_main_queue(), ^{
                        if (g_appTerminating || g_coreBusy) return;
                        if (startEngineManaged()) {
                            if (engineAlive()) { attempts = 0; ensureSystemOutputIsPEQ(); }
                        }
                    });
                } else {
                    fprintf(stderr, "[tray] engine restart abandoned after 5 attempts\n");
                }
            }
            trayUpdateIcon();
        });
    };
    NSError* err = nil;
    if (![t launchAndReturnError:&err]) {
        fprintf(stderr, "[tray] engine launch failed: %s\n", err.localizedDescription.UTF8String);
        return false;
    }
    g_engineTask = t;
    g_enginePid = (int)t.processIdentifier;     // debug
    fprintf(stderr, "[tray] engine started (pid %d)\n", (int)t.processIdentifier);
    return true;
}

// 设备失配（配置指向的输出设备消失）：
// 托盘【不】停引擎/清配置——引擎自身会在主循环检测失联并自动降级到可用输出
// （fallbackOutputDevice），随后 engine.status 更新、本文件 §refreshEngineStatus 会同步配置。
// 托盘只做状态刷新。实测：拔耳机 → 引擎 2s 内降级到内建扬声器，声音不断。
static bool g_mismatchPending = false;
static void checkDeviceMismatch() {
    if (g_conf.outputName.empty() || g_mismatchPending) return;
    if (findDeviceByName(g_conf.outputName) == kAudioObjectUnknown) {
        g_mismatchPending = true;
        peq_dbg("mismatch: config device gone, waiting for engine fallback");   // debug
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)2.5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            g_mismatchPending = false;
            if (g_conf.outputName.empty()) return;
            if (findDeviceByName(g_conf.outputName) == kAudioObjectUnknown) {
                // 引擎 2s 拍已处理（status 应已变更）；此处仅兜底刷新 UI 状态
                peq_dbg("mismatch: engine fallback pending, refresh UI only");   // debug
                refreshEngineStatus();
            } else {
                peq_dbg("mismatch cleared: device back");   // debug
            }
        });
    }
}

// Core ON 的收尾：确保系统默认输出指向 VfdPEQ（卸载 driver 时 macOS 会把默认
// 输出切走，重装后不会自动切回——不补这一步，整个 EQ 链路的第一环就是断的）
static void ensureSystemOutputIsPEQ() {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 50; ++i) {                      // 最多等 5 秒（驱动重载有延迟）
            const AudioDeviceID d = findDeviceByName("VfdPEQ 2ch");
            if (d != kAudioObjectUnknown) {
                AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDefaultOutputDevice,
                                                 kAudioObjectPropertyScopeGlobal,
                                                 kAudioObjectPropertyElementMain};
                OSStatus err = AudioObjectSetPropertyData(kAudioObjectSystemObject, &pa, 0,
                                                          nullptr, sizeof(d), &d);
                fprintf(stderr, "[tray] system default output -> VfdPEQ (%s)\n",
                        err == noErr ? "ok" : "failed");
                return;
            }
            usleep(100000);
        }
        fprintf(stderr, "[tray] VfdPEQ device never appeared; default output unchanged\n");
    });
}

static void coreOn() {
    if (g_coreBusy) return;
    g_coreBusy = true; trayUpdateIcon();
    peq_dbg("coreOn: begin (driverInstalled=%d)", driverInstalled() ? 1 : 0);   // debug
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        system("pkill -f 'engine/build/peq_engine' 2>/dev/null");   // RAII: 存在就杀
        bool ok = true;
        if (!driverInstalled())
            ok = runPrivilegedScript([projRoot() stringByAppendingPathComponent:@"scripts/install.sh"],
                @"VfdPEQ 首次启动：安装音频驱动（VfdPEQ.virtual device）到系统");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_appTerminating) return;
            g_coreBusy = false;
            if (ok) { startEngineManaged(); ensureSystemOutputIsPEQ(); startDrvLogStream(); }
            else fprintf(stderr, "[tray] core ON aborted (driver install failed)\n");
            peq_dbg("coreOn: done (ok=%d)", ok ? 1 : 0);   // debug
            trayUpdateIcon();
        });
    });
}

// debug: 架构决策（用户批准）——托盘 Core 开关只管引擎启停，驱动常驻安装。
// 反复"卸载驱动 + killall coreaudiod"是 coreaudiod 对象 churn 死循环的触发序列
// （实测 140%+ CPU、一切音频查询悬挂）。彻底卸载请手动运行 scripts/uninstall.sh。
static void coreOff() {
    if (g_coreBusy) return;
    g_coreBusy = true; trayUpdateIcon(); stopDrvLogStream();
    dispatch_async(dispatch_get_main_queue(), ^{
        stopEngineManaged();
        g_coreBusy = false;
        peq_dbg("coreOff: engine stopped (driver kept installed)");   // debug
        trayUpdateIcon();
    });
}

static void deviceSelect(NSString* name) {
    peq_dbg("deviceSelect: '%s' (engineAlive=%d coreBusy=%d driverInstalled=%d)",   // debug
            name.UTF8String, engineAlive() ? 1 : 0, g_coreBusy ? 1 : 0, driverInstalled() ? 1 : 0);
    g_deviceSwitchingUntil = ImGui::GetTime() + 2.5;
    g_confAuthorityUntil = ImGui::GetTime() + 3.0;   // debug
    g_conf.outputName = name.UTF8String;
    g_dirtySave = true;
    peqconf::save(g_confPath.c_str(), g_conf);      // 立即落盘（不依赖 draw 循环）
    // Core 未就绪（驱动未装/引擎未跑）→ 先拉起 Core：装驱动 + 起引擎，引擎起来后
    // 会读取 conf 的 output_name 自动绑定目标设备
    if (!driverInstalled()) {
        if (!g_coreBusy) coreOn();                  // coreOn 完成后会 startEngineManaged
        return;                                     // conf 已写好，Core 起来后自动生效
    }
    if (!engineAlive() && !g_coreBusy) startEngineManaged();
    trayUpdateIcon();
}

static void deviceOff() {
    stopEngineManaged();
    g_conf.outputName.clear();
    g_dirtySave = true;
    peqconf::save(g_confPath.c_str(), g_conf);
    trayUpdateIcon();
}

static NSString* launchAgentPlist() {
    // debug: 用户级 LaunchAgents（privileged 脚本安装到同一位置——路径必须一致，
    // 上轮曾误写为系统级 /Library/LaunchAgents 导致"已安装却显示 Disabled"）
    return [@"~/Library/LaunchAgents/dev.vfdpeq.gui.plist" stringByExpandingTildeInPath];
}
static bool launchAtLoginOn() {
    return [[NSFileManager defaultManager] fileExistsAtPath:launchAgentPlist()];
}
// debug: Launch at login——全部在后台队列执行（主线程/菜单零阻塞）。
// plist 写标准 ~/Library/LaunchAgents/；sudoers 白名单已移除（驱动常驻架构下
// 反复装卸驱动不再发生，免密装卸无意义——之前会在主线程弹管理员密码框卡死 UI）。
static void setLaunchAtLogin(bool on) {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString* exe = [projRoot() stringByAppendingPathComponent:@"gui/build/peq_engine"];
        NSString* guiExe = [projRoot() stringByAppendingPathComponent:@"gui/build/peq_gui"];
        NSString* tmpPlist = @"/tmp/vfdpeq_launchagent.plist";
        NSString* scriptPath = @"/tmp/vfdpeq_launch_toggle.sh";
        NSString* script;
        if (on) {
            // debug: macOS 26 安全策略——普通应用进程直接写 ~/Library/LaunchAgents 被 TCC 拒绝
            // （实测 write:0 "You don't have permission to save the file"，即便目录属主可写）。
            // GUI 把 plist 写到 /tmp（进程内可写），privileged script 负责安装到 LaunchAgents
            // + launchctl load——与 install.sh 同模式，低频操作一次密码可接受。
            NSDictionary* d = @{@"Label": @"dev.vfdpeq.gui",
                                @"ProgramArguments": @[guiExe, @"--launched-by-agent"],
                                @"RunAtLoad": @YES, @"KeepAlive": @NO,
                                @"ProcessType": @"Interactive"};
            NSError* werr = nil;
            NSData* data = [NSPropertyListSerialization dataWithPropertyList:d
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0 error:&werr];
            if (!data || ![data writeToFile:tmpPlist options:NSDataWritingAtomic error:&werr]) {
                peq_dbg("launch at login: /tmp plist write failed (%s)",   // debug
                        werr.localizedDescription.UTF8String ?: "none");
                return;
            }
            script = [NSString stringWithFormat:
                @"mkdir -p \"/Users/%@/Library/LaunchAgents\" && "
                @"cp /tmp/vfdpeq_launchagent.plist \"/Users/%@/Library/LaunchAgents/dev.vfdpeq.gui.plist\" && "
                @"chown -R \"$USER\" \"/Users/%@/Library/LaunchAgents/dev.vfdpeq.gui.plist\"",
                NSFullUserName(), NSFullUserName(), NSFullUserName()];
            (void)exe;
        } else {
            script = [NSString stringWithFormat:
                @"rm -f \"/Users/%@/Library/LaunchAgents/dev.vfdpeq.gui.plist\" \"/Users/%@/.vfdpeq_login_enabled\"",
                NSFullUserName(), NSFullUserName()];
        }
        [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        const bool privOk = runPrivilegedScript(scriptPath);
        // debug: load/unload 必须以用户身份执行——privileged(root) shell 里 load
        // 用户 Aqua agent 会上下文混乱并卡死（实测：脚本永远等不到完成）
        if (on && privOk) {
            const int lc = runTask(@"/bin/launchctl", @[@"load", launchAgentPlist()]);
            peq_dbg("launchctl load exit=%d", lc);   // debug
        }
        peq_dbg("launch at login: %s (privileged %s)", on ? "enabled" : "disabled",   // debug
                privOk ? "ok" : "cancelled");
        dispatch_async(dispatch_get_main_queue(), ^{ trayUpdateIcon(); });
    });
}

@interface TrayDelegate : NSObject
- (void)statusClicked;
- (void)quit;
- (void)coreOnAction;
- (void)coreOffAction;
- (void)deviceOffAction;
- (void)devicePick:(NSMenuItem*)sender;
- (void)devMenuSink:(NSMenuItem*)sender;
- (void)toggleLogin;
@end
// debug: NSMenu 模态跟踪会吞掉鼠标 UP 事件的投递路径，ImGui 内部可能残留
// "按住/路由失效"状态（实测：右键切换后 hover 全灭 + capture 悬空 + 狂点无效）。
// 菜单 action 回调（主线程）末尾显式复位鼠标按键状态。
static void imguiResetMouseAfterMenu() {
    if (g_appTerminating) return;
    peq_dbg("mouse-reset executed");   // debug: 验证 NSMenuDidEndTracking 触发
    ImGuiIO& io = ImGui::GetIO();
    // debug: NSMenu 模态跟踪会吞掉右键 UP 事件 → io.MouseDown[1] 永久卡在按下状态
    // → ImGui 的"点击所有权"机制（MouseDownOwned=false + mouse_earliest_down）持续清除
    // hovered window → hover 全灭。菜单跟踪结束必触发本复位。
    io.AddMouseButtonEvent(0, false);
    io.AddMouseButtonEvent(1, false);
    io.AddMouseButtonEvent(2, false);
}


@implementation TrayDelegate
- (void)statusClicked {
    NSEvent* e = [NSApp currentEvent];
    if (e && e.type == NSEventTypeRightMouseUp) {
        NSMenu* m = [[NSMenu alloc] initWithTitle:@"tray"];
        m.delegate = (id<NSMenuDelegate>)self;
        NSView* b = g_statusItem.button;
        const NSPoint screen = [NSEvent mouseLocation];
        const NSPoint inBtn = NSMakePoint(screen.x - b.window.frame.origin.x,
                                          screen.y - b.window.frame.origin.y);
        [m popUpMenuPositioningItem:nil atLocation:inBtn inView:b];
    } else if (g_window.isVisible) {
        [g_window orderOut:nil];
    } else {
        [g_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        imguiResetMouseAfterMenu();   // debug: 窗口 orderOut/orderFront 后复位 ImGui 鼠标状态（同 NSMenu 吞 UP 场景）
    }
}
- (void)menuNeedsUpdate:(NSMenu*)m {
    [m removeAllItems];
    checkDeviceMismatch();                          // 展开菜单即校验失配
    // Core
    NSMenuItem* core;
    if (g_coreBusy) {
        core = [m addItemWithTitle:@"Core: working…" action:nil keyEquivalent:@""];
        core.enabled = NO;
    } else if (engineAlive()) {
        core = [m addItemWithTitle:@"[On] Core" action:@selector(coreOffAction)
                            keyEquivalent:@""];
        core.target = self; core.state = NSControlStateValueOn;
    } else {
        core = [m addItemWithTitle:@"[Off] Core" action:@selector(coreOnAction)
                            keyEquivalent:@""];
        core.target = self;
    }
    // Device submenu
    NSMenuItem* devItem = [m addItemWithTitle:@"Device" action:nil keyEquivalent:@""];
    NSMenu* dev = [[NSMenu alloc] initWithTitle:@"Device"];
    devItem.submenu = dev;
    NSMenuItem* off = [dev addItemWithTitle:@"Off" action:@selector(deviceOffAction) keyEquivalent:@""];
    off.target = self;
    off.state = engineAlive() ? NSControlStateValueOff : NSControlStateValueOn;
    [dev addItem:[NSMenuItem separatorItem]];
    for (auto d : outputDevices()) {
        std::string n = deviceName(d);
        if (n.find("VfdPEQ") != std::string::npos) continue;    // 引擎输入通道，排除
        NSMenuItem* it = [dev addItemWithTitle:[NSString stringWithUTF8String:n.c_str()]
                                        action:@selector(devicePick:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = [NSString stringWithUTF8String:n.c_str()];
        it.state = (g_conf.outputName == n && engineAlive()) ? NSControlStateValueOn
                                                             : NSControlStateValueOff;
    }
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem* login = [m addItemWithTitle:(launchAtLoginOn() ? @"[Enabled] Launch at login"
                                                               : @"[Disabled] Launch at login")
                                     action:@selector(toggleLogin)
                              keyEquivalent:@""];
    login.target = self;
    login.state = launchAtLoginOn() ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem* q = [m addItemWithTitle:@"Quit" action:@selector(quit) keyEquivalent:@""];
    q.target = self;
}
- (void)coreOnAction  { coreOn(); }
- (void)coreOffAction { coreOff(); imguiResetMouseAfterMenu(); }
- (void)deviceOffAction { deviceOff(); imguiResetMouseAfterMenu(); }
- (void)devicePick:(NSMenuItem*)sender {
    deviceSelect(sender.representedObject);
    imguiResetMouseAfterMenu();   // debug
}
- (void)toggleLogin   { setLaunchAtLogin(!launchAtLoginOn()); }
- (void)quit {
    imguiResetMouseAfterMenu();
    // debug: 退出 = 停引擎（驱动常驻保留——卸载触发 coreaudiod churn 死循环，且装卸密码框
    // 与退出流程耦合导致每次 Quit 都要密码）。彻底卸载请手动运行 scripts/uninstall.sh。
    g_appTerminating = true;
    stopDrvLogStream();
    stopEngineManaged();
    peq_dbg("quit: engine stopped (driver kept installed)");   // debug
    [NSApp terminate:nil];
}
@end

static NSTask* g_drvLogTask = nil;   // debug: log stream 子进程，把驱动 syslog 汇入统一日志文件

// debug: 启动驱动日志汇聚（syslog → ~/.vfdpeq_gui.debug.log），随托盘生命周期
static void startDrvLogStream() {
    if (g_drvLogTask) return;
    const char* home = getenv("HOME");
    NSString* logPath = [NSString stringWithFormat:@"%s/.vfdpeq_gui.debug.log", home];
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath])
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [fh seekToEndOfFile];
    NSTask* t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    t.arguments = @[@"stream", @"--predicate",
                    @"eventMessage CONTAINS \"VfdPEQ-DRV\"",
                    @"--style", @"compact"];
    t.standardOutput = fh; t.standardError = fh;
    t.terminationHandler = ^(NSTask* task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_drvLogTask == task) g_drvLogTask = nil;
        });
    };
    NSError* err = nil;
    if (![t launchAndReturnError:&err]) {
        fprintf(stderr, "[tray] drv log stream failed: %s\n", err.localizedDescription.UTF8String);
        return;
    }
    g_drvLogTask = t;
}
static void stopDrvLogStream() {
    if (g_drvLogTask) {
        [g_drvLogTask setTerminationHandler:nil];
        if ([g_drvLogTask isRunning]) [g_drvLogTask terminate];
        g_drvLogTask = nil;
    }
}

static TrayDelegate* g_trayDelegate = nil;
static void traySetup() {
    fprintf(stderr, "[boot 10.1] delegate\n");
    g_trayDelegate = [TrayDelegate new];
    // ⚠️ MRC：工厂方法返回 autoreleased 对象，必须 retain——否则 autorelease pool
    // 排空后 g_statusItem 悬垂（SIGINT/teardown 内存复用后必崩，实测打在 NSExtraMIData 上）
    fprintf(stderr, "[boot 10.2] statusItem\n");
    g_statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    g_statusItem.button.title = @"🇻";
    g_statusItem.button.target = g_trayDelegate;
    g_statusItem.button.action = @selector(statusClicked);
    [g_statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    fprintf(stderr, "[boot 10.3] trayUpdateIcon\n");
    trayUpdateIcon();
    fprintf(stderr, "[boot 10.4] listener\n");
    // 设备热插拔监听：任何时候失配 → 清配置回退 off
    static dispatch_queue_t q;
    q = dispatch_queue_create("dev.vfdpeq.audiolistener", nullptr);
    // g_devicesChangedFlag 由 drawFrame 每秒节流消费（避免唤醒风暴期主线程枚举风暴）
    static AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &pa, q,
        ^(UInt32, const AudioObjectPropertyAddress*) {
            // debug: 回调只置标志——CoreAudio 注册时立即触发首回调，若在回调里 dispatch
            // CoreAudio 枚举会与注册线程的内部锁死锁（实测启动卡死在 listener 注册）。
            // 缓存刷新由 drawFrame 的节流检查消费标志时发起。
            g_devicesChangedFlag = true;
        });
}

// ---------------------------------------------------------------- ImGui frame
static void drawFrame(id<MTLDevice> device) {
    const double now = ImGui::GetTime();
    static double last = 0;
    double dt = (last > 0) ? std::min(now - last, 0.25) : 1.0 / 60.0;
    last = now;
    // debug: 慢帧探针——帧间隔异常（UI 卡死）时打点，供组合问题回溯
    if (dt > 0.5) peq_dbg("SLOW FRAME: %.3fs gap at %.0fs uptime", dt, now);

    // 退出走帧边界：teardown 不能与仍在排队的 draw block 交错（会踩坏堆）
    if (g_quitRequested && !g_appTerminating) {
        peq_dbg("quit requested at frame boundary");   // debug
        g_appTerminating = true;
        stopEngineManaged();
        [NSApp terminate:nil];
        return;
    }

    vfdStep(dt);
    vfdUploadTexture(device, g_screen, g_screenTex, g_rgb, g_rgba);

    // debounced config save
    if (g_dirtySave && now - g_lastSave > 0.3) {
        if (peqconf::save(g_confPath.c_str(), g_conf)) {
            g_dirtySave = false;
            g_lastSave = now;
        }
    }

    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(10, 10));
    // debug: beginOk——托盘 NSMenu 跟踪后疑似窗口路由异常，此探针记录 ImGui 对主窗口的判定
    const bool beginOk = ImGui::Begin("VfdPEQ", nullptr,
                                      ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                          ImGuiWindowFlags_NoBringToFrontOnFocus);
    g_mainBeginOk = beginOk;

    // 组合大屏：图形区 + 控件区同屏等宽
    ImGui::Image((ImTextureID)(__bridge void*)g_screenTex,
                 ImVec2((float)g_screen->width(), (float)g_screen->height()));
    g_imgOrigin = ImGui::GetItemRectMin();

    // 图形区悬停：FR/频谱 → 贯穿竖线 + 频率/FR值；声量计 → L/R dB 读数
    // sheet（导入/导出面板）打开时冻结交互：ImGui_ImplOSX 的全局鼠标监听会把
    // finder 里的点击穿透进来，热区若继续活跃就会误触发音量/参数动作
    const bool modalUp = (g_window && g_window.attachedSheet != nil);
    g_hoverCol = -1;
    if (ImGui::IsItemHovered() && !modalUp) {
        const ImVec2 m = ImGui::GetMousePos();
        const int col = (int)std::floor((m.x - g_imgOrigin.x) / (float)cellPx());
        const int row = (int)std::floor((m.y - g_imgOrigin.y) / (float)cellPx());
        const int fTop = g_screen->frTopRow(), sBot = g_screen->specBottomRow();
        if (col >= g_screen->ctlX0() && col <= g_screen->ctlX1() && row >= fTop && row <= sBot) {
            g_hoverCol = col;
            const float u = (float)(col - g_screen->ctlX0()) /
                            (float)std::max(1, g_screen->plotWidth() - 1);
            const float freq = 20.0f * std::pow(10.0f, 3.0f * u);
            // FR 值（不含 preamp）：与 vfdStep 的曲线绘制同一插值
            float frDb = 0.0f;
            const int N = (int)g_fr.comp.size();
            if (N > 1) {
                const float x = u * (float)(N - 1);
                const int i0 = std::min(N - 1, (int)x);
                const int i1 = std::min(N - 1, i0 + 1);
                frDb = g_fr.comp[i0] * (1.0f - (x - (float)i0)) + g_fr.comp[i1] * (x - (float)i0);
                if (g_conf.bypass) frDb = 0.0f;
            }
            char tt[64];
            if (freq >= 1000.0f) snprintf(tt, sizeof(tt), "%.2f kHz  |  PEQ %+.1f dB", freq / 1000.0f, frDb);
            else                 snprintf(tt, sizeof(tt), "%.0f Hz      |  PEQ %+.1f dB", freq, frDb);
            ImGui::SetTooltip("%s", tt);
        } else if (row >= 1 && row <= 11) {   // 声量计区（L/R 两条 + 边距）
            const float kDbMin = -60.0f;
            const float lv = g_meters.vuNorm()[0] * -kDbMin + kDbMin;
            const float lp = g_meters.peakNorm()[0] * -kDbMin + kDbMin;
            const float rv = g_meters.vuNorm()[1] * -kDbMin + kDbMin;
            const float rp = g_meters.peakNorm()[1] * -kDbMin + kDbMin;
            ImGui::SetTooltip("L  VU %+.1f dB  |  PK %+.1f dB\nR  VU %+.1f dB  |  PK %+.1f dB",
                              lv, lp, rv, rp);
        }
    }

    // debug: hover 命中汇总 + ImGui 窗口状态（2s 限频，鼠标在窗口内才打）
    {
        ImGuiIO& mio0 = ImGui::GetIO();   // debug: 非 const（AddMousePosEvent 注入需要）
        static double lastHoverLog = 0;
        if (now - lastHoverLog > 2.0 && mio0.MousePos.x > -10000) {
            lastHoverLog = now;
            const ImVec2 wp = ImGui::GetWindowPos();
            const ImVec2 ws = ImGui::GetWindowSize();
            ImGuiContext* g = ImGui::GetCurrentContext();
            const char* hwName = g->HoveredWindow ? g->HoveredWindow->Name : "NULL";
            peq_dbg("hover: over='%s' capture=%d mouse=(%.0f,%.0f) winHovered=%d beginOk=%d popups=%d hoveredWin='%s' mdown=%d%d%d",   // debug
                    g_lastHoverName, (int)mio0.WantCaptureMouse, mio0.MousePos.x, mio0.MousePos.y,
                    (int)ImGui::IsWindowHovered(), (int)g_mainBeginOk, (int)g->OpenPopupStack.Size, hwName,
                    (int)mio0.MouseDown[0], (int)mio0.MouseDown[1], (int)mio0.MouseDown[2]);
        }
        // debug: hover 路由自恢复——鼠标在窗口 rect 内但 ImGui 路由不认（托盘 NSMenu
        // 模态跟踪吞掉右键 UP → ImGui"点击所有权"机制持续清除 hovered window，mdown 探针实锤）。
        // 修复：每帧检测（0.5s 内触发），注入"全键释放 + 鼠标离开/重新进入"，强制重算窗口路由。
        {
            ImGuiIO& mio1 = ImGui::GetIO();
            const bool mouseInWin = mio1.MousePos.x >= 0 && mio1.MousePos.x < mio1.DisplaySize.x &&
                                    mio1.MousePos.y >= 0 && mio1.MousePos.y < mio1.DisplaySize.y;
            static int lostHoverFrames = 0;
            static bool lostAnnounced = false;
            // debug: 特例排除——按住拖拽时（MouseDown[0] 持续 / ActiveId 存在）ImGui 的
            // IsWindowHovered 为 false 是正常语义（ActiveId 占用 hover），注入复位事件
            // 会把 MouseDown[0] 强制置 false，表现为"拖到 0.5s 自动松开"。
            const bool dragHold = mio0.MouseDown[0] || ImGui::GetActiveID() != 0;   // debug: 按住/拖拽/输入框活动
            if (!ImGui::IsWindowHovered() && mouseInWin && !dragHold) {
                ++lostHoverFrames;
                if (lostHoverFrames == 30 && !lostAnnounced) {   // 0.5s（60fps × 30 帧）首次触发打一条
                    lostAnnounced = true;
                    peq_dbg("hover lost 0.5s -> reset mouse buttons + leave/re-enter");   // debug
                }
                if (lostHoverFrames >= 30) {   // 持续注入直到恢复（每帧事件对，直到路由重算成功）
                    mio1.AddMouseButtonEvent(0, false);
                    mio1.AddMouseButtonEvent(1, false);
                    mio1.AddMouseButtonEvent(2, false);
                    const ImVec2 cur = mio1.MousePos;
                    mio1.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
                    mio1.AddMousePosEvent(cur.x, cur.y);
                }
            } else {
                lostHoverFrames = 0;
                lostAnnounced = false;
            }
        }
    }
    g_lastHoverName = "(none)";   // debug: 每帧重置（防残留误导）

    // debug: 鼠标事件监听心跳 + 点击即时记录
    // ① 每次按键状态翻转即时打点——卡死时点击若出现 "mouse: DOWN" = 事件流活着（问题在热区/逻辑）；
    //    若无 = 输入监听本身断流（问题在系统层）。② 每秒一条心跳证明输入管道在持续工作。
    {
        const ImGuiIO& mio = ImGui::GetIO();
        static bool lastDown = false;
        if ((bool)mio.MouseDown[0] != lastDown) {
            lastDown = mio.MouseDown[0];
            peq_dbg("mouse: %s at (%.0f,%.0f) capture=%d",   // debug
                    lastDown ? "DOWN" : "UP", mio.MousePos.x, mio.MousePos.y,
                    (int)mio.WantCaptureMouse);
        }
        static double lastMouseHb = 0;
        if (now - lastMouseHb > 1.0) {
            lastMouseHb = now;
            peq_dbg("mouse-hb: pos=(%.0f,%.0f) down=%d capture=%d fps=%.0f",   // debug
                    mio.MousePos.x, mio.MousePos.y, (int)mio.MouseDown[0],
                    (int)mio.WantCaptureMouse, mio.Framerate);
        }
    }

    // 设备变化节流处理：最多每秒一次失配复查（唤醒风暴/拔插风暴合并）
    if (g_devicesChangedFlag && now - g_lastDeviceCheck > 1.0) {
        g_devicesChangedFlag = false;
        g_lastDeviceCheck = now;
        refreshDeviceCacheAsync();   // debug: 后台刷新设备缓存（主线程零 CoreAudio）
        checkDeviceMismatch();
    }

    ensureVolumeBindings();
    if (!modalUp) drawControlInteractions(dt);   // sheet 期间冻结热区（见上）

    ImGui::End();
    ImGui::PopStyleVar(2);
}

// ---------------------------------------------------------------- AppKit / Metal scaffolding
@interface AppView : MTKView <NSWindowDelegate>
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@end
@implementation AppView
- (void)dealloc { [super dealloc]; }
- (BOOL)acceptsFirstResponder { return YES; }
@end

@interface ViewController : NSViewController <MTKViewDelegate>
@end
@implementation ViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.view.layer = layer;
}
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size { (void)view; (void)size; }
- (void)drawInMTKView:(MTKView*)view {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)view.bounds.size.width, (float)view.bounds.size.height);
    const float scale = (float)view.layer.contentsScale;
    io.DisplayFramebufferScale = ImVec2(scale, scale);

    id<MTLCommandBuffer> commandBuffer = [[(AppView*)view commandQueue] commandBuffer];
    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor == nil) { [commandBuffer commit]; return; }

    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    ImGui_ImplMetal_NewFrame(renderPassDescriptor);
    ImGui_ImplOSX_NewFrame(view);
    ImGui::NewFrame();

    drawFrame(view.device);

    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, renderEncoder);
    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
// 信号 → 主线程优雅退出（走 applicationWillTerminate 的 RAII 收尸：停 engine）。
// handler 里只做 async-signal-safe 的 write（self-pipe），终止动作由主队列的
// dispatch source 执行——直接在 handler 里 dispatch_async 会撞上中断点上的
// 运行时/堆锁导致 SIGSEGV。
static int g_sigFd[2] = {-1, -1};
static void guiSignalHandler(int sig) {
    const char* home = getenv("HOME");
    char mpath[512]; snprintf(mpath, sizeof(mpath), "%s/.sighandler_marker", home ? home : "/tmp");
    int mfd = open(mpath, O_WRONLY | O_CREAT | O_APPEND, 0644);   // debug
    if (mfd >= 0) { write(mfd, "HIT\n", 4); close(mfd); }                            // debug
    // debug: 应急兜底——直接给引擎发 SIGTERM（kill 是 signal-safe 的）。
    // 正常退出流程由 self-pipe → 帧边界完成；这里保证即使 GUI 的退出流程
    // 因任何原因失效（渲染循环停摆、handler 链断裂），引擎也不会变孤儿。
    if (g_enginePid > 0) kill(g_enginePid, SIGTERM);
    if (g_sigFd[1] >= 0) { char c = 1; ssize_t r = write(g_sigFd[1], &c, 1); (void)r; }
}
static void guiSignalSetup() {
    if (pipe(g_sigFd) != 0) return;
    fcntl(g_sigFd[1], F_SETFL, O_NONBLOCK);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, g_sigFd[0], 0,
                                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        // debug: 退出决策在主队列 handler 直接执行——后台窗口的渲染循环可能停摆，
        // 依赖 drawFrame 消费退出标志会永远不退出。主队列串行保证与 draw 无交错。
        g_quitRequested = true;
        if (!g_appTerminating) {
            g_appTerminating = true;
            stopEngineManaged();
            [NSApp terminate:nil];
        }
    });
    dispatch_resume(src);
    // debug: 用 sigaction（比 signal 可靠）+ 显式确认安装
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = guiSignalHandler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGINT, &sa, nullptr) == 0 && sigaction(SIGTERM, &sa, nullptr) == 0)
        peq_dbg("signal handlers installed (sigaction, self-pipe + engine kill)");   // debug
    else
        peq_dbg("signal handler install FAILED");   // debug
    // debug: 检查主线程信号掩码（SIGINT 被阻塞会导致 pending 永不投递）
    sigset_t cur;
    pthread_sigmask(SIG_BLOCK, NULL, &cur);
    peq_dbg("SIGINT blocked=%d SIGTERM blocked=%d",
            sigismember(&cur, SIGINT) == 1, sigismember(&cur, SIGTERM) == 1);   // debug
}

@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app { (void)app; return NO; }
- (void)applicationDidFinishLaunching:(NSNotification*)note {
    (void)note;
    peq_dbg("[boot 9] didFinishLaunching");   // debug
    guiSignalSetup();
    peq_dbg("signal handlers installed (SIGINT/SIGTERM -> self-pipe + engine kill)");   // debug
    peq_dbg("[boot 10] traySetup");   // debug
    traySetup();
    peq_dbg("[boot 11] refreshDeviceCache");   // debug
    refreshDeviceCacheAsync();
    peq_dbg("[boot 12] coreOn");   // debug
    coreOn();       // 软件运行时默认立马开启（driver 缺失时弹一次密码框）
}
- (void)applicationWillTerminate:(NSNotification*)note {
    (void)note;
    g_appTerminating = true;
    stopDrvLogStream();
    stopEngineManaged();    // RAII 收尸（驱动常驻保留）
}
@end

int main(int argc, const char** argv) {
    peq_dbg_init("GUI");
    peq_dbg("[boot 1] dbglog init");   // debug
    // ---- 单实例保护（flock）：多实例会互杀 engine，托盘语义完全失效 ----
    static int lockFd = -1;
    {
        lockFd = open("/tmp/vfdpeq_gui.lock", O_RDWR | O_CREAT, 0600);
        if (lockFd >= 0 && flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
            fprintf(stderr, "[gui] another instance is running, exiting\n");
            close(lockFd);
            return 0;
        }
    }
    peq_dbg("[boot 2] flock");   // debug
    @autoreleasepool {
        if (argc > 1) g_confPath = argv[1];
        peq_dbg("[boot 3] conf load");   // debug
        resolveProjectPaths();
        g_conf = peqconf::load(g_confPath.c_str());
        if (g_conf.ch[0].empty())
            for (int i = 0; i < 10; ++i) g_conf.ch[0].push_back(peqconf::Band{});
        if (!g_conf.lrMode) g_conf.ch[1] = g_conf.ch[0];
        g_themeIdx    = std::clamp(g_conf.hueIdx, 0, vfdrender::kThemeCount - 1);
        g_frRangeIdx  = std::clamp(g_conf.rngIdx, 0, 4);
        fprintf(stderr, "[gui] L=%zu R=%zu bands from %s (lr=%d bypass=%d preamp=%.1f/%.1f)\n",
                g_conf.ch[0].size(), g_conf.ch[1].size(), g_confPath.c_str(), (int)g_conf.lrMode,
                (int)g_conf.bypass, g_conf.preampDb[0], g_conf.preampDb[1]);

        peq_dbg("[boot 4] NSApp");   // debug
        NSApp = [NSApplication sharedApplication];
        AppDelegate* del = [AppDelegate new];
        NSApp.delegate = del;
        // debug: Accessory——Dock 图标隐藏（用户要求：隐藏托盘图标，只依赖状态栏按钮）。
        // 窗口显隐/退出全部走状态栏按钮的左键（显隐）与右键（菜单含 Quit）。
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        peq_dbg("[boot 5] view create");   // debug
        ViewController* vc = [ViewController new];
        NSRect rect = NSMakeRect(0, 0, 680, 750);
        AppView* view = [[AppView alloc] initWithFrame:rect];
        view.device = MTLCreateSystemDefaultDevice();
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        view.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        view.preferredFramesPerSecond = 60;
        view.commandQueue = [view.device newCommandQueue];
        view.delegate = vc;

        NSWindow* window = [[NSWindow alloc] initWithContentRect:rect
                                                        styleMask:NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskResizable
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"VfdPEQ";
        // debug: 隐藏左上角红黄绿三键（关闭/最小化/缩放）——窗口显隐只走状态栏按钮
        [window standardWindowButton:NSWindowCloseButton].hidden = YES;
        [window standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
        [window standardWindowButton:NSWindowZoomButton].hidden = YES;
        window.contentView = view;
        window.delegate = view;
        g_window = window;
        peq_dbg("[boot 6] window show");   // debug
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        peq_dbg("[boot 7] imgui init");   // debug
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        io.IniFilename = nullptr;
        ImGui::StyleColorsDark();
        ImVec4* c = ImGui::GetStyle().Colors;
        c[ImGuiCol_WindowBg] = ImVec4(0.02f, 0.03f, 0.025f, 1.0f);

        // 设备菜单/tooltip 里的中文设备名：默认像素字 + 系统中文 fallback 合并
        // （Hiragino Sans GB 为系统自带；加载失败时中文仍显示 ?，不致命）
        {
            ImFontConfig fc;
            fc.MergeMode = true;
            io.Fonts->AddFontDefault();
            io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/Hiragino Sans GB.ttc", 13.0f, &fc,
                                         io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        }

        ImGui_ImplMetal_Init(view.device);
        ImGui_ImplOSX_Init(view);

        peq_dbg("[boot 8] NSApp run");   // debug
        [NSApp run];
    }
    return 0;
}
