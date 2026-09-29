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
static std::vector<peqconf::Band> g_bands;
static std::string g_confPath = "peq.conf";
static bool   g_bypass      = false;     // EQ 总开关（写进 peq.conf，引擎直通）
static bool   g_dirtySave = false;
static double g_lastSave  = 0;
static FRData g_fr;
static bool   g_frDirty = true;

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
};
static DevCtl g_inCtl, g_outCtl;
static double g_lastStatusRead = 0;
static double g_lastVolPoll    = 0;
static bool   g_volEditing     = false;

// ---- control geometry / hover glow ----
struct CtlGlow { float v = 0.f; };               // 0..1，悬停亮度惯量
static CtlGlow g_glowSide[vfdrender::Screen::kTopButtons];
static CtlGlow g_glowVol[2];
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

static bool getVolumeScalar(AudioDeviceID d, Float32& out) {
    // 实测 macOS 26：VolumeScalar 在 Output scope 下可读，Global scope 会失败
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 sz = sizeof(Float32);
    Float32 v = 0;
    if (AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &v) == noErr) { out = v; return true; }
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
    if (ImGui::GetTime() - g_lastStatusRead > 2.0) {
        g_lastStatusRead = ImGui::GetTime();
        refreshEngineStatus();
    }
    if (ImGui::GetTime() - g_lastVolPoll > 0.5 && !g_volEditing) {
        g_lastVolPoll = ImGui::GetTime();
        if (g_inCtl.dev != kAudioObjectUnknown) g_inCtl.has = getVolumeScalar(g_inCtl.dev, g_inCtl.vol);
        if (g_outCtl.dev != kAudioObjectUnknown) g_outCtl.has = getVolumeScalar(g_outCtl.dev, g_outCtl.vol);
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
    if (g_analyzer.numBands() > 0) {
        g_screen->drawBars(g_analyzer.bands(), g_analyzer.numBands());
        g_screen->drawPeaks(g_analyzer.peaks(), g_analyzer.numBands());
        g_screen->drawMeters(g_meters.vuNorm(), g_meters.peakNorm(), g_meters.channels());
    }

    // FR 子区：只画最终频响（高亮，响应参数变化，带磷光余辉）
    if (g_frDirty) {
        computeFR(g_bands, g_appliedRate > 0 ? g_appliedRate : 48000, g_fr);
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
            if (g_bypass) dbc = 0.0f;                  // 总开关旁路：0dB 平线
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
static CtlRect volRowRect(int i) {
    CtlRect r; int y0, y1;
    g_screen->volRowRect(i, y0, y1);
    r = {g_screen->ctlX0(), y0, g_screen->ctlX1(), y1};
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

static void drawCtlText(const CtlRect& r, const std::string& s, float v, bool centered = true) {
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
//   Preamp: -6.0 dB
//   Filter 1: ON PK Fc 1000 Hz Gain 3.5 dB Q 1.4
static bool exportEqapo(const char* path) {
    FILE* f = fopen(path, "w");
    if (!f) return false;
    double maxGain = 0;                                   // 防削顶惯例：-max gain 作 preamp
    for (const auto& b : g_bands)
        if (b.enabled) maxGain = std::max(maxGain, b.gainDB);
    fprintf(f, "Preamp: %.1f dB\n", -maxGain);
    int n = 0;
    for (const auto& b : g_bands) {
        ++n;
        fprintf(f, "Filter %d: %s %s Fc %.0f Hz Gain %.1f dB Q %.2f\n", n,
                b.enabled ? "ON" : "OFF", typeName(b.type), b.freq, b.gainDB, b.q);
    }
    fclose(f);
    return true;
}

static bool importEqapo(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return false;
    std::vector<peqconf::Band> out;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
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
        out.push_back(b);
    }
    fclose(f);
    if (out.empty()) return false;
    g_bands = out;
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
            fprintf(stderr, "[gui] EQAPO import <- %s : %s (%zu bands)\n",
                    p.URLs.firstObject.path.UTF8String, ok ? "ok" : "FAILED", g_bands.size());
        }
    }];
}

