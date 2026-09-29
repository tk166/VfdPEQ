// SystemPEQ engine, Stage 2
//   SystemPEQ virtual device --(device IOProc)--> ring buffer --(biquad PEQ)--> real output
//
// Usage:
//   1. Set system output to "SystemPEQ 2ch"
//   2. ./build/peq_engine [peq.conf path] [output device name]
//      - if no output device given, an interactive picker is shown:
//        press Enter to accept the suggested device, or type its number
//   3. Edit peq.conf while running; settings hot-reload (~1s)
#include <AudioToolbox/AudioToolbox.h>
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

static constexpr size_t kRingCapacity = 1 << 15; // 32768 frames ~= 0.68s @48k
static constexpr int    kChannels     = 2;

struct Engine {
    FrameRingBuffer      rb{kRingCapacity, kChannels};
    PEQChannel           peq[kChannels];
    std::atomic<bool>    running{true};
    std::string          confPath;
    std::shared_ptr<const PEQConfig> cfg;
    time_t               confMtime  = 0;
    int                  reloadTick = 0;
    AudioDeviceID        virtualDev = kAudioObjectUnknown;
    AudioDeviceID        realDev    = kAudioObjectUnknown;
    AudioDeviceIOProcID  inProc     = nullptr;
    AudioDeviceIOProcID  outProc    = nullptr;
    shmring::ShmFrameRing* shm      = nullptr;   // spectrum feed for the GUI
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

// ---------- input side: SystemPEQ device IOProc ----------
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
    if (++e->reloadTick >= 90) {
        e->reloadTick = 0;
        struct stat st{};
        if (stat(e->confPath.c_str(), &st) == 0 && st.st_mtime != e->confMtime) {
            e->confMtime = st.st_mtime;
            if (auto cfg = loadConfig(e->confPath.c_str(), (int)deviceSampleRate(e->virtualDev))) {
                for (auto& p : e->peq) p.prepare(cfg, kChannels);
                fprintf(stderr, "[peq] config reloaded (%zu bands, bypass=%d)\n",
                        cfg->bands.size(), (int)cfg->bypass);
            }
        }
    }
    return noErr;
}

