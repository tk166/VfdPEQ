// Shared PEQ config file format (used by GUI; engine's engine/config.hpp parses the same)
// Line format:  type freq gainDB q enabled      (type: lowshelf|peaking|highshelf)
// Global line:  bypass 0|1                      (optional; missing = EQ active)
#pragma once
#include "../engine/biquad.hpp"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace peqconf {

struct Band {
    bool   enabled = true;
    FilterType type = FilterType::Peaking;
    double freq   = 1000.0;
    double gainDB = 0.0;
    double q      = 1.0;
};

inline std::vector<Band> load(const char* path, bool* bypass = nullptr) {
    std::vector<Band> out;
    if (bypass) *bypass = false;
    FILE* f = fopen(path, "r");
    if (!f) return out;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\0') continue;
        if (strncmp(line, "bypass", 6) == 0) {
            int v = 0;
            if (sscanf(line + 6, "%d", &v) == 1 && bypass) *bypass = (v != 0);
            continue;
        }
        char type[32] = "";
        double freq = 0, gain = 0, q = 1.0;
        int enabled = 1;
        if (sscanf(line, "%31s %lf %lf %lf %d", type, &freq, &gain, &q, &enabled) < 3) continue;
        Band b;
        b.enabled = enabled != 0;
        b.freq    = freq;
        b.gainDB  = gain;
        b.q       = q > 0.05 ? q : 0.05;
        if      (strcmp(type, "lowshelf")  == 0) b.type = FilterType::LowShelf;
        else if (strcmp(type, "highshelf") == 0) b.type = FilterType::HighShelf;
        else                                     b.type = FilterType::Peaking;
        out.push_back(b);
    }
    fclose(f);
    return out;
}

inline bool save(const char* path, const std::vector<Band>& bands, bool bypass = false) {
    FILE* f = fopen(path, "w");
    if (!f) return false;
    fprintf(f, "# SystemPEQ config - hot-reloaded by the engine\n");
    fprintf(f, "# format: type freq gainDB q enabled | global: bypass 0|1\n");
    fprintf(f, "bypass %d\n", bypass ? 1 : 0);
    for (const auto& b : bands) {
        fprintf(f, "%-9s %8.1f %6.2f %5.2f %d\n",
                b.type == FilterType::LowShelf ? "lowshelf" :
                b.type == FilterType::HighShelf ? "highshelf" : "peaking",
                b.freq, b.gainDB, b.q, b.enabled ? 1 : 0);
    }
    fclose(f);
    return true;
}

} // namespace peqconf
