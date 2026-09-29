// Line-based PEQ config:
//   "# L=R" | "# L/R"         channel mode (missing = L=R)
//   bypass 0|1                EQ master bypass
//   preamp <dB>               L (or global in L=R) preamp
//   preampR <dB>              R preamp (L/R mode only)
//   output_name <name...>     real output device (may contain spaces; optional)
//   channel L | channel R     following bands belong to that channel (L/R mode)
//   <type> <freq> <gain> <q> <enabled>      band line
// Hot-reloaded by the engine when the file changes.
#pragma once
#include "biquad.hpp"
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>

inline void trimInPlace(std::string& s) {
    const char* ws = " \t\r\n";
    size_t b = s.find_first_not_of(ws);
    size_t e = s.find_last_not_of(ws);
    s = (b == std::string::npos) ? "" : s.substr(b, e - b + 1);
}

inline std::shared_ptr<const PEQConfig> loadConfig(const char* path, int sampleRate) {
    FILE* f = fopen(path, "r");
    if (!f) return nullptr;

    auto cfg = std::make_shared<PEQConfig>();
    cfg->sampleRate = sampleRate;
    int cur = 0;   // current channel sink for band lines

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#') {
            if (strncmp(line, "# L/R", 5) == 0) cfg->lrMode = true;
            else if (strncmp(line, "# L=R", 5) == 0) cfg->lrMode = false;
            continue;
        }
        if (line[0] == '\n' || line[0] == '\0') continue;

        if (strncmp(line, "bypass", 6) == 0) {
            int v = 0;
            if (sscanf(line + 6, "%d", &v) == 1) cfg->bypass = (v != 0);
            continue;
        }
        if (strncmp(line, "preampR", 7) == 0) {
            float v = 0;
            if (sscanf(line + 7, "%f", &v) == 1) cfg->preampDb[1] = v;
            continue;
        }
        if (strncmp(line, "preamp", 6) == 0) {
            float v = 0;
            if (sscanf(line + 6, "%f", &v) == 1) cfg->preampDb[0] = v;
            continue;
        }
        if (strncmp(line, "output_name", 11) == 0) {
            std::string s = line + 11;
            trimInPlace(s);
            cfg->outputName = s;
            continue;
        }
        if (strncmp(line, "channel", 7) == 0) {
            char side[8] = "";
            if (sscanf(line + 7, "%7s", side) == 1) cur = (side[0] == 'R' || side[0] == 'r') ? 1 : 0;
            continue;
        }

        char type[32] = "";
        double freq = 0, gain = 0, q = 1.0;
        int enabled = 1;
        if (sscanf(line, "%31s %lf %lf %lf %d", type, &freq, &gain, &q, &enabled) < 3) continue;

        BandParams b;
        b.enabled = enabled != 0;
        b.freq    = freq;
        b.gainDB  = gain;
        b.q       = q > 0.05 ? q : 0.05;
        if      (strcmp(type, "lowshelf")  == 0) b.type = FilterType::LowShelf;
        else if (strcmp(type, "highshelf") == 0) b.type = FilterType::HighShelf;
        else                                     b.type = FilterType::Peaking;
        cfg->bands[cur].push_back(b);
    }
    fclose(f);
    // L=R 模式统一化：R 侧镜像 L（引擎只读 [0]，但保持语义一致）
    if (!cfg->lrMode) cfg->bands[1] = cfg->bands[0];
    return cfg;
}
