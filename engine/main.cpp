// VfdPEQ engine, Stage 2
//   VfdPEQ virtual device --(device IOProc)--> ring buffer --(biquad PEQ)--> real output
//
// Usage:
//   1. Set system output to "VfdPEQ 2ch"
//   2. ./build/peq_engine [peq.conf path] [output device name]
//      - if no output device given, an interactive picker is shown:
//        press Enter to accept the suggested device, or type its number
//   3. Edit peq.conf while running; settings hot-reload (~1s)
#include <AudioToolbox/AudioToolbox.h>
#include <mach-o/dyld.h>
#include <CoreAudio/CoreAudio.h>
#include <sys/stat.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "biquad.hpp"
#include "config.hpp"
#include "ringbuffer.hpp"
#include "../common/shm_ring.hpp"
#include "../common/dbglog.h"   // debug

static constexpr size_t kRingCapacity = 1 << 15; // 32768 frames ~= 0.68s @48k
static constexpr int    kChannels     = 2;

struct Engine {
    FrameRingBuffer      rb{kRingCapacity, kChannels};
    PEQChannel           peq[kChannels];
    std::atomic<bool>    running{true};
    std::string          confPath;
    std::mutex cfgMx;                    // cfg 在 IO 热重载线程写、主循环热切换读
    std::shared_ptr<const PEQConfig> cfg;
    std::shared_ptr<const PEQConfig> getCfg() {
        std::lock_guard<std::mutex> lk(cfgMx);
        return cfg;
    }
    void setCfg(std::shared_ptr<const PEQConfig> p) {
        std::lock_guard<std::mutex> lk(cfgMx);
        cfg = std::move(p);
    }
    time_t               confMtime  = 0;
    int                  reloadTick = 0;
    AudioDeviceID        virtualDev = kAudioObjectUnknown;
    AudioDeviceID        realDev    = kAudioObjectUnknown;
    AudioDeviceIOProcID  inProc     = nullptr;
    AudioDeviceIOProcID  outProc    = nullptr;
    shmring::ShmFrameRing* shm      = nullptr;   // spectrum feed for the GUI
    std::string          curOutputName;          // 当前实际绑定的输出设备名
    std::atomic<bool>    rebindOutput{false};    // conf 变更 → 主循环里热切换输出设备
    std::atomic<bool>    devicesChanged{false};  // CoreAudio 设备列表变化 → 主循环检查失联
    std::atomic<bool>    confReloadRequested{false};  // debug: IOProc 置位 → 主循环热加载
    std::atomic<time_t>  lastRebindAt{0};        // debug: rebind 完成时间（抑制乒乓：完成后 3s 内跳过失联检查）
    // debug counters
    std::atomic<uint64_t> inCB{0}, inFramesGot{0}, inFramesDropped{0}, outUnderrunFrames{0}, outCB{0};
    std::atomic<float>    inPeak{0.0f}, outPeak{0.0f};
};

// ---------- device helpers ----------
static std::string deviceName(AudioDeviceID d) {
    AudioObjectPropertyAddress na = {kAudioObjectPropertyName,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    CFStringRef cfn = nullptr;
    UInt32 sz = sizeof(cfn);
    std::string out;
    if (AudioObjectGetPropertyData(d, &na, 0, nullptr, &sz, &cfn) == noErr && cfn) {
        char buf[128] = {0};
        CFStringGetCString(cfn, buf, sizeof(buf), kCFStringEncodingUTF8);
        CFRelease(cfn);
        out = buf;
    }
    return out;
}

static bool hasOutputStream(AudioDeviceID d) {
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyStreams,
                                     kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    return AudioObjectGetPropertyDataSize(d, &pa, 0, nullptr, &sz) == noErr && sz > 0;
}

static UInt32 transportType(AudioDeviceID d) {
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyTransportType,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    UInt32 t = 0, sz = sizeof(t);
    AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &t);
    return t;
}