// —— 绘制（每帧，写点阵动态层；在 vfdStep 的 clearDynamic 之后调用）——
void drawControls() {
    char buf[24];

    // 顶部按钮排（声量计与 FR 之间）：PWR RNG INP EXP HUE FLT
    const CtlRect rB[6] = {topButtonRect(0), topButtonRect(1), topButtonRect(2),
                           topButtonRect(3), topButtonRect(4), topButtonRect(5)};
    drawCtlBox(rB[0], g_glowSide[0].v, !g_bypass);
    drawCtlText(rB[0], "PWR", g_bypass ? 0.18f : (kTextBase + g_glowSide[0].v * 0.4f));
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

    // 音量行 0/1：IN(SystemPEQ) / OUT(真实设备)，滑块保留
    const CtlRect rIn = volRowRect(0), rOut = volRowRect(1);
    const int slL = g_screen->ctlX0() + 13, slR = g_screen->ctlX1();
    const CtlRect slIn  = {slL, rIn.y0,  slR, rIn.y1};
    const CtlRect slOut = {slL, rOut.y0, slR, rOut.y1};
    g_screen->textDyn(rIn.x0,  rIn.y0 + 1,  "IN",  kTextBase);
    g_screen->textDyn(rOut.x0, rOut.y0 + 1, "OUT", kTextBase);
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

    // band 行（前 10 个 band）：滑条只保留文字（无滑块）
    const int n = (int)std::min(g_bands.size(), (size_t)vfdrender::Screen::kBandRows);
    for (int i = 0; i < n; ++i) {
        const auto& b = g_bands[i];
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
        if (ImGui::IsItemClicked(0)) { g_bypass = !g_bypass; g_dirtySave = g_frDirty = true; }
    }
    // RNG：FR 纵轴 ±6/12/18/24/36 循环
    {
        float d; bool act;
        ctlHotzone("rng", rB[1], g_glowSide[1], dt, d, act);
        if (ImGui::IsItemClicked(0)) {
            g_frRangeIdx = (g_frRangeIdx + 1) % 5;
            g_screen->setFrRange(kFrRanges[g_frRangeIdx]);
        }
    }
    // INP：导入 EQAPO/REW 配置
    {
        float d; bool act;
        ctlHotzone("inp", rB[2], g_glowSide[2], dt, d, act);
        if (ImGui::IsItemClicked(0)) importDialog();
    }
    // EXP：导出 EQAPO/REW 配置
    {
        float d; bool act;
        ctlHotzone("exp", rB[3], g_glowSide[3], dt, d, act);
        if (ImGui::IsItemClicked(0)) exportDialog();
    }
    // HUE：配色循环
    {
        float d; bool act;
        ctlHotzone("hue", rB[4], g_glowSide[4], dt, d, act);
        if (ImGui::IsItemClicked(0)) g_screen->nextTheme();
    }
    // FLT：全部拉平
    {
        float d; bool act;
        ctlHotzone("flt", rB[5], g_glowSide[5], dt, d, act);
        if (ImGui::IsItemClicked(0)) {
            for (auto& b : g_bands) b.gainDB = 0;
            g_dirtySave = g_frDirty = true;
        }
    }

    // 音量条：拖动改系统音量（0~100% 显示）；双击弹 0~100 输入
    const CtlRect rIn = volRowRect(0), rOut = volRowRect(1);
    const int slL = g_screen->ctlX0() + 13, slR = g_screen->ctlX1();
    const CtlRect slIn  = {slL, rIn.y0,  slR, rIn.y1};
    const CtlRect slOut = {slL, rOut.y0, slR, rOut.y1};
    if (g_inCtl.has) {
        float d; bool act;
        ctlHotzone("volin", slIn, g_glowVol[0], dt, d, act);
        g_volEditing = act;
        if (act && d != 0) {
            g_inCtl.vol = std::min(1.0f, std::max(0.0f, g_inCtl.vol + d));
            setVolumeScalar(g_inCtl.dev, g_inCtl.vol);
        }
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) ImGui::OpenPopup("edin");
        if (ImGui::BeginPopup("edin")) {
            float pct = g_inCtl.vol * 100.0f;
            if (ImGui::SliderFloat("##v", &pct, 0.f, 100.f, "%.0f %%")) {
                g_inCtl.vol = pct / 100.0f;
                setVolumeScalar(g_inCtl.dev, g_inCtl.vol);
            }
            ImGui::EndPopup();
        }
    }
    if (g_outCtl.has) {
        float d; bool act;
        ctlHotzone("volout", slOut, g_glowVol[1], dt, d, act);
        g_volEditing = act || g_volEditing;
        if (act && d != 0) {
            g_outCtl.vol = std::min(1.0f, std::max(0.0f, g_outCtl.vol + d));
            setVolumeScalar(g_outCtl.dev, g_outCtl.vol);
        }
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) ImGui::OpenPopup("edout");
        if (ImGui::BeginPopup("edout")) {
            float pct = g_outCtl.vol * 100.0f;
            if (ImGui::SliderFloat("##v", &pct, 0.f, 100.f, "%.0f %%")) {
                g_outCtl.vol = pct / 100.0f;
                setVolumeScalar(g_outCtl.dev, g_outCtl.vol);
            }
            ImGui::EndPopup();
        }
    }

    // band 行：开关 / 类型 / 频率 / 幅值 / Q
    const int n = (int)std::min(g_bands.size(), (size_t)vfdrender::Screen::kBandRows);
    for (int i = 0; i < n; ++i) {
        auto& b = g_bands[i];
        CtlRect rOn, rType, rFreq, rGain, rQ;
        bandCellRects(i, rOn, rType, rFreq, rGain, rQ);
        ImGui::PushID(i);
        {
            float d; bool act;
            ctlHotzone("on", rOn, g_glowBand[i][0], dt, d, act);
            if (ImGui::IsItemClicked(0)) { b.enabled = !b.enabled; g_dirtySave = g_frDirty = true; }
        }
        {
            float d; bool act;
            ctlHotzone("type", rType, g_glowBand[i][1], dt, d, act);
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
        if (peqconf::save(g_confPath.c_str(), g_bands, g_bypass)) {
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

    // 组合大屏（原生 660x609）：图形区 + 控件区同屏等宽
    ImGui::Image((ImTextureID)(__bridge void*)g_screenTex,
                 ImVec2((float)g_screen->width(), (float)g_screen->height()));
    g_imgOrigin = ImGui::GetItemRectMin();
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("%dx%d | theme: %s", g_screen->width(), g_screen->height(),
                          g_screen->themeLabel());

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
        g_bands = peqconf::load(g_confPath.c_str(), &g_bypass);
        if (g_bands.empty())
            for (int i = 0; i < 10; ++i) g_bands.push_back(peqconf::Band{});
        fprintf(stderr, "[gui] %zu bands from %s (bypass=%d)\n", g_bands.size(), g_confPath.c_str(),
                (int)g_bypass);

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

        ImGui_ImplMetal_Init(view.device);
        ImGui_ImplOSX_Init(view);

        [NSApp run];
    }
    return 0;
}
