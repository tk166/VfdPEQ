// Lock-free SPSC ring buffer for stereo Float32 frames
#pragma once
#include <atomic>
#include <cstddef>
#include <vector>
#include <cstring>

class FrameRingBuffer {
public:
    explicit FrameRingBuffer(size_t capacityFrames, size_t channels = 2)
        : cap_(capacityFrames), ch_(channels), buf_(capacityFrames * channels) {}

    // returns number of frames actually written
    size_t write(const float* src, size_t frames) {
        size_t n = 0;
        while (n < frames) {
            size_t head = head_.load(std::memory_order_relaxed);
            size_t tail = tail_.load(std::memory_order_acquire);
            size_t freeSpace = cap_ - (head - tail);
            if (freeSpace == 0) break; // overflow: drop (engine slower than producer)
            size_t chunk = std::min(frames - n, freeSpace);
            // linearize to end of buffer
            size_t pos = head % cap_;
            size_t lin = std::min(chunk, cap_ - pos);
            std::memcpy(&buf_[pos * ch_], src + n * ch_, lin * ch_ * sizeof(float));
            if (chunk > lin)
                std::memcpy(&buf_[0], src + (n + lin) * ch_, (chunk - lin) * ch_ * sizeof(float));
            head_.store(head + chunk, std::memory_order_release);
            n += chunk;
        }
        return n;
    }

    // debug: 当前水位（可读帧数）——rebind 输出 Start 前的安全水位观测
    size_t level() const {
        size_t head = head_.load(std::memory_order_relaxed);
        size_t tail = tail_.load(std::memory_order_acquire);
        return head - tail;
    }

    // returns number of frames actually read
    size_t read(float* dst, size_t frames) {
        size_t n = 0;
        while (n < frames) {
            size_t tail = tail_.load(std::memory_order_relaxed);
            size_t head = head_.load(std::memory_order_acquire);
            size_t avail = head - tail;
            if (avail == 0) break; // underrun
            size_t chunk = std::min(frames - n, avail);
            size_t pos = tail % cap_;
            size_t lin = std::min(chunk, cap_ - pos);
            std::memcpy(dst + n * ch_, &buf_[pos * ch_], lin * ch_ * sizeof(float));
            if (chunk > lin)
                std::memcpy(dst + (n + lin) * ch_, &buf_[0], (chunk - lin) * ch_ * sizeof(float));
            tail_.store(tail + chunk, std::memory_order_release);
            n += chunk;
        }
        return n;
    }

private:
    size_t              cap_, ch_;
    std::vector<float>  buf_;
    // monotonically increasing frame counters
    std::atomic<size_t> head_{0}, tail_{0};
};