static Float64 deviceSampleRate(AudioDeviceID d) {
    AudioObjectPropertyAddress pa = {kAudioDevicePropertyNominalSampleRate,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    Float64 r = 0;
    UInt32 sz = sizeof(r);
    AudioObjectGetPropertyData(d, &pa, 0, nullptr, &sz, &r);
    return r;
}

static AudioDeviceID defaultOutputDevice() {
    AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    AudioDeviceID d = kAudioObjectUnknown;
    UInt32 sz = sizeof(d);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &pa, 0, nullptr, &sz, &d);
    return d;
}

static std::vector<AudioDeviceID> allDevices() {
    AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDevices,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    std::vector<AudioDeviceID> out;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &pa, 0, nullptr, &size) != noErr)
        return out;
    out.resize(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &pa, 0, nullptr, &size, out.data()) != noErr)
        out.clear();
    return out;
}

static const char* transportName(UInt32 t) {
    switch (t) {
        case kAudioDeviceTransportTypeBuiltIn:    return "built-in";
        case kAudioDeviceTransportTypeVirtual:    return "virtual";
        case kAudioDeviceTransportTypeAggregate:  return "aggregate";
        case kAudioDeviceTransportTypeUSB:        return "usb";
        case kAudioDeviceTransportTypeBluetooth:  return "bluetooth";
        case kAudioDeviceTransportTypeAirPlay:    return "airplay";
        default:                                  return "other";
    }
}

static AudioDeviceID findDeviceByName(const std::string& name) {
    for (auto d : allDevices())
        if (deviceName(d) == name) return d;
    return kAudioObjectUnknown;
}

// Interactive picker: list output devices, suggest the best real one.
// Suggestion = default output if it isn't our virtual device, else built-in, else first non-virtual.
static AudioDeviceID pickOutputDeviceInteractive(AudioDeviceID virtualDev) {
    AudioDeviceID def = defaultOutputDevice();
    std::string defName = (def != kAudioObjectUnknown) ? deviceName(def) : "";

    std::vector<AudioDeviceID> outs;
    for (auto d : allDevices())
        if (d != virtualDev && hasOutputStream(d)) outs.push_back(d);

    int suggested = -1;
    printf("\nAvailable output devices:\n");
    for (size_t i = 0; i < outs.size(); ++i) {
        AudioDeviceID d = outs[i];
        std::string n = deviceName(d);
        bool isDefault = (d == def);
        bool isVirtual = transportType(d) == kAudioDeviceTransportTypeVirtual;
        // suggestion: prefer non-virtual default, then built-in, then first non-virtual
        if (suggested < 0) {
            if (isDefault && !isVirtual) suggested = (int)i;
            else if (transportType(d) == kAudioDeviceTransportTypeBuiltIn) suggested = (int)i;
        }
        printf("  [%zu] %-40s %-10s %6.0f Hz%s%s\n", i, n.c_str(),
               transportName(transportType(d)), deviceSampleRate(d),
               isDefault ? "  <- system default" : "",
               isVirtual ? "  (virtual)" : "");
    }
    if (suggested < 0 && !outs.empty()) suggested = 0;

    AudioDeviceID chosen = kAudioObjectUnknown;
    while (chosen == kAudioObjectUnknown) {
        if (suggested >= 0)
            printf("Select output device [Enter = %d (%s), or number]: ",
                   suggested, deviceName(outs[suggested]).c_str());
        else
            printf("Select output device by number: ");
        fflush(stdout);

        char line[64] = {0};
        if (!fgets(line, sizeof(line), stdin)) return kAudioObjectUnknown;
        line[strcspn(line, "\r\n")] = 0;

        if (line[0] == 0) {                       // Enter -> suggestion
            if (suggested >= 0) chosen = outs[suggested];
        } else {
            char* end = nullptr;
            long idx = strtol(line, &end, 10);
            if (end != line && *end == 0 && idx >= 0 && idx < (long)outs.size())
                chosen = outs[idx];
        }
        if (chosen == kAudioObjectUnknown) printf("Invalid choice, try again.\n");
    }
    return chosen;
}

