// vfd_render.h —— VFD 点阵荧光频谱渲染器（C++ 版，零依赖）
//
// 这是 vfd_spectrum.py 那套视觉逻辑的移植，目标有两条：
//   1) EAPO 插件的**面板**要在配置编辑器进程里把频谱画出来（数据是靠命名管道
//      从 audiodg 侧的实例送过来的）；
//   2) 同一份渲染逻辑将来给 ESP32-P4 复用（所以刻意不依赖 JUCE / Win32）。
//
// 与 Python 参考实现一致的关键点：
//   * 点阵单元 cell×cell 里只点亮左上 dot×dot，形成"点阵屏"观感
//   * 亮度层级 V_* 与磷光调色板 PHOSPHOR_STOPS 逐项照搬
//   * 柱体竖直渐变（柱底幽暗→柱顶炽亮）+ 峰值帽（每列一个点，始终绘制）
//   * 磷光暂留 p_t = beta*p_target + (1-beta)*p_{t-1}，逐"点阵像素"
//   * 输出前做两级 box blur 泛光 + 暗角 + 调色板查表

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace vfdrender {

// ---------------------------------------------------------------- 常量(与 Python 对齐)
constexpr float V_OFF        = 0.030f;
constexpr float V_GRID       = 0.075f;
constexpr float V_GRID_MAJOR = 0.145f;
constexpr float V_AXIS       = 0.230f;
constexpr float V_TICK       = 0.280f;
constexpr float V_LABEL      = 0.520f;
constexpr float V_TITLE      = 0.720f;
constexpr float V_READOUT    = 1.000f;
constexpr float V_STATUS     = 0.400f;
constexpr float V_BEZEL      = 0.200f;
constexpr float V_PEAK       = 1.000f;
// 声量计/峰值计：峰值条主体压暗（"叠加在下面"），条头与频谱 peak 帽同亮
constexpr float V_METER_BODY = 0.240f;
constexpr float V_METER_TIP  = V_PEAK;
// 声量计/峰值计的计量下限（dBFS），底部那条横向刻度也用它
constexpr float kMeterDbMin  = -60.0f;

constexpr int kGlyphW = 3;
constexpr int kGlyphH = 5;
constexpr int kLutSize = 512;

struct RgbF { float r, g, b; };
struct Stop { float t; RgbF c; };

// ---- 主题配色 ---------------------------------------------------------------
// 一个主题 = 一组 (强度 -> RGB) 节点。点阵屏的观感几乎全由这张表决定：
//   低端越暗越"干净"（黑底不发光），高端越泛白越像"过驱动的荧光粉"。
// 依次单击点阵屏就按这个顺序循环（与 vfd_spectrum.py 的调色板同源的排在最前面）。
enum class Theme { yellowGreen = 0, deepGreen, blue, pink, orange };
constexpr int kThemeCount = 5;

inline const char* themeName(Theme t) {
    switch (t) {
        case Theme::yellowGreen: return "yellow-green";
        case Theme::deepGreen:   return "deep-green";
        case Theme::blue:        return "blue";
        case Theme::pink:        return "pink";
        case Theme::orange:      return "orange";
    }
    return "?";
}

// 想加主题：在 enum、themeName、这里各加一项，kThemeCount +1 即可。
inline const Stop* stopsTable(Theme t, int& count) {
    static const Stop kYellowGreen[] = {   // 与 vfd_spectrum.py 的 PHOSPHOR_STOPS 逐项相同
        {0.00f, {0.008f, 0.028f, 0.022f}},
        {0.10f, {0.030f, 0.180f, 0.130f}},
        {0.30f, {0.070f, 0.480f, 0.320f}},
        {0.55f, {0.180f, 0.820f, 0.550f}},
        {0.78f, {0.400f, 1.000f, 0.720f}},
        {1.00f, {0.900f, 1.000f, 0.940f}},
    };
    // 传统 VFD/荧光管的深绿：整条都保持饱和绿色，只有最亮的点芯才略微发白
    static const Stop kDeepGreen[] = {
        {0.00f, {0.004f, 0.022f, 0.014f}},
        {0.10f, {0.010f, 0.150f, 0.070f}},
        {0.30f, {0.020f, 0.520f, 0.190f}},
        {0.55f, {0.060f, 0.880f, 0.330f}},
        {0.78f, {0.180f, 1.000f, 0.560f}},
        {1.00f, {0.620f, 1.000f, 0.820f}},
    };
    static const Stop kBlue[] = {
        {0.00f, {0.006f, 0.014f, 0.040f}},
        {0.10f, {0.020f, 0.080f, 0.320f}},
        {0.30f, {0.060f, 0.250f, 0.850f}},
        {0.55f, {0.220f, 0.560f, 1.000f}},
        {0.78f, {0.480f, 0.780f, 1.000f}},
        {1.00f, {0.880f, 0.950f, 1.000f}},
    };
    static const Stop kPink[] = {
        {0.00f, {0.035f, 0.008f, 0.024f}},
        {0.10f, {0.220f, 0.035f, 0.130f}},
        {0.30f, {0.640f, 0.100f, 0.360f}},
        {0.55f, {0.960f, 0.300f, 0.580f}},
        {0.78f, {1.000f, 0.560f, 0.750f}},
        {1.00f, {1.000f, 0.900f, 0.950f}},
    };
    static const Stop kOrange[] = {
        {0.00f, {0.040f, 0.016f, 0.004f}},
        {0.10f, {0.260f, 0.085f, 0.010f}},
        {0.30f, {0.720f, 0.230f, 0.020f}},
        {0.55f, {1.000f, 0.480f, 0.080f}},
        {0.78f, {1.000f, 0.720f, 0.360f}},
        {1.00f, {1.000f, 0.930f, 0.820f}},
    };
    const Stop* table = kYellowGreen;
    switch (t) {
        case Theme::deepGreen: table = kDeepGreen; break;
        case Theme::blue:      table = kBlue;      break;
        case Theme::pink:      table = kPink;      break;
        case Theme::orange:    table = kOrange;    break;
        case Theme::yellowGreen:
        default:               table = kYellowGreen; break;
    }
    count = 6;
    return table;
}

inline std::vector<uint8_t> buildLut(Theme theme) {
    int n = 0;
    const Stop* s = stopsTable(theme, n);
    std::vector<uint8_t> lut((size_t)kLutSize * 3);
    for (int i = 0; i < kLutSize; ++i) {
        const float t = (float)i / (float)(kLutSize - 1);
        int k = 0;
        while (k + 1 < n && t > s[k + 1].t) ++k;
        const float t0 = s[k].t;
        const float t1 = (k + 1 < n) ? s[k + 1].t : 1.0f;
        const float u = (t1 > t0) ? (t - t0) / (t1 - t0) : 0.0f;
        const RgbF c0 = s[k].c;
        const RgbF c1 = (k + 1 < n) ? s[k + 1].c : s[k].c;
        lut[(size_t)i * 3 + 0] = (uint8_t)(255.0f * std::min(1.0f, c0.r + (c1.r - c0.r) * u));
        lut[(size_t)i * 3 + 1] = (uint8_t)(255.0f * std::min(1.0f, c0.g + (c1.g - c0.g) * u));
        lut[(size_t)i * 3 + 2] = (uint8_t)(255.0f * std::min(1.0f, c0.b + (c1.b - c0.b) * u));
    }
    return lut;
}

// ---------------------------------------------------------------- 3x5 点阵字体
// 每个字形 5 行，每行低 3 位表示左→右；与 Python 的 FONT_3X5 同一张表
struct Glyph { char c; uint8_t rows[kGlyphH]; };

inline const Glyph* fontTable(int& count) {
    static const Glyph kFont[] = {
        {'0', {0b111, 0b101, 0b101, 0b101, 0b111}},
        {'1', {0b010, 0b110, 0b010, 0b010, 0b111}},
        {'2', {0b111, 0b001, 0b111, 0b100, 0b111}},
        {'3', {0b111, 0b001, 0b111, 0b001, 0b111}},
        {'4', {0b101, 0b101, 0b111, 0b001, 0b001}},
        {'5', {0b111, 0b100, 0b111, 0b001, 0b111}},
        {'6', {0b111, 0b100, 0b111, 0b101, 0b111}},
        {'7', {0b111, 0b001, 0b001, 0b001, 0b001}},
        {'8', {0b111, 0b101, 0b111, 0b101, 0b111}},
        {'9', {0b111, 0b101, 0b111, 0b001, 0b111}},
        {'A', {0b111, 0b101, 0b111, 0b101, 0b101}},
        {'B', {0b110, 0b101, 0b110, 0b101, 0b110}},
        {'C', {0b111, 0b100, 0b100, 0b100, 0b111}},
        {'D', {0b110, 0b101, 0b101, 0b101, 0b110}},
        {'E', {0b111, 0b100, 0b111, 0b100, 0b111}},
        {'F', {0b111, 0b100, 0b111, 0b100, 0b100}},
        {'G', {0b111, 0b100, 0b101, 0b101, 0b111}},
        {'H', {0b101, 0b101, 0b111, 0b101, 0b101}},
        {'I', {0b111, 0b010, 0b010, 0b010, 0b111}},
        {'J', {0b001, 0b001, 0b001, 0b101, 0b111}},
        {'K', {0b101, 0b101, 0b110, 0b101, 0b101}},
        {'L', {0b100, 0b100, 0b100, 0b100, 0b111}},
        {'M', {0b101, 0b111, 0b111, 0b101, 0b101}},
        {'N', {0b110, 0b101, 0b101, 0b101, 0b101}},
        {'O', {0b111, 0b101, 0b101, 0b101, 0b111}},
        {'P', {0b111, 0b101, 0b111, 0b100, 0b100}},
        {'Q', {0b111, 0b101, 0b101, 0b111, 0b001}},
        {'R', {0b111, 0b101, 0b111, 0b110, 0b101}},
        {'S', {0b111, 0b100, 0b111, 0b001, 0b111}},
        {'T', {0b111, 0b010, 0b010, 0b010, 0b010}},
        {'U', {0b101, 0b101, 0b101, 0b101, 0b111}},
        {'V', {0b101, 0b101, 0b101, 0b101, 0b010}},
        {'W', {0b101, 0b101, 0b111, 0b111, 0b101}},
        {'X', {0b101, 0b101, 0b010, 0b101, 0b101}},
        {'Y', {0b101, 0b101, 0b010, 0b010, 0b010}},
        {'Z', {0b111, 0b001, 0b010, 0b100, 0b111}},
        {'-', {0b000, 0b000, 0b111, 0b000, 0b000}},
        {'.', {0b000, 0b000, 0b000, 0b000, 0b010}},
        {':', {0b000, 0b010, 0b000, 0b010, 0b000}},
        {'/', {0b001, 0b001, 0b010, 0b100, 0b100}},
        {'+', {0b000, 0b010, 0b111, 0b010, 0b000}},
        {'%', {0b101, 0b001, 0b010, 0b100, 0b101}},
        {' ', {0b000, 0b000, 0b000, 0b000, 0b000}},
    };
    count = (int)(sizeof(kFont) / sizeof(kFont[0]));
    return kFont;
}

// ---------------------------------------------------------------- 屏幕
class Screen {
public:
    Screen(int cols, int rows, int cell, int dot, float dbMin = -78.0f, float dbMax = 0.0f)
        : cols_(cols), rows_(rows), cell_(cell), dot_(dot),
          dbMin_(dbMin), dbMax_(dbMax),
          lut_(buildLut(Theme::yellowGreen)),
          field_((size_t)rows * cols, V_OFF),
          persist_((size_t)rows * cols, V_OFF),
          stat_((size_t)rows * cols, V_OFF) {
        computeLayout();
        buildCaches();
    }

    int width() const { return cols_ * cell_; }
    int height() const { return rows_ * cell_; }

    // ---- 主题配色（单击点阵屏循环切换；只重建 512 项查表，代价可忽略）----
    Theme theme() const { return theme_; }
    const char* themeLabel() const { return themeName(theme_); }
    static int themeCount() { return kThemeCount; }
    void setTheme(Theme t) {
        theme_ = t;
        lut_ = buildLut(t);
    }
    void nextTheme() {
        setTheme((Theme)(((int)theme_ + 1) % kThemeCount));
    }
    int plotLeft() const { return plotLeft_; }
    int plotRight() const { return plotRight_; }
    int plotTop() const { return plotTop_; }
    int plotBottom() const { return plotBottom_; }
    // 声量计版式（供调用方/测试查询）
    int meterWidth() const { return plotW(); }
    int meterHeight() const { return meterH_; }
    int meterTopRow() const { return meterTop_; }
    int meterRowTop(int ch) const { return meterTop_ + ch * (meterH_ + meterGap_); }

    // 版面里**不再有状态行**：底部那一行（原来写 "EAPO 254 BANDS" / "VFD"）已经
    // 整行还给频谱。插件把这类信息放它自己的状态栏（JUCE 画在图像下方，不占点阵）。
    void setHeader(const std::string& title, const std::string& readout1,
                   const std::string& readout2) {
        title_ = title;
        readout1_ = readout1;
        readout2_ = readout2;
        buildStatic();
    }

    // ---- FR 模式扩展（SystemPEQ）-------------------------------------------
    // frMode_: 0dB 居中的对称 dB 轴 + 左侧 dB 标签（用于画 EQ 频响曲线）
    void configureFr(bool on) {
        if (frMode_ == on) return;
        frMode_ = on;
        computeLayout();
        buildStatic();
    }
    void setMetersVisible(bool on) {
        if (showMeters_ == on) return;
        showMeters_ = on;
        computeLayout();
        buildStatic();
    }
    // u∈[0,1] 频率轴（20Hz..20kHz 对数），v∈[0,1] dB 轴（dbMin_..dbMax_，0=底 1=顶）
    // 写入动态层 field_（与 drawBars 同层，走磷光余辉）
    void plotDotU(float u, float v, float val) {
        u = std::min(1.0f, std::max(0.0f, u));
        v = std::min(1.0f, std::max(0.0f, v));
        const int col = plotLeft_ + (int)std::lround(u * (float)(plotW() - 1));
        const int row = plotBottom_ - (int)std::lround(v * (float)(plotBottom_ - plotTop_));
        if (col < plotLeft_ || col > plotRight_ || row < plotTop_ || row > plotBottom_) return;
        float& cell = field_[(size_t)row * cols_ + col];
        cell = std::max(cell, val);
    }
    static float uForFreq(float f) {
        constexpr float lo = 1.30103f, hi = 4.30103f;   // log10(20), log10(20000)
        return (std::log10(std::max(f, 1e-6f)) - lo) / (hi - lo);
    }

    // ---- 组合屏模式（SystemPEQ）：顶部声量计 + 中部 FR 曲线 + 底部频谱，共享频率轴 ----
    void configureDual(bool on) {
        if (dualMode_ == on) return;
        dualMode_ = on;
        computeLayout();
        buildStatic();
    }
    int plotWidth() const { return plotW(); }
    // FR 纵轴量程（±halfDb），由 RNG 按钮在 ±6/12/18/24/36 之间循环
    void setFrRange(float halfDb) {
        halfDb = std::min(48.0f, std::max(2.0f, std::fabs(halfDb)));
        if (frDbMax_ == halfDb) return;
        frDbMin_ = -halfDb;
        frDbMax_ = halfDb;
        buildStatic();
    }
    float frRange() const { return frDbMax_; }
    // 在 FR 子区画点：u∈[0,1] 频率轴（20Hz..20kHz 对数），db 直接用 FR 量程（默认 ±24dB）
    void frDotDb(float u, float db, float val) {
        u = std::min(1.0f, std::max(0.0f, u));
        float v = (db - frDbMin_) / (frDbMax_ - frDbMin_);
        v = std::min(1.0f, std::max(0.0f, v));
        const int col = plotLeft_ + (int)std::lround(u * (float)(plotW() - 1));
        const int row = frBottom_ - (int)std::lround(v * (float)(frBottom_ - frTop_));
        if (col < plotLeft_ || col > plotRight_ || row < frTop_ || row > frBottom_) return;
        float& cell = field_[(size_t)row * cols_ + col];
        cell = std::max(cell, val);
    }

    // ---- 控件区绘制原语（SystemPEQ）：写动态层 field_，与 drawBars 同层 max 合成 ----
    // 控件（音量条/PEQ 滑条/按钮）每帧由调用方重画：框 + 滑块 + 点阵文字 + 悬停辉光。
    void dotDyn(int x, int y, float v) {
        if (x < 0 || x >= cols_ || y < 0 || y >= rows_) return;
        float& cell = field_[(size_t)y * cols_ + x];
        cell = std::max(cell, v);
    }
    void hLineDyn(int x0, int x1, int y, float v) {
        if (y < 0 || y >= rows_) return;
        for (int x = std::max(0, x0); x <= std::min(cols_ - 1, x1); ++x) dotDyn(x, y, v);
    }
    void vLineDyn(int x, int y0, int y1, float v) {
        if (x < 0 || x >= cols_) return;
        for (int y = std::max(0, y0); y <= std::min(rows_ - 1, y1); ++y) dotDyn(x, y, v);
    }
    // 空心矩形框（点阵观感：四边 1 格线）
    void boxDyn(int x0, int y0, int x1, int y1, float v) {
        hLineDyn(x0, x1, y0, v);  hLineDyn(x0, x1, y1, v);
        vLineDyn(x0, y0, y1, v);  vLineDyn(x1, y0, y1, v);
    }
    void textDyn(int x, int y, const std::string& s, float v, int scale = 1) {
        textTo(field_, x, y, s, v, scale);
    }

    // ---- 控件区几何（供调用方摆放 ImGui 热区；格坐标，含边框）----
    static constexpr int kBandRows = 10;      // 控件区固定 10 行 band
    static constexpr int kTopButtons = 6;     // PWR RNG INP EXP HUE FLT（声量计下方水平一排）
    static constexpr int kFrSpanRows = 61;    // FR 子区行数（47 行再加高 ~30%）
    int cellPx() const { return cell_; }
    int ctlX0() const { return plotLeft_; }   // 控件区与图形区等宽（同一 plotLeft/Right）
    int ctlX1() const { return plotRight_; }
    // 顶部按钮排第 i 个按钮（PWR/RNG/INP/EXP/HUE/FLT 从左到右）：格矩形
    void topButtonRect(int i, int& x0, int& y0, int& x1, int& y1) const {
        const int w = (plotW() - (kTopButtons - 1) * 2) / kTopButtons;
        x0 = plotLeft_ + i * (w + 2);
        x1 = (i == kTopButtons - 1) ? plotRight_ : (x0 + w - 1);
        y0 = btnRowTop_;
        y1 = y0 + kCtlH - 1;
    }
    // 音量行 i（0=IN 上行, 1=OUT 下行）
    void volRowRect(int i, int& y0, int& y1) const {
        y0 = volTop_ + i * (kCtlH + 1);
        y1 = y0 + kCtlH - 1;
    }
    // band 行 i
    void bandRowRect(int i, int& y0, int& y1) const {
        y0 = bandTop_ + i * (kCtlH + 1);
        y1 = y0 + kCtlH - 1;
    }
    int ctlHeight() const { return kCtlH; }

    void clearDynamic() {
        std::copy(stat_.begin(), stat_.end(), field_.begin());
    }

    // 把 n 个频段映射到显示列：**每列取该列覆盖范围内的最大值**。
    // 直接最近邻采样会在 512 频段 -> 109 列时把窄峰整根丢掉（实测很显眼）。
    void columnRange(int c, int n, int& lo, int& hi) const {
        const int plotW_ = plotW();
        lo = (int)(((long long)c * n) / plotW_);
        hi = (int)((((long long)(c + 1) * n) + plotW_ - 1) / plotW_);
        if (hi <= lo) hi = lo + 1;
        lo = std::min(lo, n - 1);
        hi = std::min(hi, n);
    }

    // 柱体：竖直磷光渐变；频段按列取 max 后重采样
    void drawBars(const float* bands, int n) {
        const int span = plotBottom_ - plotTop_;
        if (span <= 0 || n <= 0) return;
        for (int c = 0; c < plotW(); ++c) {
            int lo = 0, hi = 1;
            columnRange(c, n, lo, hi);
            float v = 0.0f;
            for (int i = lo; i < hi; ++i) v = std::max(v, bands[i]);
            v = std::min(1.0f, std::max(0.0f, v));
            const float height = v * (float)span;
            const float tint = std::pow(v, 0.30f) + 0.02f;
            for (int r = plotTop_; r <= plotBottom_; ++r) {
                const float up = (float)(plotBottom_ - r);
                const float lit = std::min(1.0f, std::max(0.0f, height - up));
                if (lit <= 0.0f) continue;
                const float depth = std::min(1.0f, up / std::max(height, 1e-6f));
                // 查表代替每格一次 pow()
                const float bright = std::min(1.0f, depthLut_[(size_t)(int)(depth * 64.0f)] * lit * tint);
                float& cell = field_[(size_t)r * cols_ + (plotLeft_ + c)];
                cell = std::max(cell, bright);
            }
        }
    }

    // 峰值帽：每列只点亮一个点，且**始终绘制**（沿用 Python 的最终设计）
    void drawPeaks(const float* peaks, int n) {        const int span = plotBottom_ - plotTop_;
        if (span <= 0 || n <= 0) return;
        for (int c = 0; c < plotW(); ++c) {
            int lo = 0, hi = 1;
            columnRange(c, n, lo, hi);
            float p = 0.0f;
            for (int i = lo; i < hi; ++i) p = std::max(p, peaks[i]);
            p = std::min(1.0f, std::max(0.0f, p));
            int row = plotBottom_ - (int)std::lround(p * (float)span);
            row = std::min(plotBottom_, std::max(plotTop_, row));
            float& cell = field_[(size_t)row * cols_ + (plotLeft_ + c)];
            cell = std::max(cell, V_PEAK);
        }
    }

    // ---- 声量计 / 峰值计（foobar2000 那种两条：声量 + 峰值）--------------------
    // 版式：绘图区下方两条横向条（上=L，下=R），最底部一条横向 dBFS 刻度。
    // 风格与频谱柱体一致：水平方向的磷光渐变（起点幽暗 → 条头炽亮），峰值条整体压暗，
    // 只有它的**条头**用与频谱 peak 帽相同的最高亮度（V_METER_TIP）。
    // 计量坐标：linear in dB，[kMeterDbMin, 0] dBFS → 0..1 归一化（与底部刻度一一对应）。
    void drawMeters(const float* vuNorm, const float* peakNorm, int nChannels) {
        if (meterW() <= 2 || nChannels <= 0) return;
        const int w = meterW();
        for (int ch = 0; ch < nChannels && ch < 2; ++ch) {
            const int rowTop = meterRowTop(ch);
            if (rowTop < 0) continue;
            const float vu = std::min(1.0f, std::max(0.0f, vuNorm[ch]));
            const float pk = std::min(1.0f, std::max(0.0f, peakNorm[ch]));
            const int vuCols = (int)std::lround(vu * (float)w);
            const int pkCols = (int)std::lround(pk * (float)w);
            for (int c = 0; c < w; ++c) {
                const float level = (float)(c + 1) / (float)w;   // 该列对应的归一化电平
                float v = V_OFF;
                // 峰值条：整条压暗，只有条头最亮
                if (c < pkCols) v = std::max(v, V_METER_BODY);
                if (c == pkCols - 1) v = std::max(v, V_METER_TIP);
                // 声量条：与频谱柱体同一套"深度渐变"，但把底部亮度抬到明显高于峰值条
                // 主体（否则条子前半段看不出"声量 vs 峰值"两层）
                if (c < vuCols) {
                    const float depth = (vu > 1e-4f) ? std::min(1.0f, level / vu) : 1.0f;
                    const float tint = std::pow(vu, 0.30f) + 0.02f;
                    const float ramp = 0.30f + 0.70f * depthLut_[(size_t)(int)(depth * 64.0f)];
                    v = std::max(v, std::min(1.0f, ramp * tint));
                }
                for (int r = rowTop; r < rowTop + meterH_ && r < rows_; ++r) {
                    float& cell = field_[(size_t)r * cols_ + (plotLeft_ + c)];
                    cell = std::max(cell, v);
                }
            }
        }
    }

    // 磷光暂留：逐点阵像素的一阶 IIR，beta 用 dt 换算（帧率无关）
    //
    // 声量计那一段**跳过暂留**：它自己已经带弹道（VU 300ms 积分 + 峰值 dB/s 回落），
    // 再叠一层磷光余辉会把读数整体抬高、也变得迟钝。渲染时的泛光仍然覆盖它，
    // 所以看上去还是同一块屏。
    void applyPersistence(float dt, float tau) {
        if (tau <= 1e-6f) {
            persist_ = field_;
            return;
        }
        const float beta = 1.0f - std::exp(-std::max(0.0f, dt) / tau);
        const int meterStart = meterTopRow();
        const int meterEnd = meterBottomRow();
        for (int r = 0; r < rows_; ++r) {
            const size_t base = (size_t)r * cols_;
            const bool inMeter = (meterStart >= 0 && r >= meterStart && r <= meterEnd);
            // 控件区（音量/滑条/按钮）不走余辉：数值读数要即时清晰，
            // "亮度变换惯量"由调用方每控件的 glow 变量自己实现。
            const bool inCtl = (ctlSkipTop_ >= 0 && r >= ctlSkipTop_ && r <= ctlSkipBottom_);
            for (int c = 0; c < cols_; ++c) {
                const size_t i = base + (size_t)c;
                if (inMeter || inCtl) {
                    persist_[i] = field_[i];      // 仪表/控件区不走余辉（见上面的注释）
                } else {
                    persist_[i] = beta * field_[i] + (1.0f - beta) * persist_[i];
                }
            }
        }
    }

    // 出图：**泛光在格域做** + 展开成原生像素（点阵掩膜/暗角/查表）
    //
    // 为什么泛光要放格域：像素域是 508x300 = 152,400 个点，格域只有 127x75 = 9,525 个，
    // 少 16 倍；而且点阵屏的辉光本来就该以"点"为单位扩散（早年 16 位单片机也是这么做的）。
    // 实测原本像素域两级 box_blur + 查表要 4~9 ms，改完后整帧 <1 ms。
    void render(std::vector<uint8_t>& rgbOut) const {
        const int w = width(), h = height();

        std::vector<float> glow((size_t)rows_ * cols_, 0.0f);
        std::vector<float> tmp((size_t)rows_ * cols_, 0.0f);
        boxBlurCells(persist_, tmp, glow, 1, 0.30f);   // 对应像素域半径 3(≈0.75 格)
        boxBlurCells(persist_, tmp, glow, 2, 0.12f);   // 对应像素域半径 7(≈1.75 格)

        rgbOut.resize((size_t)w * h * 3);
        for (int cy = 0; cy < rows_; ++cy) {
            for (int cx = 0; cx < cols_; ++cx) {
                const size_t ci = (size_t)cy * cols_ + cx;
                const float base = persist_[ci];
                const float g = glow[ci];
                for (int py = 0; py < cell_; ++py) {
                    const int y = cy * cell_ + py;
                    const bool dotRow = (py < dot_);
                    uint8_t* row = rgbOut.data() + ((size_t)y * w + (size_t)cx * cell_) * 3;
                    const float vigY = vy_[(size_t)y];
                    for (int px = 0; px < cell_; ++px) {
                        const bool dotCol = (px < dot_);
                        // 点亮区 = 自身磷光 + 泛光；间隙只吃一部分泛光（留出点阵颗粒感）
                        float lit = (dotRow && dotCol) ? (base + g) : (g * 0.55f);
                        lit *= (1.06f - vx_[(size_t)(cx * cell_ + px)] - vigY);
                        lit = lit < 0.0f ? 0.0f : (lit > 1.0f ? 1.0f : lit);
                        const int li = (int)(lit * (float)(kLutSize - 1));
                        row[px * 3 + 0] = lut_[(size_t)li * 3 + 0];
                        row[px * 3 + 1] = lut_[(size_t)li * 3 + 1];
                        row[px * 3 + 2] = lut_[(size_t)li * 3 + 2];
                    }
                }
            }
        }
    }

private:
    int plotW() const { return plotRight_ - plotLeft_ + 1; }
    int meterW() const { return plotW(); }                       // 声量计与频谱同宽
    int meterBottomRow() const { return meterBottom_; }

    // 预计算热点表：柱体竖直渐变(替代 pow) 与暗角的行/列分量
    void buildCaches() {
        depthLut_.resize(65);
        for (int i = 0; i <= 64; ++i) {
            const float d = (float)i / 64.0f;
            depthLut_[(size_t)i] = 0.12f + 0.88f * std::pow(d, 1.15f);
        }
        const int w = width(), h = height();
        vx_.resize((size_t)w);
        vy_.resize((size_t)h);
        for (int x = 0; x < w; ++x) {
            const float nx = ((float)x / (float)(w - 1)) * 2.0f - 1.0f;
            vx_[(size_t)x] = 0.24f * 0.7f * nx * nx;
        }
        for (int y = 0; y < h; ++y) {
            const float ny = ((float)y / (float)(h - 1)) * 2.0f - 1.0f;
            vy_[(size_t)y] = 0.24f * 0.5f * ny * ny;
        }
    }

    void computeLayoutDual() {
        margin_ = 1;
        headerH_ = 0;                                   // 无表头（In/Out 信息在 GUI 设备栏）
        headerTop_ = margin_;
        // 绘图区占满整屏宽度（FR 的 dB 标签画在曲线区内侧右缘，不再留左侧标签列）
        plotLeft_ = margin_ + 1;
        plotRight_ = cols_ - margin_ - 1;
        // 顶部声量计（L/R 两条，横向）
        meterH_ = 4;
        meterGap_ = 1;
        meterTop_ = margin_ + 1;
        meterBottom_ = meterTop_ + 2 * meterH_ + meterGap_ - 1;
        // 按钮排（PWR/RNG/INP/EXP/HUE/FLT 水平一排）：声量计与 FR 之间
        btnRowTop_ = meterBottom_ + 2;
        // FR 子区：按钮排下方，固定 47 行（比旧 31 行加高 ~50%）
        frTop_ = btnRowTop_ + kCtlH + 2;
        frBottom_ = frTop_ + kFrSpanRows - 1;
        // ---- 共享频率轴（FR 与频谱之间）----
        axisTickTop_ = frBottom_ + 2;
        axisLabelTop_ = axisTickTop_ + 2;
        // ---- 频谱子区：固定 50 行 ----
        specTop_ = axisLabelTop_ + kGlyphH + 1;
        specBottom_ = specTop_ + kSpecSpan - 1;
        plotTop_ = specTop_;
        plotBottom_ = specBottom_;
        // ---- 控件区（自下而上）：10 行 band + 2 行音量，框高 7，行距 1 ----
        const int bezelBottom = rows_ - 1;
        bandTop_ = bezelBottom - 2 - kCtlH - (kBandRows - 1) * (kCtlH + 1);
        volTop_  = bandTop_ - 3 - (kCtlH - 1) - 2 - (kCtlH - 1);
        ctlSkipTop_ = volTop_;
        ctlSkipBottom_ = bandTop_ + (kBandRows - 1) * (kCtlH + 1) + kCtlH - 1;
    }

    void buildStaticDual() {
        std::fill(stat_.begin(), stat_.end(), V_OFF);
        for (int x = 0; x < cols_; ++x) { dot(x, 0, V_BEZEL); dot(x, rows_ - 1, V_BEZEL); }
        for (int y = 0; y < rows_; ++y) { dot(0, y, V_BEZEL); dot(cols_ - 1, y, V_BEZEL); }

        // FR 子区：对称 dB 网格 + 内侧右缘标签（不再占左侧空间）
        // 刻度固定为 {-R, -R/2, 0, +R/2, +R}（R = 6/12/18/24/36），位置恒定不随行数变
        const float dbTotal = frDbMax_ - frDbMin_;
        const int frSpan = frBottom_ - frTop_;
        const float marks[5] = {frDbMin_, frDbMin_ * 0.5f, 0.0f, frDbMax_ * 0.5f, frDbMax_};
        for (float db : marks) {
            const float t = (db - frDbMin_) / dbTotal;
            const int row = frBottom_ - (int)std::lround(t * (float)frSpan);
            hLine(plotLeft_, plotRight_, row, (std::fabs(db) < 0.01f) ? V_GRID_MAJOR : V_GRID, 2);
            char buf[8];
            std::snprintf(buf, sizeof(buf), "%d", (int)db);
            const int w = textWidth(buf, 1);
            text(plotRight_ - w, row - 2, buf, V_LABEL, 1);   // 曲线区内侧右对齐
        }

        // 共享频率轴（FR 与频谱之间）
        static const float kMajors[] = {20, 50, 100, 500, 1000, 5000, 10000, 20000};
        int lastLabelEnd = -100;
        for (float f : kMajors) {
            const int col = (int)std::lround(freqToCol(f));
            vLine(col, axisTickTop_, axisTickTop_ + 1, V_TICK, 1);
            char buf[16];
            if (f >= 1000.0f) std::snprintf(buf, sizeof(buf), "%dK", (int)(f / 1000.0f));
            else std::snprintf(buf, sizeof(buf), "%d", (int)f);
            const std::string label(buf);
            const int wLab = textWidth(label, 1);
            const int lx = std::max(plotLeft_, col - wLab / 2);
            if (lx > lastLabelEnd + 1 && lx + wLab < cols_ - margin_) {
                text(lx, axisLabelTop_, label, V_LABEL, 1);
                lastLabelEnd = lx + wLab;
            }
        }

        // 频谱子区底边界线（顶部不画：FR 与频谱之间不要横线）
        hLine(plotLeft_, plotRight_, specBottom_ + 1, V_AXIS, 1);

        std::copy(stat_.begin(), stat_.end(), field_.begin());
        std::copy(stat_.begin(), stat_.end(), persist_.begin());
    }

    void computeLayout() {
        if (dualMode_) { computeLayoutDual(); return; }
        margin_ = 2;
        titleScale_ = (cols_ >= 100) ? 2 : 1;
        const int titleH = kGlyphH * titleScale_ + 2;
        const int readoutH = 2 * (kGlyphH + 1);
        // 不要 +2 的余量：标题块下方紧挨着频谱顶边（用户要求把这段 padding 减两行，
        // 腾出来的两行直接给频谱）。标题本身已经有 1 行内边距（titleH 里的 +2）。
        headerH_ = std::max(titleH, readoutH);
        headerTop_ = margin_;

        // 左侧不再留 14 列给 dB 刻度：只留"外框 + 1 格轴线"。
        plotLeft_ = margin_ + 1;
        plotRight_ = cols_ - margin_ - 1;

        // ---- 底部（由下往上）：dBFS 刻度 -> 声量计两条(L/R) -> 频率刻度 -> 频谱轴线 ----
        //   dBFS 刻度标签最底下一行，风格与频率刻度一致（只有数字，不写 "dBFS" 字样）
        dbfsLabelTop_ = rows_ - margin_ - kGlyphH;
        dbfsTickRow_ = dbfsLabelTop_ - 1;
        meterBottom_ = dbfsLabelTop_ - 3;                    // 与刻度之间留 2 格
        // 声量计条高度**保持原样**（标称 15px）；用户要的是"整块显示区加高 20%，
        // 多出来的高度全给频谱"，仪表条不参与变高。
        meterH_ = std::max(3, (int)std::lround(15.0 / (double)std::max(1, cell_)));
        meterH_ = std::min(meterH_, std::max(3, (rows_ - 40) / 6));   // 小屏时别把频谱挤没
        meterGap_ = 1;
        if (!showMeters_) { meterH_ = 0; meterGap_ = 0; }             // FR 模式：整块还给频谱/曲线
        meterTop_ = meterBottom_ - (2 * meterH_ + meterGap_) + 1;

        // 频谱的 X 轴（刻度线 + 频率标签）紧贴绘图区下方
        axisLabelTop_ = meterTop_ - 2 - kGlyphH;
        axisTickTop_ = axisLabelTop_ - 2;
        axisRow_ = axisTickTop_ - 1;
        plotBottom_ = axisRow_ - 1;
        plotTop_ = headerTop_ + headerH_ + 1;
        if (plotBottom_ < plotTop_ + 4) plotBottom_ = plotTop_ + 4;   // 极端小屏兜底
    }

    void dot(int x, int y, float v) {
        if (x < 0 || x >= cols_ || y < 0 || y >= rows_) return;
        float& cell = stat_[(size_t)y * cols_ + x];
        cell = std::max(cell, v);
    }

    void hLine(int x0, int x1, int y, float v, int dash) {
        if (y < 0 || y >= rows_) return;
        for (int x = std::max(0, x0); x <= std::min(cols_ - 1, x1); ++x) {
            if (dash <= 1 || (x % dash) == 0) dot(x, y, v);
        }
    }

    void vLine(int x, int y0, int y1, float v, int dash) {
        if (x < 0 || x >= cols_) return;
        for (int y = std::max(0, y0); y <= std::min(rows_ - 1, y1); ++y) {
            if (dash <= 1 || (y % dash) == 0) dot(x, y, v);
        }
    }

    int textWidth(const std::string& s, int scale) const {
        if (s.empty()) return 0;
        return (int)s.size() * (kGlyphW + 1) * scale - scale;
    }

    void text(int x, int y, const std::string& s, float v, int scale) {
        textTo(stat_, x, y, s, v, scale);
    }

    void textTo(std::vector<float>& target, int x, int y, const std::string& s, float v, int scale) const {
        int cx = x;
        for (char ch : s) {
            const char up = (char)std::toupper((unsigned char)ch);
            int n = 0;
            const Glyph* font = fontTable(n);
            const Glyph* g = nullptr;
            for (int i = 0; i < n; ++i) {
                if (font[i].c == up) { g = &font[i]; break; }
            }
            if (g != nullptr) {
                for (int gy = 0; gy < kGlyphH; ++gy) {
                    for (int gx = 0; gx < kGlyphW; ++gx) {
                        if ((g->rows[gy] >> (kGlyphW - 1 - gx)) & 1) {
                            for (int sy = 0; sy < scale; ++sy) {
                                for (int sx = 0; sx < scale; ++sx) {
                                    const int px = cx + gx * scale + sx, py = y + gy * scale + sy;
                                    if (px < 0 || px >= cols_ || py < 0 || py >= rows_) continue;
                                    float& cell = target[(size_t)py * cols_ + px];
                                    cell = std::max(cell, v);
                                }
                            }
                        }
                    }
                }
            }
            cx += (kGlyphW + 1) * scale;
        }
    }

    float freqToCol(float f) const {
        const float lo = std::log10(20.0f), hi = std::log10(20000.0f);
        const float t = (std::log10(std::max(f, 1e-6f)) - lo) / (hi - lo);
        return (float)plotLeft_ + t * (float)(plotW() - 1);
    }

    void buildStatic() {
        if (dualMode_) { buildStaticDual(); return; }
        std::fill(stat_.begin(), stat_.end(), V_OFF);

        // 外框
        for (int x = 0; x < cols_; ++x) { dot(x, 0, V_BEZEL); dot(x, rows_ - 1, V_BEZEL); }
        for (int y = 0; y < rows_; ++y) { dot(0, y, V_BEZEL); dot(cols_ - 1, y, V_BEZEL); }

        // 横向 dB 网格线（只在绘图区内，纵向网格线故意不画——低清点阵下会糊）
        // frMode_ 时轴对称（0dB 居中），并在左侧标 dB 值
        const float dbTotal = dbMax_ - dbMin_;
        const int spanRows = plotBottom_ - plotTop_;
        int dbStep = 78;
        const int candidates[] = {6, 12, 24, 39, 78};
        for (int s : candidates) {
            if ((float)s / dbTotal * (float)spanRows >= 2.4f) { dbStep = s; break; }
        }
        for (float db = std::ceil(dbMin_ / dbStep) * dbStep; db <= dbMax_ + 0.01f; db += (float)dbStep) {
            const float t = (db - dbMin_) / dbTotal;
            const int row = (int)std::lround((float)plotBottom_ - t * (float)spanRows);
            hLine(plotLeft_, plotRight_, row, (std::fabs(db) < 0.01f) ? V_GRID_MAJOR : V_GRID, 2);
            if (frMode_ && std::fabs(db) > 0.01f) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "%d", (int)db);
                text(plotLeft_ + 1, row + 1, buf, V_LABEL, 1);
            }
        }

        // 坐标轴。
        // ⚠️ 左侧那条**竖轴线去掉了**：它原来标的是"这里曾是 dB 刻度"，刻度搬到底部
        // 横向 dBFS 条之后它就只剩副作用 —— 它画在第 plotLeft_-1 列，比柱形区（第
        // plotLeft_ 列）和声量计条（同样是第 plotLeft_ 列）都靠左一格，于是"频谱柱形区
        // 左沿看着和声量计左沿没对齐"。去掉它，三者左沿严格齐平。
        // 横轴线也跟着从 plotLeft_ 起（否则会往左探出一格、上面却是空的）。
        hLine(plotLeft_, plotRight_, axisRow_, V_AXIS, 1);

        // 频率刻度线 + 自适应标签
        static const float kMajors[] = {20, 50, 100, 500, 1000, 5000, 10000, 20000};
        int lastLabelEnd = -100;
        for (float f : kMajors) {
            const int col = (int)std::lround(freqToCol(f));
            vLine(col, axisTickTop_, axisTickTop_ + 1, V_TICK, 1);
            char buf[16];
            if (f >= 1000.0f) std::snprintf(buf, sizeof(buf), "%dK", (int)(f / 1000.0f));
            else std::snprintf(buf, sizeof(buf), "%d", (int)f);
            const std::string label(buf);
            const int wLab = textWidth(label, 1);
            // 最左边的标签也夹在绘图区内（不能越到外框上，也不能往左探出柱形区）
            const int lx = std::max(plotLeft_, col - wLab / 2);
            if (lx > lastLabelEnd + 1 && lx + wLab < cols_ - margin_) {
                text(lx, axisLabelTop_, label, V_LABEL, 1);
                lastLabelEnd = lx + wLab;
            }
        }

        // 标题（左上）与读数（右上）
        text(margin_, headerTop_, title_, V_TITLE, titleScale_);
        const int rx = cols_ - margin_ - textWidth(readout1_, 1);
        text(rx, headerTop_, readout1_, V_READOUT, 1);
        text(cols_ - margin_ - textWidth(readout2_, 1), headerTop_ + kGlyphH + 1, readout2_,
             V_READOUT, 1);

        // ---- 声量计区的 dBFS 网格（faint 竖点线，与频谱的横网格同一种风格）----
        if (showMeters_) {
            for (float db = kMeterDbMin; db <= -0.01f; db += 6.0f) {
                const int col = meterColForDb(db);
                const bool major = std::fmod(std::fabs(db), 12.0f) < 0.01f;
                vLine(col, meterTop_, meterBottom_, major ? V_GRID_MAJOR : V_GRID, 2);
            }
            // ---- 底部横向 dBFS 刻度（风格与频率刻度一致：短刻度线 + 数字，不写单位）----
            for (float db = kMeterDbMin; db <= 0.01f; db += 6.0f) {
                const int col = meterColForDb(db);
                vLine(col, dbfsTickRow_, dbfsTickRow_, V_TICK, 1);
                if (std::fmod(std::fabs(db), 12.0f) > 0.01f) continue;      // 每 12 dB 一个数字
                char buf[16];
                std::snprintf(buf, sizeof(buf), (db > -0.01f) ? "0" : "%d", (int)db);
                const std::string label(buf);
                const int wLab = textWidth(label, 1);
                const int lx = std::max(margin_, std::min(col - wLab / 2, cols_ - margin_ - wLab));
                text(lx, dbfsLabelTop_, label, V_LABEL, 1);
            }
        }

        std::copy(stat_.begin(), stat_.end(), field_.begin());
        std::copy(stat_.begin(), stat_.end(), persist_.begin());
    }

    // dBFS → 声量计区的列号（线性 in dB，与 MeterBank 的归一化严格对应）
    int meterColForDb(float db) const {
        const float t = (db - kMeterDbMin) / (0.0f - kMeterDbMin);
        return plotLeft_ + (int)std::lround(t * (float)(plotW() - 1));
    }

    // 格域可分离 box blur，用**滑动窗口**做到每格 O(1)（与半径无关）；
    // 结果按 weight 累加到 dst。作用对象是 127x75 的点阵网格。
    void boxBlurCells(const std::vector<float>& src, std::vector<float>& tmp,
                      std::vector<float>& dst, int r, float weight) const {
        const int w = cols_, h = rows_;
        const float inv = 1.0f / (float)(2 * r + 1);
        for (int y = 0; y < h; ++y) {
            const float* srow = src.data() + (size_t)y * w;
            float* trow = tmp.data() + (size_t)y * w;
            float sum = 0.0f;
            for (int k = -r; k <= r; ++k) sum += srow[std::min(w - 1, std::max(0, k))];
            for (int x = 0; x < w; ++x) {
                trow[x] = sum * inv;
                sum += srow[std::min(w - 1, x + r + 1)] - srow[std::max(0, x - r)];
            }
        }
        for (int x = 0; x < w; ++x) {
            float sum = 0.0f;
            for (int k = -r; k <= r; ++k) {
                sum += tmp[(size_t)std::min(h - 1, std::max(0, k)) * w + x];
            }
            for (int y = 0; y < h; ++y) {
                dst[(size_t)y * w + x] += weight * sum * inv;
                sum += tmp[(size_t)std::min(h - 1, y + r + 1) * w + x]
                       - tmp[(size_t)std::max(0, y - r) * w + x];
            }
        }
    }

    int cols_, rows_, cell_, dot_;
    float dbMin_, dbMax_;
    Theme theme_ = Theme::yellowGreen;
    std::vector<uint8_t> lut_;
    std::vector<float> field_, persist_, stat_;
    std::vector<float> depthLut_;    // 柱体竖直渐变查表(替代每格 pow)
    std::vector<float> vx_, vy_;     // 暗角按行/列预计算(每像素只剩两次减法)

    int margin_ = 2, titleScale_ = 2, headerH_ = 12, headerTop_ = 2;
    bool frMode_ = false, showMeters_ = true;
    bool dualMode_ = false;                       // 组合屏：声量计+FR+频谱
    float frDbMin_ = -24.0f, frDbMax_ = 24.0f;    // FR 子区 dB 量程
    int frTop_ = 0, frBottom_ = 0;                // FR 子区行范围
    int specTop_ = 0, specBottom_ = 0;            // 频谱子区行范围
    int plotLeft_ = 3, plotRight_ = 0, plotTop_ = 0, plotBottom_ = 0;
    int axisRow_ = 0, axisTickTop_ = 0, axisLabelTop_ = 0;
    int meterTop_ = 0, meterBottom_ = 0, meterH_ = 4, meterGap_ = 1;   // 声量计区
    int dbfsTickRow_ = 0, dbfsLabelTop_ = 0;                          // 底部 dBFS 刻度

    // 控件区布局（dual 模式）：顶部按钮排 + 2 行音量 + 10 行 band
    static constexpr int kCtlH = 7;               // 控件框高（5 行字形 + 上下各 1 行边距）
    static constexpr int kSpecSpan = 50;          // 频谱子区行数
    int btnRowTop_ = 0;
    int volTop_ = 0, bandTop_ = 0;
    int ctlSkipTop_ = -1, ctlSkipBottom_ = -1;

    std::string title_ = "SPECTRUM", readout1_ = "48000HZ", readout2_ = "32BIT 2CH";
};

}  // namespace vfdrender
