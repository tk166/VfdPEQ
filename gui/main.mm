// SystemPEQ GUI — Dear ImGui (Metal) + 全点阵 VFD 界面
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
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include <CoreAudio/CoreAudio.h>
#include <mach-o/dyld.h>
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
#include "vfd/vfd_render.h"

// ---------------------------------------------------------------- state
static peqconf::Conf g_conf;                 // 全部持久状态（bypass/preamp/lrMode/output/bands）
static int   g_curCh = 0;                    // L/R 模式下正在编辑的声道（0=L 1=R）
static std::string g_confPath = "peq.conf";
static bool   g_dirtySave = false;
static double g_lastSave  = 0;
static FRData g_fr;
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
static int g_frRangeIdx = 3;                     // 默认 ±24dB
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
static std::string deviceName(AudioDeviceID d) {
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

static AudioDeviceID findDeviceByName(const std::string& name) {
    for (auto d : outputDevices())
        if (deviceName(d) == name) return d;
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

// device binding + volume polling（无 UI；由 drawFrame 周期调用）
static void ensureVolumeBindings() {
    static bool inLogged = false;
    if (g_inCtl.dev == kAudioObjectUnknown) {
        g_inCtl.dev = findDeviceByName("SystemPEQ 2ch");
        g_inCtl.name = "SystemPEQ 2ch";
        if (g_inCtl.dev != kAudioObjectUnknown) {
            g_inCtl.has = getVolumeScalar(g_inCtl.dev, g_inCtl.vol);
            if (!inLogged) {
                inLogged = true;
                fprintf(stderr, "[gui] IN bind: dev=0x%x has=%d vol=%.2f\n",
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
        if (g_inCtl.dev != kAudioObjectUnknown) {
            g_inCtl.has = getVolumeScalar(g_inCtl.dev, g_inCtl.vol);
            g_inCtl.muted = isMuted(g_inCtl.dev);
        }
        if (g_outCtl.dev != kAudioObjectUnknown) {
            g_outCtl.has = getVolumeScalar(g_outCtl.dev, g_outCtl.vol);
            g_outCtl.muted = isMuted(g_outCtl.dev);
            if (g_outCtl.muted) g_outCtl.vol = 0.0f;   // 静音设备如实显示 0%
        }
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
            g_analyzer.numBands());
}

static void vfdStep(double dt) {
    // lazy init
    if (!g_screen) {
        // 空隙 cell:gap = 3:1（点更小、文字更小）；220 列 × 3px = 660px（≈旧 508px 的 130%）
        // 241 行：声量计 + 按钮排 + FR(61 行) + 频谱(50 行) + 控件区（2 音量行 + 10 band 行）
        g_screen = new vfdrender::Screen(220, 241, 3, 2, -78.0f, 0.0f);
        g_screen->configureDual(true);   // 组合屏：顶部声量计 + 按钮排 + FR + 频谱 + 控件区
    }
    if (!g_shm) {
        g_shm = shmring::ShmFrameRing::open("/systempeq_audio");
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

    // FR 子区：只画最终频响（高亮，响应参数变化，带磷光余辉）
    if (g_frDirty) {
        computeFR(editBands(), g_appliedRate > 0 ? g_appliedRate : 48000, g_fr);
        g_frDirty = false;
    }
    const int pw = g_screen->plotWidth();
    const int N = (int)g_fr.comp.size();
    if (N > 1) {
        for (int c = 0; c < pw; ++c) {
            const float u = (float)c / (float)(pw - 1);
            const float x = u * (float)(N - 1);
            const int i0 = (int)x;
            const int i1 = std::min(N - 1, i0 + 1);
            const float fr = x - (float)i0;
            float dbc = g_fr.comp[i0] * (1.0f - fr) + g_fr.comp[i1] * fr;
            if (g_conf.bypass) dbc = 0.0f;                  // 总开关旁路：0dB 平线
            g_screen->frDotDb(u, dbc, 1.0f);
        }
    }

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
static bool ctlHotzone(const char* id, const CtlRect& r, CtlGlow& g, double dt, float& dnorm,
                       bool& active) {
    const float c = (float)cellPx();
    const ImVec2 p0(g_imgOrigin.x + r.x0 * c, g_imgOrigin.y + r.y0 * c);
    const ImVec2 sz((r.x1 - r.x0 + 1) * c, (r.y1 - r.y0 + 1) * c);
    ImGui::SetCursorScreenPos(p0);
    ImGui::InvisibleButton(id, sz);
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

// 双击弹出数值输入（保留原"double-click to type"能力）
// pid 必须每控件唯一（同 band 的 freq/gain/Q 共用 id 会触发 ImGui ID 冲突告警）
// 注意：InputScalar 不支持 EnterReturnsTrue（1.89+ 会 IM_ASSERT 崩溃），
// 提交用 IsItemDeactivatedAfterEdit 判定。
static void ctlEditPopup(const char* pid, float* v, const char* fmt) {
    if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) ImGui::OpenPopup(pid);
    if (ImGui::BeginPopup(pid)) {
        ImGui::InputFloat("##in", v, 0, 0, fmt);
        if (ImGui::IsItemDeactivatedAfterEdit()) ImGui::CloseCurrentPopup();
        ImGui::EndPopup();
    }
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
        fprintf(f, "Channel: L\nPreamp: %.1f dB\n", g_conf.preampDb[0]);
        writeFilters(f, g_conf.ch[0]);
        fprintf(f, "Channel: R\nPreamp: %.1f dB\n", g_conf.preampDb[1]);
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
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("PWR - EQ master bypass (audio passes through untouched)");
        if (ImGui::IsItemClicked(0)) { g_conf.bypass = !g_conf.bypass; g_dirtySave = g_frDirty = true; }
    }
    // RNG：FR 纵轴 ±6/12/18/24/36 循环
    {
        float d; bool act;
        ctlHotzone("rng", rB[1], g_glowSide[1], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("RNG - FR y-axis range, cycles +/-6/12/18/24/36 dB");
        if (ImGui::IsItemClicked(0)) {
            g_frRangeIdx = (g_frRangeIdx + 1) % 5;
            g_screen->setFrRange(kFrRanges[g_frRangeIdx]);
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
        if (ImGui::IsItemClicked(0)) g_screen->nextTheme();
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
        }
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("SystemPEQ input volume (click to set, drag to fine-tune)");
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
                    if (n.find("SystemPEQ") != std::string::npos) continue;  // 引擎输入通道，选它会死循环
                    devList.emplace_back(dev, n);
                }
                devListAt = ImGui::GetTime();
            }
            ImGui::OpenPopup("devmenu");
        }
        if (ImGui::BeginPopup("devmenu")) {
            for (auto& kv : devList) {
                if (ImGui::MenuItem(kv.second.c_str())) {
                    g_conf.outputName = kv.second;
                    g_dirtySave = true;
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
        }
    }
    if (g_conf.lrMode) {
        float d; bool act;
        ctlHotzone("chL", rChL, g_glowVol[4], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("Edit channel L");
        if (ImGui::IsItemClicked(0)) g_curCh = 0;
        ctlHotzone("chR", rChR, g_glowVol[5], dt, d, act);
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("Edit channel R");
        if (ImGui::IsItemClicked(0)) g_curCh = 1;
    }
    // Preamp 滑条（±12dB，L/R 模式下独立）：
    {
        float d; bool act;
        ctlHotzone("preamp", slPre, g_glowVol[6], dt, d, act);
        if (act && d != 0) {
            editPreamp() = std::min(12.0f, std::max(-12.0f, editPreamp() + d * 24.0f));
            g_dirtySave = true;
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
            if (ImGui::IsItemClicked(0)) { b.enabled = !b.enabled; g_dirtySave = g_frDirty = true; }
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
            }
            float f = (float)b.freq;
            ctlEditPopup("editf", &f, "%.1f");
            if (f > 0 && (double)f != b.freq) { b.freq = f; g_dirtySave = g_frDirty = true; }
        }
        {
            float d; bool act;
            ctlHotzone("gain", rGain, g_glowBand[i][3], dt, d, act);
            snprintf(tt, sizeof(tt), "%s CH - Band %d - gain (dB)", chTag, i + 1);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tt);
            if (act && d != 0) {
                b.gainDB = std::min(12.0, std::max(-12.0, b.gainDB + (double)d * 24.0));
                g_dirtySave = g_frDirty = true;
            }
            float g = (float)b.gainDB;
            ctlEditPopup("editg", &g, "%.2f");
            if ((double)g != b.gainDB) { b.gainDB = g; g_dirtySave = g_frDirty = true; }
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
            }
            float q = (float)b.q;
            ctlEditPopup("editq", &q, "%.3f");
            if (q > 0 && (double)q != b.q) { b.q = q; g_dirtySave = g_frDirty = true; }
        }
        ImGui::PopID();
    }
}

// ---------------------------------------------------------------- ImGui frame
static void drawFrame(id<MTLDevice> device) {
    const double now = ImGui::GetTime();
    static double last = 0;
    double dt = (last > 0) ? std::min(now - last, 0.25) : 1.0 / 60.0;
    last = now;

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
    ImGui::Begin("SystemPEQ", nullptr,
                 ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                     ImGuiWindowFlags_NoBringToFrontOnFocus);

    // 组合大屏：图形区 + 控件区同屏等宽
    ImGui::Image((ImTextureID)(__bridge void*)g_screenTex,
                 ImVec2((float)g_screen->width(), (float)g_screen->height()));
    g_imgOrigin = ImGui::GetItemRectMin();

    // 图形区悬停：FR/频谱 → 贯穿竖线 + 频率/FR值；声量计 → L/R dB 读数
    g_hoverCol = -1;
    if (ImGui::IsItemHovered()) {
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

    ensureVolumeBindings();
    drawControlInteractions(dt);

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
@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app { (void)app; return YES; }
@end

int main(int argc, const char** argv) {
    @autoreleasepool {
        if (argc > 1) g_confPath = argv[1];
        resolveProjectPaths();
        g_conf = peqconf::load(g_confPath.c_str());
        if (g_conf.ch[0].empty())
            for (int i = 0; i < 10; ++i) g_conf.ch[0].push_back(peqconf::Band{});
        if (!g_conf.lrMode) g_conf.ch[1] = g_conf.ch[0];
        fprintf(stderr, "[gui] L=%zu R=%zu bands from %s (lr=%d bypass=%d preamp=%.1f/%.1f)\n",
                g_conf.ch[0].size(), g_conf.ch[1].size(), g_confPath.c_str(), (int)g_conf.lrMode,
                (int)g_conf.bypass, g_conf.preampDb[0], g_conf.preampDb[1]);

        NSApp = [NSApplication sharedApplication];
        AppDelegate* del = [AppDelegate new];
        NSApp.delegate = del;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

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
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable |
                                                                  NSWindowStyleMaskClosable
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        window.title = @"SystemPEQ";
        window.contentView = view;
        window.delegate = view;
        g_window = window;
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

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

        [NSApp run];
    }
    return 0;
}