// ---------- input side: VfdPEQ device IOProc ----------
static OSStatus inputProc(AudioObjectID /*inDevice*/, const AudioTimeStamp* /*now*/,
                          const AudioBufferList* inInputData, const AudioTimeStamp* /*inTime*/,
                          AudioBufferList* /*outOutputData*/, const AudioTimeStamp* /*outTime*/,
                          void* client) {
    auto* e = static_cast<Engine*>(client);
    if (inInputData->mNumberBuffers < 1) return noErr;
    const AudioBuffer& ab = inInputData->mBuffers[0];
    static std::atomic<bool> printedOnce{false};
    if (!printedOnce.exchange(true))
        fprintf(stderr, "[dbg] input buffers=%u  ch=%u  bytes=%u\n",
                inInputData->mNumberBuffers, ab.mNumberChannels, ab.mDataByteSize);
    // BlackHole-style stream: Float32, channels interleaved in one buffer
    const size_t frames = ab.mDataByteSize / (sizeof(float) * kChannels);
    e->inCB.fetch_add(1, std::memory_order_relaxed);
    if (ab.mNumberChannels == kChannels) {
        const float* p = static_cast<const float*>(ab.mData);
        float pk = e->inPeak.load(std::memory_order_relaxed);
        for (size_t i = 0; i < frames * kChannels; ++i) {
            float a = std::fabs(p[i]);
            if (a > pk) pk = a;
        }
        e->inPeak.store(pk, std::memory_order_relaxed);
        size_t written = e->rb.write(static_cast<const float*>(ab.mData), frames);
        e->inFramesGot.fetch_add(frames, std::memory_order_relaxed);
        e->inFramesDropped.fetch_add(frames - written, std::memory_order_relaxed);
        if (e->shm) e->shm->write(p, frames);   // pre-EQ feed for GUI spectrum
    }
    return noErr;
}

// ---------- output side: IOProc on the REAL device ----------
static OSStatus outputDeviceProc(AudioObjectID /*inDevice*/, const AudioTimeStamp* /*now*/,
                                 const AudioBufferList* /*inInputData*/, const AudioTimeStamp* /*inTime*/,
                                 AudioBufferList* outOutputData, const AudioTimeStamp* /*outTime*/,
                                 void* client) {
    auto* e = static_cast<Engine*>(client);
    if (outOutputData->mNumberBuffers < 1) return noErr;

    AudioBuffer& ab = outOutputData->mBuffers[0];
    const UInt32 nFrames = ab.mDataByteSize / (sizeof(float) * kChannels);

    static thread_local std::vector<float> tmp;
    tmp.resize(nFrames * kChannels);

    size_t got = e->rb.read(tmp.data(), nFrames);
    e->outCB.fetch_add(1, std::memory_order_relaxed);
    if (got < nFrames) { // underrun: zero-fill the tail
        e->outUnderrunFrames.fetch_add(nFrames - got, std::memory_order_relaxed);
        std::memset(tmp.data() + got * kChannels, 0, (nFrames - got) * kChannels * sizeof(float));
    }

    e->peq[0].processInterleaved(tmp.data(), nFrames, kChannels);

    {   // peak meter (post-EQ, pre-output)
        float pk = e->outPeak.load(std::memory_order_relaxed);
        for (size_t i = 0; i < nFrames * kChannels; ++i) {
            float a = std::fabs(tmp[i]);
            if (a > pk) pk = a;
        }
        e->outPeak.store(pk, std::memory_order_relaxed);
    }

    // write to the real device (interleaved or per-channel buffers)
    if (outOutputData->mNumberBuffers == 1 && ab.mNumberChannels == kChannels) {
        std::memcpy(ab.mData, tmp.data(), nFrames * kChannels * sizeof(float));
    } else {
        for (UInt32 b = 0; b < outOutputData->mNumberBuffers && b < (UInt32)kChannels; ++b) {
            AudioBuffer& ob = outOutputData->mBuffers[b];
            float* dst = static_cast<float*>(ob.mData);
            for (UInt32 f = 0; f < nFrames; ++f) dst[f] = tmp[f * kChannels + b];
        }
    }

    // hot-reload config ~1x per second
    if (++e->reloadTick >= 20) {
        e->reloadTick = 0;
        struct stat st{};
        // debug: 热加载检查（探针只在 mtime 变化时打，正常时静默）
        const int stR = stat(e->confPath.c_str(), &st);
        const bool mtimeChanged = (stR == 0 && st.st_mtime != e->confMtime);
        if (mtimeChanged)
            peq_dbg("reload: mtime changed %lld -> %lld",   // debug
                    (long long)e->confMtime, (long long)st.st_mtime);
        if (mtimeChanged) {
            e->confMtime = st.st_mtime;
            peq_dbg("reload: loadConfig begin");   // debug
            if (auto cfg = loadConfig(e->confPath.c_str(), (int)deviceSampleRate(e->virtualDev))) {
                peq_dbg("reload: loadConfig OK");   // debug
                for (auto& p : e->peq) p.prepare(cfg, kChannels);
                e->setCfg(cfg);
                peq_dbg("[peq] config reloaded (L=%zu R=%zu lr=%d preamp=%.1f/%.1f bypass=%d)",cfg->bands[0].size(), cfg->bands[1].size(), (int)cfg->lrMode, cfg->preampDb[0], cfg->preampDb[1], (int)cfg->bypass);
                if (!cfg->outputName.empty() && cfg->outputName != e->curOutputName)
                    e->rebindOutput.store(true);   // 主循环里热切换（不在 IO 线程动设备）
            }
        }
    }
    return noErr;
}

