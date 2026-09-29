// EQ state + composite/band frequency-response computation (for the FR plot)
#pragma once
#include "../engine/biquad.hpp"
#include "../common/peq_conf.hpp"
#include <cmath>
#include <vector>

struct FRData {
    std::vector<float> freqs;
    std::vector<float> comp;
    std::vector<std::vector<float>> perBand;
};

inline void computeFR(const std::vector<peqconf::Band>& bands, double fs, FRData& out) {
    constexpr int N = 220;
    out.freqs.resize(N);
    for (int i = 0; i < N; ++i)
        out.freqs[i] = (float)(20.0 * std::pow(1000.0, (double)i / (N - 1)));
    out.comp.assign(N, 0.0f);
    out.perBand.assign(bands.size(), {});

    for (size_t b = 0; b < bands.size(); ++b) {
        out.perBand[b].assign(N, 0.0f);
        if (!bands[b].enabled) continue;
        BandParams p{bands[b].enabled, bands[b].type, bands[b].freq, bands[b].gainDB, bands[b].q};
        const BiquadCoeffs c = BiquadCoeffs::design(p, fs);
        for (int i = 0; i < N; ++i) {
            const double w = 2.0 * M_PI * out.freqs[i] / fs;
            const double zr = std::cos(w),  zi = -std::sin(w);   // z^-1
            const double z2r = std::cos(2*w), z2i = -std::sin(2*w);
            const double nr = c.b0 + c.b1 * zr + c.b2 * z2r;
            const double ni = c.b1 * zi + c.b2 * z2i;
            const double dr = 1.0 + c.a1 * zr + c.a2 * z2r;
            const double di = c.a1 * zi + c.a2 * z2i;
            const double mag = std::sqrt((nr*nr + ni*ni) / (dr*dr + di*di));
            const double db = 20.0 * std::log10(std::max(mag, 1e-9));
            out.perBand[b][i] = (float)db;
            out.comp[i] += (float)db;
        }
    }
}
