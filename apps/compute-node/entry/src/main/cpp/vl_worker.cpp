// HDC-started local inference process. The HAP exchanges files in its private
// cache; this process drops root before handling any model or request data.
#include "vl_runtime.h"
#include "vl_worker_client.h"
#include "vl_worker_protocol.h"

#include <csignal>
#include <cstdlib>
#include <grp.h>
#include <linux/capability.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <sys/wait.h>

namespace {

volatile sig_atomic_t stopping = 0;
void StopSignal(int) { stopping = 1; }

struct ActiveJob {
    std::mutex mutex;
    std::string directory;
    uint32_t clientPid = 0;
    uint64_t deadline = 0;
    uint64_t cancelSince = 0;
    pid_t child = 0;
};

class EventWriter {
public:
    explicit EventWriter(const std::string& path, bool append = false)
    {
        fd = open(path.c_str(), O_WRONLY | O_CREAT | (append ? O_APPEND : O_EXCL) | O_NOFOLLOW | O_CLOEXEC, 0600);
    }
    ~EventWriter() { if (fd >= 0) close(fd); }
    bool IsOpen() const { return fd >= 0; }
    void Send(vlworker::EventType type, const std::string& payload)
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (fd < 0 || payload.size() > vlworker::MAX_EVENT) return;
        const vlworker::Frame frame {type, static_cast<uint32_t>(payload.size())};
        if (!Write(&frame, sizeof(frame)) || !Write(payload.data(), payload.size())) {
            close(fd);
            fd = -1;
        }
    }
private:
    bool Write(const void* data, size_t length)
    {
        size_t offset = 0;
        while (offset < length) {
            const ssize_t n = write(fd, static_cast<const char*>(data) + offset, length - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return false;
            offset += static_cast<size_t>(n);
        }
        return true;
    }
    int fd = -1;
    std::mutex mutex;
};

struct Stream {
    EventWriter& writer;
    Qwen2vlEngine* engine;
    std::mutex mutex;
    std::string previous;
    unsigned repeated = 0;
    bool cut = false;
};

void StreamToken(void* context, const char* text)
{
    if (text == nullptr) return;
    auto& stream = *static_cast<Stream*>(context);
    std::lock_guard<std::mutex> lock(stream.mutex);
    if (stream.cut) return;
    if (stream.previous == text) ++stream.repeated;
    else { stream.previous = text; stream.repeated = 1; }
    if (stream.repeated >= 8) {
        stream.cut = true;
        qwen2vl_cancel(stream.engine);
        return;
    }
    stream.writer.Send(vlworker::EventType::Response, text);
}

bool DropPrivileges(uid_t uid, bool driverGroups)
{
    if (getuid() == 0) {
        const gid_t groups[] = {1097, 3099, 3070, 3094};
        if (setgroups(driverGroups ? 4 : 2, groups) != 0 || setgid(uid) != 0 || setuid(uid) != 0) return false;
    }
    if (getuid() != uid || geteuid() != uid) return false;
    __user_cap_header_struct header {_LINUX_CAPABILITY_VERSION_3, 0};
    __user_cap_data_struct capabilities[2] {};
    return syscall(SYS_capset, &header, capabilities) == 0;
}

void Watch(const std::string& directory, const vlworker::Ready& identity, ActiveJob& active,
    std::atomic<bool>& finished)
{
    uint64_t heartbeat = 0;
    while (!finished.load()) {
        const uint64_t now = vlworker::NowMs();
        if (now - heartbeat >= 1000) {
            vlworker::Ready ready = identity;
            ready.heartbeat = now;
            if (!vlworker::WriteFile(directory + "/ready", &ready, sizeof(ready))) stopping = 1;
            heartbeat = now;
        }
        std::string stop;
        if (vlworker::ReadFile(directory + "/stop", sizeof(identity.instance), stop) &&
            stop.size() == sizeof(identity.instance) && memcmp(stop.data(), identity.instance, stop.size()) == 0) stopping = 1;
        bool cancel = false;
        {
            std::lock_guard<std::mutex> lock(active.mutex);
            if (!active.directory.empty()) {
                cancel = stopping || now >= active.deadline || vlworker::RegularFile(active.directory + "/cancel") ||
                    (kill(active.clientPid, 0) != 0 && errno == ESRCH);
                if (cancel && !active.cancelSince) active.cancelSince = now;
                if (active.cancelSince && now - active.cancelSince > 15000) {
                    // Only kill the child that this supervisor launched.
                    // Keep the request service available after an SDK hang.
                    if (active.child > 0) kill(active.child, SIGKILL);
                }
                if (cancel && active.child > 0) kill(active.child, SIGTERM);
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void ServeJob(const std::string& job, const vlworker::Request& request,
    const std::string& modelDir, ActiveJob& active)
{
    const int claim = open((job + "/claimed").c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (claim < 0) return;
    close(claim);
    EventWriter writer(job + "/events");
    if (!writer.IsOpen()) return;
    std::string model, prompt, image;
    std::string error;
    std::string reason = "error";
    if (!vlworker::ReadFile(job + "/model", 127, model) || model != vlworker::ModelName(modelDir) ||
        !vlworker::ReadFile(job + "/prompt", vlworker::MAX_PROMPT, prompt) || prompt.empty() ||
        !vlworker::ReadFile(job + "/image.jpg", vlworker::MAX_IMAGE, image) || image.empty()) {
        error = "本机推理请求无效或超过大小限制";
    } else {
        image.clear();
        {
            std::lock_guard<std::mutex> lock(active.mutex);
            active.directory = job;
            active.clientPid = request.clientPid;
            active.deadline = request.created + request.timeout;
            active.cancelSince = 0;
        }
        auto& state = S();
        if (vlworker::RegularFile(job + "/cancel") || stopping) reason = "cancelled";
        else if (EnsureEngine(state, modelDir, error)) {
            if (vlworker::RegularFile(job + "/cancel") || stopping) reason = "cancelled";
            else {
                Stream stream {writer, state.engine};
                const int rc = qwen2vl_chat(state.engine, (job + "/image.jpg").c_str(), prompt.c_str(), StreamToken, &stream);
                if (rc == QWEN2VL_OK || (rc == QWEN2VL_ERR_CANCELLED && stream.cut)) reason = "stop";
                else if (rc == QWEN2VL_ERR_CANCELLED) reason = "cancelled";
                else {
                    const char* detail = qwen2vl_last_error(state.engine);
                    error = detail != nullptr && detail[0] ? detail : "本机图文推理失败";
                }
            }
        }
        if (vlworker::RegularFile(job + "/cancel") || stopping) reason = "cancelled";
        {
            std::lock_guard<std::mutex> lock(active.mutex);
            if (vlworker::NowMs() >= active.deadline) { error = "本机图文推理超时"; reason = "error"; }
            active.directory.clear();
            active.cancelSince = 0;
        }
        // Each job exits its own process. Recreating only the SDK handle did
        // not reliably reset the private runtime's process-global state.
    }
    if (!error.empty()) writer.Send(vlworker::EventType::Error, error);
    vlworker::WriteFile(job + "/done", "done");
    writer.Send(vlworker::EventType::End, reason);
}

int RunSingleJob(const std::string& cacheDir, const std::string& modelDir, const std::string& job)
{
    setbuf(stdout, nullptr);
    setbuf(stderr, nullptr);
    const std::string prefix = cacheDir + "/vl-worker/jobs/";
    if (job.compare(0, prefix.size(), prefix) != 0 || !vlworker::JobName(job.substr(prefix.size()))) return 20;
    std::string bytes;
    if (!vlworker::ReadFile(job + "/request", sizeof(vlworker::Request), bytes) ||
        bytes.size() != sizeof(vlworker::Request)) return 21;
    vlworker::Request request;
    memcpy(&request, bytes.data(), sizeof(request));
    signal(SIGTERM, StopSignal);
    signal(SIGINT, StopSignal);
    const std::string sdkLogDir = cacheDir + "/qwenvl-sdk";
    const std::string sdkErrorLog = sdkLogDir + "/llm_err.log";
    SDK_LOG_DIR = sdkLogDir.c_str();
    SDK_ERROR_LOG = sdkErrorLog.c_str();
    ActiveJob active;
    std::atomic<bool> finished {false};
    std::thread canceller([&] {
        while (!finished.load()) {
            if (stopping || vlworker::RegularFile(job + "/cancel") ||
                vlworker::NowMs() >= request.created + request.timeout) {
                auto& state = S();
                std::lock_guard<std::mutex> lock(state.mutex);
                if (state.engine != nullptr) qwen2vl_cancel(state.engine);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });
    ServeJob(job, request, modelDir, active);
    finished.store(true);
    canceller.join();
    return 0;
}

void LaunchJob(const std::string& job, const vlworker::Request& request,
    const std::string& cacheDir, const std::string& modelDir, ActiveJob& active)
{
    // Prepare every argument before fork: the supervisor has a heartbeat
    // thread, so the child may only call async-signal-safe functions until exec.
    const std::string uid = std::to_string(getuid());
    const char* args[] = {"/proc/self/exe", "job", uid.c_str(), cacheDir.c_str(), modelDir.c_str(), job.c_str(), nullptr};
    std::unique_lock<std::mutex> lock(active.mutex);
    active.directory = job;
    active.clientPid = request.clientPid;
    active.deadline = request.created + request.timeout;
    active.cancelSince = 0;
    const pid_t child = fork();
    if (child == 0) {
        execv(args[0], const_cast<char* const*>(args));
        _exit(127);
    }
    active.child = child;
    lock.unlock();
    int status = 0;
    if (child > 0) {
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    lock.lock();
    active.child = 0;
    active.directory.clear();
    active.cancelSince = 0;
    lock.unlock();
    if (!vlworker::RegularFile(job + "/done")) {
        EventWriter writer(job + "/events", true);
        const bool cancelled = stopping || vlworker::RegularFile(job + "/cancel");
        if (!cancelled) writer.Send(vlworker::EventType::Error,
            vlworker::NowMs() >= request.created + request.timeout ? "本机图文推理超时" : "图文推理进程异常退出，请重试");
        vlworker::WriteFile(job + "/done", "done");
        writer.Send(vlworker::EventType::End, cancelled ? "cancelled" : "error");
    }
    printf("request process pid=%d exit_status=%d\n", child, status);
}

int Serve(const std::string& cacheDir, const std::string& modelDir)
{
    const std::string directory = cacheDir + "/vl-worker";
    const std::string model = vlworker::ModelName(modelDir);
    if (model.empty() || model.size() >= sizeof(vlworker::Ready::model) ||
        !vlworker::EnsureDirectory(directory) || !vlworker::EnsureDirectory(directory + "/jobs")) return 10;
    const int lock = open((directory + "/lock").c_str(), O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) { if (lock >= 0) close(lock); return 11; }
    const int log = open((directory + "/worker.log").c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (log < 0) { close(lock); return 12; }
    dup2(log, STDOUT_FILENO);
    dup2(log, STDERR_FILENO);
    close(log);
    setbuf(stdout, nullptr);
    setbuf(stderr, nullptr);
    vlworker::Ready identity;
    identity.pid = getpid();
    memcpy(identity.model, model.data(), model.size());
    unsigned char nonce[16];
    if (getrandom(nonce, sizeof(nonce), 0) != sizeof(nonce)) { close(lock); return 13; }
    const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < sizeof(nonce); i++) {
        identity.instance[2 * i] = hex[nonce[i] >> 4];
        identity.instance[2 * i + 1] = hex[nonce[i] & 15];
    }
    unlink((directory + "/stop").c_str());
    if (!vlworker::WriteFile(directory + "/enabled", "VLW1")) { close(lock); return 14; }
    signal(SIGTERM, StopSignal);
    signal(SIGINT, StopSignal);
    signal(SIGHUP, SIG_IGN);
    printf("worker pid=%d uid=%d model=%s\n", getpid(), getuid(), model.c_str());
    ActiveJob active;
    std::atomic<bool> finished {false};
    std::thread watcher(Watch, directory, identity, std::ref(active), std::ref(finished));
    while (!stopping) {
        std::string release;
        if (vlworker::ReadFile(directory + "/release", sizeof(identity.instance), release)) {
            unlink((directory + "/release").c_str());
            if (release.size() == sizeof(identity.instance) &&
                memcmp(release.data(), identity.instance, release.size()) == 0) {
                puts("worker idle; request process releases model on exit");
            }
        }
        std::vector<std::string> jobs;
        DIR* entries = opendir((directory + "/jobs").c_str());
        if (entries != nullptr) {
            while (dirent* entry = readdir(entries)) {
                if (vlworker::JobName(entry->d_name)) jobs.emplace_back(entry->d_name);
                if (jobs.size() >= 128) break;
            }
            closedir(entries);
        }
        std::sort(jobs.begin(), jobs.end());
        for (const auto& name : jobs) {
            const std::string job = directory + "/jobs/" + name;
            struct stat st {};
            if (lstat(job.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) continue;
            std::string bytes;
            if (!vlworker::ReadFile(job + "/request", sizeof(vlworker::Request), bytes) ||
                bytes.size() != sizeof(vlworker::Request)) continue;
            vlworker::Request request;
            memcpy(&request, bytes.data(), sizeof(request));
            const uint64_t now = vlworker::NowMs();
            if (request.magic != vlworker::MAGIC || request.version != vlworker::VERSION ||
                memcmp(request.instance, identity.instance, sizeof(identity.instance)) != 0 ||
                request.created > now || now - request.created > vlworker::MAX_REQUEST_MS + 15000 ||
                request.timeout == 0 || request.timeout > vlworker::MAX_REQUEST_MS || request.clientPid == 0) {
                vlworker::RemoveJob(job);
                continue;
            }
            if (vlworker::RegularFile(job + "/claimed") || vlworker::RegularFile(job + "/done")) continue;
            LaunchJob(job, request, cacheDir, modelDir, active);
            if (stopping) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    finished.store(true);
    watcher.join();
    unlink((directory + "/ready").c_str());
    close(lock);
    puts("worker stopped");
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 4) { fprintf(stderr, "usage: vl-worker serve|status|stop|infer UID CACHE [MODEL] [IMAGE] [CANCEL_MS]\n"); return 2; }
    const std::string mode = argv[1];
    char* end = nullptr;
    const unsigned long parsed = strtoul(argv[2], &end, 10);
    if (end == argv[2] || *end || parsed < 20000000 || parsed >= 30000000) return 3;
    const uid_t uid = parsed;
    const std::string cache = argv[3];
    struct stat st {};
    if (lstat(cache.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != uid) return 4;
    if (!DropPrivileges(uid, mode == "serve")) { perror("drop worker privileges"); return 5; }
    const std::string directory = cache + "/vl-worker";
    if (mode == "serve" && argc == 5) return Serve(cache, argv[4]);
    // exec preserves the supervisor's driver groups; DropPrivileges above
    // clears capabilities again. Avoid private SDK static destructors entirely.
    if (mode == "job" && argc == 6) _exit(RunSingleJob(cache, argv[4], argv[5]));
    if (mode == "release") { vlworker::Release(cache); puts("RELEASE_REQUESTED"); return 0; }
    if (mode == "status" || mode == "stop") {
        vlworker::Ready ready;
        if (!vlworker::ReadReady(directory, ready)) { puts("NOT_RUNNING"); return mode == "status" ? 6 : 0; }
        if (mode == "stop") {
            if (!vlworker::WriteFile(directory + "/stop", ready.instance, sizeof(ready.instance))) return 7;
            printf("STOP_REQUESTED pid=%u\n", ready.pid);
        } else printf("READY pid=%u model=%s\n", ready.pid, ready.model);
        return 0;
    }
    if (mode == "infer" && argc >= 6) {
        const uint64_t start = vlworker::NowMs();
        const unsigned cancelMs = argc > 6 ? strtoul(argv[6], nullptr, 10) : 0;
        const vlworker::Result result = vlworker::Infer(cache, argv[4], argv[5], "描述图片中最主要的物体，只回答一句话。",
            [](const char* text) { fputs(text, stdout); fflush(stdout); },
            [start, cancelMs] { return cancelMs && vlworker::NowMs() - start >= cancelMs; });
        printf("\nRESULT handled=%d finish=%s error=%s elapsed_ms=%llu\n", result.handled,
            result.finishReason.c_str(), result.error.c_str(), static_cast<unsigned long long>(vlworker::NowMs() - start));
        return result.handled && result.error.empty() &&
            result.finishReason == (cancelMs ? "cancelled" : "stop") ? 0 : 8;
    }
    return 2;
}