// status file for the GUI (device binding + volume sliders)
static void writeEngineStatus(const Engine& e, Float64 vRate, Float64 rRate) {
    std::string dir = ".";
    const size_t slash = e.confPath.find_last_of('/');
    if (slash != std::string::npos) dir = e.confPath.substr(0, slash);
    FILE* sf = fopen((dir + "/engine.status").c_str(), "w");
    if (sf) {
        fprintf(sf, "output_name=%s\noutput_rate=%.0f\nvirtual_rate=%.0f\n",
                deviceName(e.realDev).c_str(), rRate, vRate);
        fclose(sf);
    }
}

// 把 VfdPEQ 标称采样率对齐到目标率：SetProperty 可能返回 noErr 但值未生效
// （HAL 侧异步/客户端清理时序），所以设置后必须回读验证，失败带间隔重试。
static bool alignVirtualRate(Engine& e, Float64 want) {
    AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
    for (int i = 0; i < 5; ++i) {
        Float64 cur = deviceSampleRate(e.virtualDev);
        if (std::fabs(cur - want) < 1.0) return true;       // 已一致（含前次生效）
        Float64 w = want;
        OSStatus err = AudioObjectSetPropertyData(e.virtualDev, &ra, 0, nullptr, sizeof(w), &w);
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        if (err == noErr && std::fabs(deviceSampleRate(e.virtualDev) - want) < 1.0) return true;
    }
    return std::fabs(deviceSampleRate(e.virtualDev) - want) < 1.0;
}

