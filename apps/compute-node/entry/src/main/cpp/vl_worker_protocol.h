#pragma once

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace vlworker {

constexpr uint32_t MAGIC = 0x31574c56; // VLW1, local little-endian protocol
constexpr uint32_t VERSION = 1;
constexpr size_t MAX_IMAGE = 8 * 1024 * 1024;
constexpr size_t MAX_PROMPT = 64 * 1024;
constexpr size_t MAX_EVENT = 16 * 1024;
constexpr uint64_t MAX_REQUEST_MS = 180000;
constexpr uint64_t READY_MAX_AGE_MS = 6000;

struct Ready {
    uint32_t magic = MAGIC;
    uint32_t version = VERSION;
    uint32_t pid = 0;
    uint32_t reserved = 0;
    uint64_t heartbeat = 0;
    char instance[32] {};
    char model[128] {};
};
static_assert(sizeof(Ready) == 184);

struct Request {
    uint32_t magic = MAGIC;
    uint32_t version = VERSION;
    uint32_t clientPid = 0;
    uint32_t reserved = 0;
    uint64_t created = 0;
    uint64_t timeout = MAX_REQUEST_MS;
    char instance[32] {};
};
static_assert(sizeof(Request) == 64);

enum class EventType : uint32_t { Response = 1, Error = 2, End = 3 };
struct Frame { EventType type; uint32_t length; };
static_assert(sizeof(Frame) == 8);

inline uint64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

inline std::string ModelName(std::string path)
{
    while (!path.empty() && path.back() == '/') path.pop_back();
    return path.substr(path.find_last_of('/') + 1);
}

inline bool RegularFile(const std::string& path)
{
    struct stat st {};
    return lstat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid();
}

inline bool EnsureDirectory(const std::string& path)
{
    if (mkdir(path.c_str(), 0700) != 0 && errno != EEXIST) return false;
    const int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st {};
    const bool ok = fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == getuid() &&
        fchmod(fd, 0700) == 0;
    close(fd);
    return ok;
}

inline bool ReadFile(const std::string& path, size_t limit, std::string& out)
{
    out.clear();
    const int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st {};
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 &&
        static_cast<uint64_t>(st.st_size) <= limit;
    if (ok) {
        out.resize(static_cast<size_t>(st.st_size));
        size_t offset = 0;
        while (offset < out.size()) {
            const ssize_t n = read(fd, &out[offset], out.size() - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = false; break; }
            offset += static_cast<size_t>(n);
        }
    }
    close(fd);
    if (!ok) out.clear();
    return ok;
}

inline bool WriteFile(const std::string& path, const void* data, size_t size)
{
    static std::atomic<unsigned> sequence {0};
    const std::string temporary = path + ".tmp-" + std::to_string(getpid()) + "-" +
        std::to_string(++sequence);
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    size_t offset = 0;
    while (offset < size) {
        const ssize_t n = write(fd, static_cast<const char*>(data) + offset, size - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        offset += static_cast<size_t>(n);
    }
    bool ok = close(fd) == 0 && offset == size;
    if (ok) ok = rename(temporary.c_str(), path.c_str()) == 0;
    if (!ok) unlink(temporary.c_str());
    return ok;
}

inline bool WriteFile(const std::string& path, const std::string& data)
{
    return WriteFile(path, data.data(), data.size());
}

inline bool ReadReady(const std::string& directory, Ready& ready)
{
    std::string bytes;
    if (!ReadFile(directory + "/ready", sizeof(Ready), bytes) || bytes.size() != sizeof(Ready)) return false;
    memcpy(&ready, bytes.data(), sizeof(ready));
    const uint64_t now = NowMs();
    return ready.magic == MAGIC && ready.version == VERSION && ready.pid > 0 &&
        memchr(ready.model, 0, sizeof(ready.model)) != nullptr && ready.model[0] != 0 &&
        ready.heartbeat <= now && now - ready.heartbeat <= READY_MAX_AGE_MS;
}

inline bool JobName(const std::string& name)
{
    return name.size() > 2 && name.size() < 80 && name.compare(0, 2, "r-") == 0 &&
        name.find_first_not_of("r-0123456789abcdef") == std::string::npos;
}

inline void RemoveJob(const std::string& directory)
{
    // All names are fixed; never follow client-supplied paths or recurse.
    for (const char* name : {"request", "model", "prompt", "image.jpg", "events", "cancel", "claimed", "done"}) {
        unlink((directory + "/" + name).c_str());
    }
    rmdir(directory.c_str());
}

} // namespace vlworker
