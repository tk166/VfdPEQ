// SystemPEQ engine — RBJ cookbook biquad cascade
#pragma once
#include <cmath>
#include <vector>

enum class FilterType { LowShelf, Peaking, HighShelf };

struct BandParams {
    bool       enabled = true;
    FilterType type    = FilterType::Peaking;
    double     freq    = 1000.0;
    double     gainDB  = 0.0;
    double     q       = 1.0;
};

struct PEQConfig {
    int      sampleRate = 48000;
    bool     bypass     = false;   // EQ 总开关：true 时全部直通（含 preamp）
    bool     lrMode     = false;   // true = L/R 声道独立 EQ；false = L=R
    float    preampDb[2] = {0, 0}; // per-channel preamp（L=R 时只用 [0]）
    std::string outputName;          // 真实输出设备名（空 = 交互选择；变化触发热切换）
    std::vector<BandParams> bands[2]; // [0]=L，[1]=R（lrMode 时有效）
};

// Per-channel biquad state
struct BiquadState {
    double x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
};

struct BiquadCoeffs {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;

    static BiquadCoeffs design(const BandParams& p, double fs) {
        BiquadCoeffs c;
        if (p.freq <= 0.0 || p.freq >= fs * 0.5) return c; // identity
        double w0 = 2.0 * M_PI * p.freq / fs;
        double cw = std::cos(w0), sw = std::sin(w0);
        double A, alpha, a0;

        if (p.type == FilterType::Peaking) {
            A     = std::pow(10.0, p.gainDB / 40.0);
            alpha = sw / (2.0 * p.q);
            c.b0 = 1.0 + alpha * A;
            c.b1 = -2.0 * cw;
            c.b2 = 1.0 - alpha * A;
            a0        = 1.0 + alpha / A;
            c.a1      = -2.0 * cw;
            c.a2      = 1.0 - alpha / A;
        } else {
            // Low/High shelf (Q -> S via sqrt(A) slope compromise, RBJ shelf w/ Q)
            A     = std::pow(10.0, p.gainDB / 40.0);
            alpha = sw / (2.0 * p.q);
            double twoSqrtAalpha = 2.0 * std::sqrt(A) * alpha;
            if (p.type == FilterType::LowShelf) {
                c.b0 =        A * ((A + 1.0) - (A - 1.0) * cw + twoSqrtAalpha);
                c.b1 =  2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
                c.b2 =        A * ((A + 1.0) - (A - 1.0) * cw - twoSqrtAalpha);
                a0   =             (A + 1.0) + (A - 1.0) * cw + twoSqrtAalpha;
                c.a1 =   -2.0    * ((A - 1.0) + (A + 1.0) * cw);
                c.a2 =             (A + 1.0) + (A - 1.0) * cw - twoSqrtAalpha;
            } else {
                c.b0 =        A * ((A + 1.0) + (A - 1.0) * cw + twoSqrtAalpha);
                c.b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
                c.b2 =        A * ((A + 1.0) + (A - 1.0) * cw - twoSqrtAalpha);
                a0   =             (A + 1.0) - (A - 1.0) * cw + twoSqrtAalpha;
                c.a1 =    2.0    * ((A - 1.0) - (A + 1.0) * cw);
                c.a2 =             (A + 1.0) - (A - 1.0) * cw - twoSqrtAalpha;
            }
        }
        c.b0 /= a0; c.b1 /= a0; c.b2 /= a0; c.a1 /= a0; c.a2 /= a0;
        return c;
    }
};

// Cascade of biquads for one channel
class PEQChannel {
public:
    void prepare(const std::shared_ptr<const PEQConfig>& cfg, int channels) {
        std::lock_guard<std::mutex> lk(m_);
        if (cfg) { cfg_ = cfg; }
        if (!cfg_) return;
        nCh_ = channels;
        // per-channel 链：L/R 模式下两声道各自用 bands[0]/bands[1]，band 数可不同
        preampGain_.assign(channels, 1.0f);
        coeffs_.assign(channels, {});
        states_.assign(channels, {});
        for (int ch = 0; ch < channels; ++ch) {
            const int src = cfg_->lrMode ? ch : 0;
            preampGain_[ch] = std::pow(10.0f, cfg_->preampDb[src] / 20.0f);
            for (const auto& b : cfg_->bands[src])
                coeffs_[ch].push_back((cfg_->bypass || !b.enabled)
                                          ? BiquadCoeffs{}   // 默认系数 = 恒等（直通）
                                          : BiquadCoeffs::design(b, cfg_->sampleRate));
            states_[ch].assign(coeffs_[ch].size(), {});
        }
    }

    // inPlace: interleaved buffer frame by frame
    void processInterleaved(float* data, size_t frames, int channels) {
        std::lock_guard<std::mutex> lk(m_);
        if (!cfg_) return;
        if (cfg_->bypass) return;   // 总开关旁路：含 preamp 完全直通
        for (size_t f = 0; f < frames; ++f) {
            for (int ch = 0; ch < channels && ch < nCh_; ++ch) {
                double s = (double)data[f * channels + ch] * (double)preampGain_[ch];
                const auto& cs = coeffs_[ch];
                auto& st = states_[ch];
                for (size_t bi = 0; bi < cs.size(); ++bi) {
                    const BiquadCoeffs& c = cs[bi];
                    double y = c.b0 * s + c.b1 * st[bi].x1 + c.b2 * st[bi].x2
                             - c.a1 * st[bi].y1 - c.a2 * st[bi].y2;
                    st[bi].x2 = st[bi].x1; st[bi].x1 = s;
                    st[bi].y2 = st[bi].y1; st[bi].y1 = y;
                    s = y;
                }
                data[f * channels + ch] = static_cast<float>(s);
            }
        }
    }

private:
    std::mutex                                      m_;
    std::shared_ptr<const PEQConfig>                cfg_;
    std::vector<float>                              preampGain_;          // per ch
    std::vector<std::vector<BiquadCoeffs>>          coeffs_;              // per ch per band
    std::vector<std::vector<BiquadState>>           states_;              // per ch per band
    int                                             nCh_ = 2;
};