// conf 的 output_name 变化 → 切换真实输出设备（主循环线程调用，不在 IO 线程动设备）
//
// 顺序至关重要：VfdPEQ 标称采样率的重对齐必须在它的 IOProc 停止时做——
// 设备 IO 运行中 SetProperty(nominal rate) 会被拒绝（启动时能对齐是因为当时 IO 还没起），
// 拒绝后输入/输出采样率持续失配 = 环形缓冲欠载 = 声音断断续续。
// 核心重绑定：把输出切到指定设备（含 IO 停/对齐/重启的完整顺序）
static void rebindToDevice(Engine& e, AudioDeviceID nd) {
    if (nd == kAudioObjectUnknown || nd == e.realDev) return;
    // 设备刚插回时枚举可能延迟：按名字确认存在，最多重试 1.5s
    for (int i = 0; i < 5; ++i) {
        if (findDeviceByName(deviceName(nd)) != kAudioObjectUnknown) break;
        peq_dbg("[peq] rebind target '%s' not enumerated yet, retry (%d/5)",deviceName(nd).c_str(), i + 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
    }
    {
        auto cfg = e.getCfg();
        if (cfg && !cfg->outputName.empty() && cfg->outputName == deviceName(nd)) {
            // 与配置一致：正常热切换
        }
    }
    const AudioDeviceID oldDev = e.realDev;
    peq_dbg("[peq] switching output: '%s' -> '%s'",oldDev != kAudioObjectUnknown ? deviceName(oldDev).c_str() : "(none)", deviceName(nd).c_str());

    // 1. 先停 VfdPEQ 输入（为重对齐采样率腾出条件，也避免切换期间数据失衡）
    AudioDeviceStop(e.virtualDev, e.inProc);
    // 2. 停+销毁旧输出（必须在真实设备上做，否则旧回调继续跑、和新回调抢数据）
    if (oldDev != kAudioObjectUnknown && e.outProc) {
        AudioDeviceStop(oldDev, e.outProc);
        AudioDeviceDestroyIOProcID(oldDev, e.outProc);
        e.outProc = nullptr;
    }

    // 3. 重对齐 VfdPEQ 标称采样率到新设备（IO 已停，失败则重试）
    const Float64 rRate = deviceSampleRate(nd);
    Float64 vRate = deviceSampleRate(e.virtualDev);
    if (vRate != rRate) {
        if (alignVirtualRate(e, rRate)) {
            vRate = deviceSampleRate(e.virtualDev);
            peq_dbg("[peq] VfdPEQ rate realigned to %.0f Hz", vRate);
        } else {
            peq_dbg("[peq] WARNING: rate realign failed; expect pitch/drop artifacts");
        }
    }

    // 4. 绑定并启动新输出；失败则尽力恢复旧设备
    e.realDev = nd;
    bool ok = AudioDeviceCreateIOProcID(nd, outputDeviceProc, &e, &e.outProc) == noErr &&
              AudioDeviceStart(nd, e.outProc) == noErr;
    if (!ok) {
        peq_dbg("[peq] ERROR: cannot bind new output; restoring previous");
        e.realDev = oldDev;
        ok = oldDev != kAudioObjectUnknown &&
             AudioDeviceCreateIOProcID(oldDev, outputDeviceProc, &e, &e.outProc) == noErr &&
             AudioDeviceStart(oldDev, e.outProc) == noErr;
        if (ok) peq_dbg("[peq] restored output '%s'", deviceName(oldDev).c_str());
    }

    // 5. 重启输入（此时输入输出采样率一致，环形缓冲重新平衡）
    AudioDeviceStart(e.virtualDev, e.inProc);

    if (ok) {
        e.curOutputName = deviceName(e.realDev);
        writeEngineStatus(e, vRate, rRate);
        peq_dbg("rebind DONE: '%s' @ %.0f Hz", deviceName(e.realDev).c_str(), rRate);   // debug
        peq_dbg("[peq] output now '%s' @ %.0f Hz", deviceName(e.realDev).c_str(), rRate);
    } else {
        peq_dbg("rebind FAILED to '%s'", deviceName(nd).c_str());   // debug
    }
}

// ---- 设备列表变化监听（VfdPEQ 之外设备的拔插检测）----
static OSStatus sysDevicesChangedCb(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void* client) {
    // debug: 设备列表变化 → 置引擎标志，主循环 2s 拍检查失联并降级
    // （⚠️ 修复记录：曾误用独立全局标志与 e.devicesChanged 断链，导致失联降级永不触发）
    if (client) ((Engine*)client)->devicesChanged.store(true);
    return noErr;
}
static void installDevicesListener(Engine& e) {
    static AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &pa, sysDevicesChangedCb, &e);
}

// 配置驱动的热切换（conf output_name 变化时由主循环调用）
static void rebindOutputDevice(Engine& e) {
    auto cfg = e.getCfg();
    if (!cfg || cfg->outputName.empty()) return;
    AudioDeviceID nd = findDeviceByName(cfg->outputName);
    if (nd == kAudioObjectUnknown) {
        peq_dbg("[peq] output '%s' not found; keeping '%s'",cfg->outputName.c_str(), e.realDev != kAudioObjectUnknown ? deviceName(e.realDev).c_str() : "(none)");
        return;
    }
    rebindToDevice(e, nd);
}

