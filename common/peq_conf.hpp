// Shared PEQ config file format (used by GUI; engine's engine/config.hpp parses the same)
//
//   "# L=R" | "# L/R"         channel mode comment (missing = L=R)
//   bypass 0|1                EQ master bypass
//   preamp <dB>               L (or global in L=R) preamp
//   preampR <dB>              R preamp (L/R mode)
//   output_name <name...>     real output device (may contain spaces)
//   channel L | channel R     band lines belong to that channel (L/R mode)
//   <type> <freq> <gain> <q> <enabled>      band line
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

struct Conf {
    bool bypass = false;
    bool lrMode = false;               // true = L/R independent
    float preampDb[2] = {0.0f, 0.0f};
    std::string outputName;            // real output device (engine hot-switches on change)
    std::vector<Band> ch[2];           // [0]=L, [1]=R (mirror of L in L=R mode)
    int hueIdx = 0;                    // GUI: phosphor theme index (persisted for restarts)
    int rngIdx = 3;                    // GUI: FR y-axis range index (±24dB default)
};

inline void trimInPlace(std::string& s) {
    const char* ws = " \t\r\n";
    size_t b = s.find_first_not_of(ws);
    size_t e = s.find_last_not_of(ws);
    s = (b == std::string::npos) ? "" : s.substr(b, e - b + 1);
}

inline Conf load(const char* path) {
    Conf c;
    FILE* f = fopen(path, "r");
    if (!f) return c;
    int cur = 0;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#') {
            if (strncmp(line, "# L/R", 5) == 0) c.lrMode = true;
            else if (strncmp(line, "# L=R", 5) == 0) c.lrMode = false;
            continue;
        }
        if (line[0] == '\n' || line[0] == '\0') continue;
        if (strncmp(line, "bypass", 6) == 0) {
            int v = 0;
            if (sscanf(line + 6, "%d", &v) == 1) c.bypass = (v != 0);
            continue;
        }
        if (strncmp(line, "preampR", 7) == 0) {
            float v = 0;
            if (sscanf(line + 7, "%f", &v) == 1) c.preampDb[1] = v;
            continue;
        }
        if (strncmp(line, "preamp", 6) == 0) {
            float v = 0;
            if (sscanf(line + 6, "%f", &v) == 1) c.preampDb[0] = v;
            continue;
        }
        if (strncmp(line, "output_name", 11) == 0) {
            std::string s = line + 11;
            trimInPlace(s);
            c.outputName = s;
            continue;
        }
        if (strncmp(line, "hue", 3) == 0) {
            int v = 0;
            if (sscanf(line + 3, "%d", &v) == 1) c.hueIdx = v;
            continue;
        }
        if (strncmp(line, "rng", 3) == 0) {
            int v = 0;
            if (sscanf(line + 3, "%d", &v) == 1) c.rngIdx = v;
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
        Band b;
        b.enabled = enabled != 0;
        b.freq    = freq;
        b.gainDB  = gain;
        b.q       = q > 0.05 ? q : 0.05;
        if      (strcmp(type, "lowshelf")  == 0) b.type = FilterType::LowShelf;
        else if (strcmp(type, "highshelf") == 0) b.type = FilterType::HighShelf;
        else                                     b.type = FilterType::Peaking;
        c.ch[cur].push_back(b);
    }
    fclose(f);
    if (!c.lrMode) c.ch[1] = c.ch[0];
    return c;
}

inline bool save(const char* path, const Conf& c) {
    FILE* f = fopen(path, "w");
    if (!f) return false;
    fprintf(f, "# SystemPEQ config - hot-reloaded by the engine\n");
    fprintf(f, c.lrMode ? "# L/R\n" : "# L=R\n");
    fprintf(f, "bypass %d\n", c.bypass ? 1 : 0);
    fprintf(f, "preamp %.2f\n", c.preampDb[0]);
    if (c.lrMode) fprintf(f, "preampR %.2f\n", c.preampDb[1]);
    if (!c.outputName.empty()) fprintf(f, "output_name %s\n", c.outputName.c_str());
    fprintf(f, "hue %d\n", c.hueIdx);
    fprintf(f, "rng %d\n", c.rngIdx);
    const int last = c.lrMode ? 1 : 0;
    for (int side = 0; side <= last; ++side) {
        if (c.lrMode) fprintf(f, "channel %s\n", side == 0 ? "L" : "R");
        for (const auto& b : c.ch[side]) {
            fprintf(f, "%-9s %8.1f %6.2f %5.2f %d\n",
                    b.type == FilterType::LowShelf ? "lowshelf" :
                    b.type == FilterType::HighShelf ? "highshelf" : "peaking",
                    b.freq, b.gainDB, b.q, b.enabled ? 1 : 0);
        }
    }
    fclose(f);
    return true;
}

} // namespace peqconf
