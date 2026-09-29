// Shared-memory SPSC frame ring: engine (producer) -> GUI (consumer)
// Zero-copy-ish POSIX shm; producer drops frames when full (GUI offline is harmless).
#pragma once
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <atomic>
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace shmring {

constexpr uint32_t kMagic = 0x51504553; // 'SPEQ'

struct Header {
    uint32_t magic;
    uint32_t channels;
    uint32_t sampleRate;
    uint64_t capacity;                  // frames
    std::atomic<uint64_t> head{0};      // total frames written (monotonic)
    std::atomic<uint64_t> tail{0};      // total frames consumed
};

class ShmFrameRing {
public:
    // producer side
    static ShmFrameRing* create(const char* name, uint32_t channels, uint32_t sampleRate,
                                uint64_t capacityFrames) {
        // macOS: O_TRUNC 打开被其他进程 mmap 的对象会返回 EINVAL。
        // 先 unlink 保证总是新建对象；旧持有者的映射变成孤儿（不崩溃），
        // GUI 通过 head 停滞检测自动重挂新对象。
        shm_unlink(name);   // ignore error (may not exist)
        int fd = shm_open(name, O_CREAT | O_RDWR | O_TRUNC, 0600);
        if (fd < 0) {
            fprintf(stderr, "[shm] shm_open(%s) failed: %s\n", name, strerror(errno));
            return nullptr;
        }
        const size_t total = sizeof(Header) + capacityFrames * channels * sizeof(float);
        if (ftruncate(fd, (off_t)total) != 0) {
            fprintf(stderr, "[shm] ftruncate(%zu) failed: %s\n", total, strerror(errno));
            ::close(fd);
            return nullptr;
        }
        void* mem = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        ::close(fd);
        if (mem == MAP_FAILED) {
            fprintf(stderr, "[shm] mmap(%zu) failed: %s\n", total, strerror(errno));
            return nullptr;
        }

        auto* h = new (mem) Header();
        h->magic = kMagic;
        h->channels = channels;
        h->sampleRate = sampleRate;
        h->capacity = capacityFrames;
        auto* r = new ShmFrameRing((Header*)mem, capacityFrames * channels, true);
        r->name_ = name;    // owner 析构时 shm_unlink 需要真实名字
        return r;
    }

    // consumer side
    static ShmFrameRing* open(const char* name) {
        int fd = shm_open(name, O_RDWR, 0600);
        if (fd < 0) return nullptr;
        struct stat st{};
        if (fstat(fd, &st) != 0 || (size_t)st.st_size <= sizeof(Header)) { ::close(fd); return nullptr; }
        const size_t total = (size_t)st.st_size;
        void* mem = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        ::close(fd);
        if (mem == MAP_FAILED) return nullptr;
        auto* h = (Header*)mem;
        if (h->magic != kMagic) { munmap(mem, total); return nullptr; }
        auto* r = new ShmFrameRing(h, h->capacity * h->channels, false);
        r->name_ = name;
        return r;
    }

    void destroy() {
        if (!hdr_) return;
        const size_t total = sizeof(Header) + hdr_->capacity * hdr_->channels * sizeof(float);
        if (owner_) shm_unlink(name_.c_str());
        munmap(hdr_, total);
        hdr_ = nullptr;
    }

    bool    ok()         const { return hdr_ != nullptr; }
    uint32_t channels()  const { return hdr_ ? hdr_->channels : 0; }
    uint32_t sampleRate()const { return hdr_ ? hdr_->sampleRate : 0; }
    uint64_t capacity()  const { return hdr_ ? hdr_->capacity : 0; }
    uint64_t headSeq()   const { return hdr_ ? hdr_->head.load(std::memory_order_acquire) : 0; }

    // producer: returns frames actually written (drops when GUI stalls)
    size_t write(const float* src, size_t frames) {
        if (!hdr_) return 0;
        const uint64_t cap = hdr_->capacity;
        size_t n = 0;
        while (n < frames) {
            const uint64_t head = hdr_->head.load(std::memory_order_relaxed);
            const uint64_t tail = hdr_->tail.load(std::memory_order_acquire);
            const uint64_t freeSpace = cap - (head - tail);
            if (freeSpace == 0) break;
            const uint64_t chunk = std::min<uint64_t>(frames - n, freeSpace);
            const uint64_t pos = head % cap;
            const uint64_t lin = std::min<uint64_t>(chunk, cap - pos);
            std::memcpy(buf_ + pos * hdr_->channels, src + n * hdr_->channels,
                        (size_t)lin * hdr_->channels * sizeof(float));
            if (chunk > lin)
                std::memcpy(buf_, src + (n + lin) * hdr_->channels,
                            (size_t)(chunk - lin) * hdr_->channels * sizeof(float));
            hdr_->head.store(head + chunk, std::memory_order_release);
            n += chunk;
        }
        return n;
    }

    // consumer: returns frames actually read
    size_t read(float* dst, size_t frames) {
        if (!hdr_) return 0;
        const uint64_t cap = hdr_->capacity;
        size_t n = 0;
        while (n < frames) {
            const uint64_t tail = hdr_->tail.load(std::memory_order_relaxed);
            const uint64_t head = hdr_->head.load(std::memory_order_acquire);
            const uint64_t avail = head - tail;
            if (avail == 0) break;
            const uint64_t chunk = std::min<uint64_t>(frames - n, avail);
            const uint64_t pos = tail % cap;
            const uint64_t lin = std::min<uint64_t>(chunk, cap - pos);
            std::memcpy(dst + n * hdr_->channels, buf_ + pos * hdr_->channels,
                        (size_t)lin * hdr_->channels * sizeof(float));
            if (chunk > lin)
                std::memcpy(dst + (n + lin) * hdr_->channels, buf_,
                            (size_t)(chunk - lin) * hdr_->channels * sizeof(float));
            hdr_->tail.store(tail + chunk, std::memory_order_release);
            n += chunk;
        }
        return n;
    }

private:
    ShmFrameRing(Header* h, size_t, bool owner) : hdr_(h), buf_((float*)(h + 1)), owner_(owner) {}
    Header* hdr_ = nullptr;
    float*  buf_ = nullptr;
    bool    owner_ = false;
    std::string name_;
};

} // namespace shmring