// 输出设备失联（拔出/失联）时的自动降级：选一个可用输出重绑，保证声音不断
static void fallbackOutputDevice(Engine& e) {
    auto cfg = e.getCfg();
    AudioDeviceID nd = kAudioObjectUnknown;
    if (cfg && !cfg->outputName.empty()) nd = findDeviceByName(cfg->outputName);   // 配置设备若已恢复优先
    if (nd == kAudioObjectUnknown || nd == e.virtualDev) {
        for (auto d : allDevices()) {
            if (d == e.virtualDev || !hasOutputStream(d)) continue;
            if (transportType(d) == kAudioDeviceTransportTypeVirtual) continue;
            nd = d; break;                          // 第一个物理输出（通常是内建扬声器）
        }
    }
    if (nd == kAudioObjectUnknown) {
        peq_dbg("[peq] no output device available for fallback");
        return;
    }
    peq_dbg("[peq] output device lost, falling back to '%s'", deviceName(nd).c_str());
    rebindToDevice(e, nd);
}

int main(int argc, char** argv) {
    peq_dbg_init("ENG");   // debug
    Engine e;
    peq_dbg("engine starting (pid %d)", (int)getpid());   // debug
    // 默认 conf 路径相对可执行文件定位（engine/build/peq_engine -> engine/peq.conf），
    // 不受启动目录影响；argv[1] 仍可覆盖
    {
        char buf[4096];
        uint32_t sz = sizeof(buf);
        std::string def = "peq.conf";
        if (_NSGetExecutablePath(buf, &sz) == 0) {
            std::string p = buf;
            const size_t s1 = p.find_last_of('/');      // .../engine/build
            const size_t s2 = (s1 == std::string::npos) ? std::string::npos : p.rfind('/', s1 - 1);
            if (s2 != std::string::npos) def = p.substr(0, s2) + "/peq.conf";   // .../engine/peq.conf
        }
        e.confPath = argc > 1 ? argv[1] : def;
    }

    e.virtualDev = findDeviceByName("VfdPEQ 2ch");
    // coreaudiod 重启/驱动重载后设备枚举有延迟，重试等待就绪
    for (int i = 0; i < 10 && e.virtualDev == kAudioObjectUnknown; ++i) {
        peq_dbg("[peq] VfdPEQ not enumerated yet, retrying (%d/10)...", i + 1);
        std::this_thread::sleep_for(std::chrono::seconds(1));
        e.virtualDev = findDeviceByName("VfdPEQ 2ch");
    }
    if (e.virtualDev == kAudioObjectUnknown) {
        fprintf(stderr, "ERROR: VfdPEQ 2ch device not found. Is the driver installed?\n");
        return 1;
    }
    Float64 vRate = deviceSampleRate(e.virtualDev);

    // ---- pick real output device: conf output_name > argv[2] > interactive ----
    AudioDeviceID realDev = kAudioObjectUnknown;
    std::string confOutput;
    {
        auto pre = loadConfig(e.confPath.c_str(), (int)vRate);
        if (pre) confOutput = pre->outputName;
    }
    if (argc > 2) {
        realDev = findDeviceByName(argv[2]);
        if (realDev == kAudioObjectUnknown) {
            peq_dbg("[peq] output device '%s' not found, showing picker", argv[2]);
        }
    }
    if (realDev == kAudioObjectUnknown && !confOutput.empty()) {
        realDev = findDeviceByName(confOutput);
        if (realDev != kAudioObjectUnknown)
            peq_dbg("[peq] output device from config: '%s'", confOutput.c_str());
        else
            peq_dbg("[peq] output device '%s' (from config) not found, showing picker",confOutput.c_str());
    }
    // 配置设备彻底不可用时：降级到第一个可用输出（通常内建扬声器），保证引擎总能启动。
    // 运行期失联的降级语义与此一致（fallbackOutputDevice）。
    if (realDev == kAudioObjectUnknown) {
        for (auto d : allDevices()) {
            if (d == e.virtualDev || !hasOutputStream(d)) continue;
            if (transportType(d) == kAudioDeviceTransportTypeVirtual) continue;
            realDev = d;
            peq_dbg("[peq] falling back to first available output: '%s'",deviceName(d).c_str());
            break;
        }
    }
    if (realDev == kAudioObjectUnknown)
        realDev = pickOutputDeviceInteractive(e.virtualDev);
    if (realDev == kAudioObjectUnknown) {
        fprintf(stderr, "ERROR: no output device selected\n");
        return 1;
    }
    e.realDev = realDev;   // 尽早赋值：writeEngineStatus 等下游都依赖它
    e.curOutputName = deviceName(realDev);
    Float64 rRate = deviceSampleRate(realDev);
    fprintf(stderr, "\n[peq] VfdPEQ @ %.0f Hz  ->  '%s' @ %.0f Hz\n",
            vRate, deviceName(realDev).c_str(), rRate);

    // 把 VfdPEQ 标称采样率对齐到真实设备：消除音调偏移和环形缓冲漂移丢帧
    if (vRate != rRate) {
        if (alignVirtualRate(e, rRate)) {
            vRate = deviceSampleRate(e.virtualDev);
            peq_dbg("[peq] VfdPEQ nominal rate set to %.0f Hz (matched output)", vRate);
        } else {
            peq_dbg("[peq] WARNING: cannot change VfdPEQ rate to %.0f Hz", rRate);
        }
    }

    // status file for the GUI (device binding + volume sliders)
    writeEngineStatus(e, vRate, rRate);
    if (vRate != rRate)
        peq_dbg("[peq] WARNING: sample rates differ; expect pitch/speed artifacts");

    // ---- initial config ----
    struct stat st{};
    if (stat(e.confPath.c_str(), &st) == 0) e.confMtime = st.st_mtime;
    e.setCfg(loadConfig(e.confPath.c_str(), (int)vRate));
    auto initCfg = e.getCfg();
    if (!initCfg) {
        peq_dbg("[peq] WARNING: %s not found, starting bypass (0 bands)", e.confPath.c_str());
        auto bypass = std::make_shared<PEQConfig>();
        bypass->sampleRate = (int)vRate;
        e.setCfg(bypass);
        initCfg = e.getCfg();
    } else {
        peq_dbg("[peq] loaded L=%zu R=%zu bands from %s (lr=%d)",initCfg->bands[0].size(), initCfg->bands[1].size(), e.confPath.c_str(), (int)initCfg->lrMode);
    }
    for (auto& p : e.peq) p.prepare(e.getCfg(), kChannels);

    // shared-memory spectrum feed for the GUI (best-effort)
    e.shm = shmring::ShmFrameRing::create("/vfdpeq_audio", kChannels, (uint32_t)vRate, 1 << 16);
    if (!e.shm) peq_dbg("[peq] WARNING: shm create failed, GUI spectrum unavailable");

    // ---- output: IOProc directly on the chosen real device (no AudioUnit ambiguity) ----
    // ⚠️ realDev 必须写入 e.realDev：rebind 的停/销毁旧回调都依赖它
    e.realDev = realDev;
    if (AudioDeviceCreateIOProcID(realDev, outputDeviceProc, &e, &e.outProc) != noErr) {
        fprintf(stderr, "ERROR: cannot create IOProc on output device\n");
        return 1;
    }
    if (AudioDeviceStart(realDev, e.outProc) != noErr) { fprintf(stderr, "ERROR: cannot start output IOProc\n"); return 1; }

    // ---- input: IOProc on VfdPEQ device ----
    if (AudioDeviceCreateIOProcID(e.virtualDev, inputProc, &e, &e.inProc) != noErr) {
        fprintf(stderr, "ERROR: cannot create IOProc on VfdPEQ\n");
        return 1;
    }
    if (AudioDeviceStart(e.virtualDev, e.inProc) != noErr) { fprintf(stderr, "ERROR: cannot start IOProc\n"); return 1; }
    peq_dbg("IO started: virtualDev=0x%x realDev=0x%x (%s)",   // debug
            (unsigned)e.virtualDev, (unsigned)e.realDev, deviceName(e.realDev).c_str());

    installDevicesListener(e);
    peq_dbg("[peq] engine running. Ctrl+C to stop. Editing %s hot-reloads.", e.confPath.c_str());

    // Ctrl+C / SIGTERM -> graceful shutdown (release devices + shm unlink)
    static std::atomic<bool>* stopFlag = &e.running;
    signal(SIGINT,  [](int){ stopFlag->store(false); });
    signal(SIGTERM, [](int){ stopFlag->store(false); });

    // debug: main loop 0.2s tick — hot-reload + device management all here (non-RT thread)
    int hbCount = 0;
    while (e.running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        // ① hot-reload config (IOProc 只置标志，重量级操作在此执行)
        if (e.confReloadRequested.exchange(false)) {
            struct stat st{};
            if (stat(e.confPath.c_str(), &st) == 0 && st.st_mtime != e.confMtime) {
                e.confMtime = st.st_mtime;
                peq_dbg("hot-reload: loadConfig begin");   // debug
                if (auto cfg = loadConfig(e.confPath.c_str(), (int)deviceSampleRate(e.virtualDev))) {
                    for (auto& p : e.peq) p.prepare(cfg, kChannels);
                    e.setCfg(cfg);
                    peq_dbg("hot-reload: config reloaded (L=%zu R=%zu lr=%d preamp=%.1f/%.1f bypass=%d)",
                            cfg->bands[0].size(), cfg->bands[1].size(), (int)cfg->lrMode,
                            cfg->preampDb[0], cfg->preampDb[1], (int)cfg->bypass);
                    if (!cfg->outputName.empty() && cfg->outputName != e.curOutputName) {
                        peq_dbg("hot-reload: output target changed -> rebind");   // debug
                        e.rebindOutput.store(true);
                    }
                } else {
                    peq_dbg("hot-reload: loadConfig returned NULL");   // debug
                }
            }
        }
        // ② 设备失联降级（拔出耳机 → 自动切到可用输出）
        if (e.devicesChanged.exchange(false)) {
            if (time(NULL) - e.lastRebindAt.load() < 3) {
                peq_dbg("skip lost-device check: within rebind suppression window");   // debug
            } else if (e.realDev != kAudioObjectUnknown &&
                       findDeviceByName(deviceName(e.realDev)) == kAudioObjectUnknown) {
                fallbackOutputDevice(e);
            }
        }
        // ③ rebind（conf 的 output_name 变化 → 引擎热切换输出设备）
        if (e.rebindOutput.exchange(false)) rebindOutputDevice(e);
        // ④ heartbeat（每 10 拍 = 2s 一条）+ stats
        if (++hbCount % 10 != 0) continue;
        static uint64_t lastIn = 0, lastInF = 0, lastOutU = 0, lastOutCB = 0;
        uint64_t inCB   = e.inCB.load();
        uint64_t inF    = e.inFramesGot.load();
        uint64_t dropF  = e.inFramesDropped.load();
        uint64_t outU   = e.outUnderrunFrames.load();
        uint64_t outCBn = e.outCB.load();
        float inPk      = e.inPeak.exchange(0.0f, std::memory_order_relaxed);
        float outPk     = e.outPeak.exchange(0.0f, std::memory_order_relaxed);
        peq_dbg("hb: inCB=%llu(+%llu) drop=%llu underrun=%llu(+%llu) | outCB=%llu(+%llu) peak: in=%.4f out=%.4f",
                (unsigned long long)inCB, (unsigned long long)(inCB - lastIn),
                (unsigned long long)dropF,
                (unsigned long long)outU, (unsigned long long)(outU - lastOutU),
                (unsigned long long)outCBn, (unsigned long long)(outCBn - lastOutCB),
                inPk, outPk);
        lastIn = inCB; lastInF = inF; lastOutU = outU; lastOutCB = outCBn;
    }

    AudioDeviceStop(e.virtualDev, e.inProc);
    AudioDeviceDestroyIOProcID(e.virtualDev, e.inProc);
    AudioDeviceStop(e.realDev, e.outProc);
    AudioDeviceDestroyIOProcID(e.realDev, e.outProc);
    if (e.shm) e.shm->destroy();
    peq_dbg("[peq] bye");
    return 0;
}