int main(int argc, char** argv) {
    Engine e;
    e.confPath = argc > 1 ? argv[1] : "peq.conf";

    e.virtualDev = findDeviceByName("SystemPEQ 2ch");
    if (e.virtualDev == kAudioObjectUnknown) {
        fprintf(stderr, "ERROR: SystemPEQ 2ch device not found. Is the driver installed?\n");
        return 1;
    }
    Float64 vRate = deviceSampleRate(e.virtualDev);

    // ---- pick real output device (interactive unless given via argv[2]) ----
    AudioDeviceID realDev = kAudioObjectUnknown;
    if (argc > 2) {
        realDev = findDeviceByName(argv[2]);
        if (realDev == kAudioObjectUnknown) {
            fprintf(stderr, "[peq] output device '%s' not found, showing picker\n", argv[2]);
        }
    }
    if (realDev == kAudioObjectUnknown)
        realDev = pickOutputDeviceInteractive(e.virtualDev);
    if (realDev == kAudioObjectUnknown) {
        fprintf(stderr, "ERROR: no output device selected\n");
        return 1;
    }
    Float64 rRate = deviceSampleRate(realDev);
    fprintf(stderr, "\n[peq] SystemPEQ @ %.0f Hz  ->  '%s' @ %.0f Hz\n",
            vRate, deviceName(realDev).c_str(), rRate);

    // 把 SystemPEQ 标称采样率对齐到真实设备：消除音调偏移和环形缓冲漂移丢帧
    if (vRate != rRate) {
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate,
                                         kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        Float64 want = rRate;
        UInt32 wsz = sizeof(want);
        OSStatus rerr = AudioObjectSetPropertyData(e.virtualDev, &ra, 0, nullptr, wsz, &want);
        if (rerr == noErr) {
            vRate = deviceSampleRate(e.virtualDev);
            fprintf(stderr, "[peq] SystemPEQ nominal rate set to %.0f Hz (matched output)\n", vRate);
        } else {
            fprintf(stderr, "[peq] WARNING: cannot change SystemPEQ rate to %.0f Hz (err %d)\n", rRate, rerr);
        }
    }

    // status file for the GUI (device binding + volume sliders)
    {
        std::string dir = ".";
        const size_t slash = e.confPath.find_last_of('/');
        if (slash != std::string::npos) dir = e.confPath.substr(0, slash);
        FILE* sf = fopen((dir + "/engine.status").c_str(), "w");
        if (sf) {
            fprintf(sf, "output_name=%s\noutput_rate=%.0f\nvirtual_rate=%.0f\n",
                    deviceName(realDev).c_str(), rRate, vRate);
            fclose(sf);
        }
    }
    if (vRate != rRate)
        fprintf(stderr, "[peq] WARNING: sample rates differ; expect pitch/speed artifacts\n");

    // ---- initial config ----
    struct stat st{};
    if (stat(e.confPath.c_str(), &st) == 0) e.confMtime = st.st_mtime;
    e.cfg = loadConfig(e.confPath.c_str(), (int)vRate);
    if (!e.cfg) {
        fprintf(stderr, "[peq] WARNING: %s not found, starting bypass (0 bands)\n", e.confPath.c_str());
        auto bypass = std::make_shared<PEQConfig>();
        bypass->sampleRate = (int)vRate;
        e.cfg = bypass;
    } else {
        fprintf(stderr, "[peq] loaded %zu bands from %s\n", e.cfg->bands.size(), e.confPath.c_str());
    }
    for (auto& p : e.peq) p.prepare(e.cfg, kChannels);

    // shared-memory spectrum feed for the GUI (best-effort)
    e.shm = shmring::ShmFrameRing::create("/systempeq_audio", kChannels, (uint32_t)vRate, 1 << 16);
    if (!e.shm) fprintf(stderr, "[peq] WARNING: shm create failed, GUI spectrum unavailable\n");

    // ---- output: IOProc directly on the chosen real device (no AudioUnit ambiguity) ----
    if (AudioDeviceCreateIOProcID(realDev, outputDeviceProc, &e, &e.outProc) != noErr) {
        fprintf(stderr, "ERROR: cannot create IOProc on output device\n");
        return 1;
    }
    if (AudioDeviceStart(realDev, e.outProc) != noErr) { fprintf(stderr, "ERROR: cannot start output IOProc\n"); return 1; }

    // ---- input: IOProc on SystemPEQ device ----
    if (AudioDeviceCreateIOProcID(e.virtualDev, inputProc, &e, &e.inProc) != noErr) {
        fprintf(stderr, "ERROR: cannot create IOProc on SystemPEQ\n");
        return 1;
    }
    if (AudioDeviceStart(e.virtualDev, e.inProc) != noErr) { fprintf(stderr, "ERROR: cannot start IOProc\n"); return 1; }

    fprintf(stderr, "[peq] engine running. Ctrl+C to stop. Editing %s hot-reloads.\n", e.confPath.c_str());

    // Ctrl+C / SIGTERM -> graceful shutdown (release devices + shm unlink)
    static std::atomic<bool>* stopFlag = &e.running;
    signal(SIGINT,  [](int){ stopFlag->store(false); });
    signal(SIGTERM, [](int){ stopFlag->store(false); });

    // debug stats thread
    uint64_t lastIn = 0, lastInF = 0, lastOutU = 0, lastOutCB = 0;
    while (e.running) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        uint64_t inCB   = e.inCB.load();
        uint64_t inF    = e.inFramesGot.load();
        uint64_t dropF  = e.inFramesDropped.load();
        uint64_t outU   = e.outUnderrunFrames.load();
        uint64_t outCBn = e.outCB.load();
        float inPk      = e.inPeak.exchange(0.0f, std::memory_order_relaxed);
        float outPk     = e.outPeak.exchange(0.0f, std::memory_order_relaxed);
        fprintf(stderr, "[dbg] inCB=%llu(+%llu) frames=%llu(+%llu) drop=%llu underrun=%llu(+%llu) | outCB=%llu(+%llu) peak: in=%.4f out=%.4f\n",
                (unsigned long long)inCB, (unsigned long long)(inCB - lastIn),
                (unsigned long long)inF, (unsigned long long)(inF - lastInF),
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
    fprintf(stderr, "[peq] bye\n");
    return 0;
}
