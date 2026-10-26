#ifndef GEWU_PROBE_TEST
#include <napi/native_api.h>
#include <qos/qos.h>
#include <hilog/log.h>
#endif
#include <cstdint>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <memory>
#include <vector>
#include <sys/stat.h>

struct Job {
    uintptr_t id = 0;
    bool running = false;
    bool completed = false;
    bool cancelled = false;
    bool active = false;
    bool gotResponse = false;
    // stream:false delivers exactly one callback carrying the whole answer, so
    // that callback is terminal; waiting for a JS round trip only adds stalls.
    bool singleShot = false;
    int waitSeconds = 0;
    int64_t startedMs = 0;
    std::string utf8Pending;
};

#ifdef GEWU_PROBE_TEST
int probeWaitSeconds = 45;
#endif

struct Probe {
    std::mutex mutex;
    std::condition_variable wake;
    bool started = false;
    std::vector<std::unique_ptr<Job>> jobs;
    std::ofstream log;
    std::vector<std::string> events;
    uintptr_t nextId = 0;
    int64_t t0 = 0;
};

static Probe& State() { static auto* state = new Probe; return *state; }

// Optional session reuse. A request that names a session key keeps its native session
// (and so its KV cache) for the next request with the same key. Without a key every
// request still creates and destroys its own session, exactly as before.
using SessionHandle = decltype(OH_QoS_GewuCreateSession("").session);
static constexpr size_t MAX_CACHED_SESSIONS = 4;
static constexpr int64_t SESSION_IDLE_MS = 180000;
struct CachedSession {
    std::string key;
    SessionHandle session;
    int64_t lastUsed = 0;
    bool inUse = false;
    bool drop = false;
};
static std::vector<CachedSession> g_cached;
static std::mutex g_cachedMutex;

static int64_t NowMs()
{
    timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

static void DestroyAll(const std::vector<SessionHandle>& doomed)
{
    for (const auto& handle : doomed) OH_QoS_GewuDestroySession(handle);
}

// Removes idle-expired entries; the caller destroys the returned handles outside the lock.
static void ExpireLocked(std::vector<SessionHandle>& doomed)
{
    const int64_t now = NowMs();
    for (size_t i = 0; i < g_cached.size();) {
        if (!g_cached[i].inUse && now - g_cached[i].lastUsed > SESSION_IDLE_MS) {
            doomed.push_back(g_cached[i].session);
            g_cached.erase(g_cached.begin() + static_cast<std::ptrdiff_t>(i));
        } else ++i;
    }
}

static void CloseSession(const std::string& key)
{
    std::vector<SessionHandle> doomed;
    {
        std::lock_guard<std::mutex> lock(g_cachedMutex);
        for (size_t i = 0; i < g_cached.size();) {
            if (g_cached[i].key != key) { ++i; continue; }
            if (g_cached[i].inUse) { g_cached[i].drop = true; ++i; continue; }
            doomed.push_back(g_cached[i].session);
            g_cached.erase(g_cached.begin() + static_cast<std::ptrdiff_t>(i));
        }
    }
    DestroyAll(doomed);
}

static int FieldKb(const std::string& line, const char* key)
{
    const size_t n = std::strlen(key);
    if (line.size() < n || line.compare(0, n, key) != 0) return -1;
    int kb = -1;
    return std::sscanf(line.c_str() + n, "%d", &kb) == 1 ? kb : -1;
}

static std::string ReadMem()
{
    int rss = -1, hwm = -1, swap = -1, pss = -1, swapPss = -1;
    std::ifstream status("/proc/self/status");
    std::string line;
    while (std::getline(status, line)) {
        int value = FieldKb(line, "VmRSS:");
        if (value >= 0) { rss = value; continue; }
        value = FieldKb(line, "VmHWM:");
        if (value >= 0) { hwm = value; continue; }
        value = FieldKb(line, "VmSwap:");
        if (value >= 0) swap = value;
    }
    std::ifstream rollup("/proc/self/smaps_rollup");
    while (std::getline(rollup, line)) {
        int value = FieldKb(line, "Pss:");
        if (value >= 0) { pss = value; continue; }
        value = FieldKb(line, "SwapPss:");
        if (value >= 0) swapPss = value;
    }
    return "rss_kb=" + std::to_string(rss) + " hwm_kb=" + std::to_string(hwm) +
        " swap_kb=" + std::to_string(swap) + " pss_kb=" + std::to_string(pss) +
        " swap_pss_kb=" + std::to_string(swapPss);
}

static std::string Quote(const std::string& value)
{
    std::string result = "\"";
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') { result += '\\'; result += c; }
        else if (c < 32) {
            const char* hex = "0123456789abcdef";
            result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15];
        } else result += c;
    }
    return result + '"';
}

static int RunningCountLocked(Probe& state)
{
    int count = 0;
    for (const auto& job : state.jobs) if (job && job->running) ++count;
    return count;
}

static Job* FindJobLocked(Probe& state, uintptr_t id)
{
    if (id == 0) return nullptr;
    for (auto& job : state.jobs) {
        if (job && job->running && job->id == id) return job.get();
    }
    return nullptr;
}

static Job* OccupyJobLocked(Probe& state)
{
    for (auto& job : state.jobs) {
        if (job && !job->running) {
            *job = Job{};
            return job.get();
        }
    }
    state.jobs.push_back(std::make_unique<Job>());
    return state.jobs.back().get();
}

static void EventLocked(Probe& state, uintptr_t id, const std::string& event, const std::string& payload)
{
    const int64_t t = state.t0 == 0 ? 0 : NowMs() - state.t0;
    const Job* job = FindJobLocked(state, id);
    const std::string elapsed = job == nullptr ? "" :
        ",\"elapsedMs\":" + std::to_string(NowMs() - job->startedMs);
    std::string line = "{\"event\":" + Quote(event) + ",\"id\":" + Quote(std::to_string(id)) +
        ",\"t\":" + std::to_string(t) + elapsed + ",\"payload\":" + Quote(payload) + "}";
    if (state.log.is_open()) state.log << line << std::endl;
    state.events.push_back(line);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xD003F00, "GewuProbe", "%{public}s", line.c_str());
}

static void Event(uintptr_t id, const std::string& event, const std::string& payload)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    EventLocked(state, id, event, payload);
}

static bool ContentSpan(const std::string& json, size_t& openQuote, size_t& closeQuote)
{
    const std::string key = "\"content\"";
    size_t pos = json.find(key);
    if (pos == std::string::npos) return false;
    pos += key.size();
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n' || json[pos] == '\r')) ++pos;
    if (pos >= json.size() || json[pos] != ':') return false;
    ++pos;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n' || json[pos] == '\r')) ++pos;
    if (pos >= json.size() || json[pos] != '"') return false;
    openQuote = pos;
    ++pos;
    while (pos < json.size()) {
        if (json[pos] == '\\') {
            if (pos + 1 >= json.size()) return false;
            pos += 2;
            continue;
        }
        if (json[pos] == '"') {
            closeQuote = pos;
            return true;
        }
        ++pos;
    }
    return false;
}

static size_t CompleteUtf8End(const std::string& bytes)
{
    const auto* data = reinterpret_cast<const unsigned char*>(bytes.data());
    size_t index = 0;
    const size_t length = bytes.size();
    while (index < length) {
        const unsigned char lead = data[index];
        size_t need = 1;
        if (lead < 0x80) need = 1;
        else if ((lead & 0xE0) == 0xC0 && lead >= 0xC2) need = 2;
        else if ((lead & 0xF0) == 0xE0) need = 3;
        else if ((lead & 0xF8) == 0xF0 && lead <= 0xF4) need = 4;
        else {
            ++index;
            continue;
        }
        if (index + need > length) return index;
        bool complete = true;
        for (size_t extra = 1; extra < need; ++extra) {
            if ((data[index + extra] & 0xC0) != 0x80) {
                complete = false;
                break;
            }
        }
        if (!complete) {
            ++index;
            continue;
        }
        index += need;
    }
    return length;
}

static std::string RepairResponse(Job& job, const std::string& raw)
{
    size_t openQuote = 0;
    size_t closeQuote = 0;
    if (!ContentSpan(raw, openQuote, closeQuote)) return raw;
    const std::string content = job.utf8Pending + raw.substr(openQuote + 1, closeQuote - openQuote - 1);
    const size_t keep = CompleteUtf8End(content);
    job.utf8Pending = content.substr(keep);
    return raw.substr(0, openQuote + 1) + content.substr(0, keep) + raw.substr(closeQuote);
}

static void OnResponse(void* context, const char* response)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const uintptr_t id = reinterpret_cast<uintptr_t>(context);
    Job* job = FindJobLocked(state, id);
    if (job == nullptr || !job->active || response == nullptr) return;
    EventLocked(state, id, "response", RepairResponse(*job, response));
    if (!job->gotResponse) {
        job->gotResponse = true;
        EventLocked(state, id, "mem_first", ReadMem());
    }
    if (job->singleShot) {
        job->completed = true;
        state.wake.notify_all();
    }
}

static void FinishJob(Job& job, const std::string& reason)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    job.active = false;
    EventLocked(state, job.id, "mem_end", ReadMem());
    EventLocked(state, job.id, "end", reason);
    job.running = false;
    state.started = RunningCountLocked(state) > 0;
}

static int DefaultWaitSeconds()
{
#ifdef GEWU_PROBE_TEST
    return probeWaitSeconds;
#else
    // Both streaming and single-shot requests stay inside the chat hard budget.
    // A missing finish marker must time out without reissuing the same prompt.
    return 150;
#endif
}

// Callers derive the wait from the requester's deadline; never exceed the default.
static int WaitSecondsFor(int requested)
{
    const int ceiling = DefaultWaitSeconds();
    return requested > 0 && requested < ceiling ? requested : ceiling;
}

static bool WaitUntilDone(uintptr_t id, Job* owned, int seconds)
{
    auto& state = State();
    std::unique_lock<std::mutex> lock(state.mutex);
    return state.wake.wait_for(lock, std::chrono::seconds(seconds), [owned, id] {
        return owned->id != id || owned->completed || owned->cancelled;
    });
}

// No completion callback before the wait ends means this generation did not
// finish. Abort it once. Submitting the same prompt again does not finish it.
enum class Attempt { Done, Stalled, CreateFailed, SubmitFailed };

// Returns the session to use. reused is true when a cached session was taken instead of created.
static bool AcquireSession(const std::string& key, const std::string& attributes, uintptr_t id,
    SessionHandle& session, bool& reused)
{
    reused = false;
    std::vector<SessionHandle> doomed;
    if (!key.empty()) {
        std::lock_guard<std::mutex> lock(g_cachedMutex);
        ExpireLocked(doomed);
        for (auto& entry : g_cached) {
            if (entry.key == key && !entry.inUse && !entry.drop) {
                entry.inUse = true;
                session = entry.session;
                reused = true;
                break;
            }
        }
    }
    DestroyAll(doomed);
    if (reused) {
        Event(id, "reuse", "0");
        Event(id, "mem_after_create", ReadMem());
        return true;
    }
    auto created = OH_QoS_GewuCreateSession(attributes.c_str());
    Event(id, "create", std::to_string(created.error));
    Event(id, "mem_after_create", ReadMem());
    if (created.error != OH_QOS_GEWU_OK) return false;
    session = created.session;
    if (!key.empty()) {
        std::vector<SessionHandle> evicted;
        {
            std::lock_guard<std::mutex> lock(g_cachedMutex);
            while (g_cached.size() >= MAX_CACHED_SESSIONS) {
                size_t oldest = g_cached.size();
                for (size_t i = 0; i < g_cached.size(); ++i) {
                    if (g_cached[i].inUse) continue;
                    if (oldest == g_cached.size() || g_cached[i].lastUsed < g_cached[oldest].lastUsed) oldest = i;
                }
                if (oldest == g_cached.size()) break;
                evicted.push_back(g_cached[oldest].session);
                g_cached.erase(g_cached.begin() + static_cast<std::ptrdiff_t>(oldest));
            }
            CachedSession entry;
            entry.key = key;
            entry.session = session;
            entry.lastUsed = NowMs();
            entry.inUse = true;
            g_cached.push_back(entry);
        }
        DestroyAll(evicted);
    }
    return true;
}

// keep=true leaves a keyed session cached for the next request; otherwise it is destroyed.
static void ReleaseSession(const std::string& key, SessionHandle session, bool keep, uintptr_t id)
{
    bool destroy = true;
    if (!key.empty()) {
        std::lock_guard<std::mutex> lock(g_cachedMutex);
        for (size_t i = 0; i < g_cached.size(); ++i) {
            if (g_cached[i].key != key || !g_cached[i].inUse) continue;
            if (keep && !g_cached[i].drop) {
                g_cached[i].inUse = false;
                g_cached[i].lastUsed = NowMs();
                destroy = false;
            } else {
                g_cached.erase(g_cached.begin() + static_cast<std::ptrdiff_t>(i));
            }
            break;
        }
    }
    if (destroy) Event(id, "destroy", std::to_string(OH_QoS_GewuDestroySession(session)));
    else Event(id, "keep", "0");
}

static Attempt SubmitOnce(const std::string& attributes, const std::string& request, uintptr_t id, Job* owned,
    const std::string& sessionKey)
{
    auto& state = State();
    SessionHandle session {};
    bool reused = false;
    if (!AcquireSession(sessionKey, attributes, id, session, reused)) return Attempt::CreateFailed;
    bool shouldSubmit = false;
    int waitSeconds = DefaultWaitSeconds();
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (owned->id == id) waitSeconds = owned->waitSeconds;
        if (owned->id == id && !owned->cancelled) {
            owned->active = true;
            owned->utf8Pending.clear();
            shouldSubmit = true;
        }
    }
    bool stalled = false;
    if (shouldSubmit) {
        Event(id, "request", request);
        auto submitted = OH_QoS_GewuSubmitRequest(session, request.c_str(), OnResponse,
            reinterpret_cast<void*>(id));
        Event(id, "submit", std::to_string(submitted.error));
        if (submitted.error != OH_QOS_GEWU_OK) {
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                if (owned->id == id) owned->active = false;
            }
            ReleaseSession(sessionKey, session, false, id);
            return Attempt::SubmitFailed;
        }
        bool signaled = WaitUntilDone(id, owned, waitSeconds);
        bool grace = false;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            grace = owned->id == id && owned->gotResponse && !owned->completed && !owned->cancelled;
        }
        if (grace) signaled = WaitUntilDone(id, owned, 5) || signaled;
        bool abort = false;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            const bool finished = owned->id != id || owned->completed;
            stalled = !finished && !owned->cancelled && !signaled;
            abort = !finished && (owned->cancelled || stalled);
            if (abort) owned->active = false;
        }
        if (abort) {
            const std::string result = std::to_string(OH_QoS_GewuAbortRequest(session, submitted.request));
            Event(id, stalled ? "stall" : "abort", result);
        }
    }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (owned->id == id) owned->active = false;
    }
    bool keep = false;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        keep = shouldSubmit && !stalled && !owned->cancelled && owned->id == id && owned->completed;
    }
    ReleaseSession(sessionKey, session, keep, id);
    return stalled ? Attempt::Stalled : Attempt::Done;
}

static void Run(std::string modelPath, std::string request, uintptr_t id, Job* owned, std::string sessionKey)
{
    for (const char* name : {"api_config.json", "tokenizer.json", "params"}) {
        std::string path = modelPath + "/" + name;
        struct stat details {};
        std::ifstream file(path, std::ios::binary);
        char firstByte = 0;
        if (stat(path.c_str(), &details) != 0 || !file.get(firstByte)) {
            Event(id, "file_error", name);
            FinishJob(*owned, "model_unreadable");
            return;
        }
        Event(id, "file_readable", std::string(name) + " bytes=" + std::to_string(details.st_size));
    }
    Event(id, "mem_begin", ReadMem());
    const std::string attributes = "{\"model\":" + Quote(modelPath) +
        ",\"eval_settings\":{\"backend\":\"knpu\",\"max_ctx\":32768}}";
    Event(id, "attributes", attributes);
    const Attempt attempt = SubmitOnce(attributes, request, id, owned, sessionKey);
    if (attempt == Attempt::CreateFailed) FinishJob(*owned, "create_failed");
    else if (attempt == Attempt::Stalled) FinishJob(*owned, "stalled");
    else FinishJob(*owned, "closed");
}

static uintptr_t Begin(const std::string& modelPath, const std::string& request, const std::string& path,
    int waitSeconds = 0, const std::string& sessionKey = "")
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.log.is_open()) {
        state.log.clear();
        state.log.open(path, std::ios::out | std::ios::trunc);
        if (!state.log.is_open()) return 0;
        state.t0 = NowMs();
        EventLocked(state, 0, "log_open", ReadMem());
    }
    Job* job = OccupyJobLocked(state);
    job->id = ++state.nextId;
    job->startedMs = NowMs();
    job->running = true;
    job->singleShot = request.find("\"stream\":false") != std::string::npos;
    job->waitSeconds = WaitSecondsFor(waitSeconds);
    state.started = true;
    const uintptr_t id = job->id;
    try {
        std::thread(Run, modelPath, request, id, job, sessionKey).detach();
    } catch (...) {
        job->running = false;
        state.started = RunningCountLocked(state) > 0;
        return 0;
    }
    return id;
}

static void CompleteJob(uintptr_t id)
{
    auto& state = State();
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        Job* job = FindJobLocked(state, id);
        if (job == nullptr) return;
        job->completed = true;
    }
    state.wake.notify_all();
}

static void Notify(bool cancel)
{
    auto& state = State();
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.started) return;
        for (auto& item : state.jobs) {
            if (!item || !item->running) continue;
            if (cancel) { item->cancelled = true; item->active = false; }
            else item->completed = true;
        }
    }
    state.wake.notify_all();
}

static void CancelJob(uintptr_t id)
{
    if (id == 0) { Notify(true); return; }
    auto& state = State();
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        Job* job = FindJobLocked(state, id);
        if (job == nullptr) return;
        job->cancelled = true;
        job->active = false;
    }
    state.wake.notify_all();
}

#ifndef GEWU_PROBE_TEST
static bool StringArg(napi_env env, napi_value arg, std::string& result)
{
    size_t size = 0;
    if (napi_get_value_string_utf8(env, arg, nullptr, 0, &size) != napi_ok || size > 65536) return false;
    result.resize(size + 1);
    if (napi_get_value_string_utf8(env, arg, result.data(), result.size(), &size) != napi_ok) return false;
    result.resize(size);
    return true;
}

static bool IntArg(napi_env env, napi_value arg, int32_t& result)
{
    return napi_get_value_int32(env, arg, &result) == napi_ok;
}

static napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string modelPath, request, path;
    if (argc < 3 || argc > 5 || !StringArg(env, args[0], modelPath) || !StringArg(env, args[1], request) ||
        !StringArg(env, args[2], path) || path.find('\0') != std::string::npos) {
        napi_throw_type_error(env, nullptr, "Expected model path, request and log path strings");
        return nullptr;
    }
    int32_t waitSeconds = 0;
    if (argc >= 4 && !IntArg(env, args[3], waitSeconds)) waitSeconds = 0;
    std::string sessionKey;
    if (argc == 5 && (!StringArg(env, args[4], sessionKey) || sessionKey.size() > 128)) sessionKey.clear();
    const uintptr_t id = Begin(modelPath, request, path, waitSeconds, sessionKey);
    napi_value value;
    napi_create_int32(env, static_cast<int32_t>(id), &value);
    return value;
}

static napi_value TakeEvents(napi_env env, napi_callback_info)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    napi_value array;
    napi_create_array_with_length(env, state.events.size(), &array);
    for (size_t i = 0; i < state.events.size(); ++i) {
        napi_value value;
        napi_create_string_utf8(env, state.events[i].c_str(), state.events[i].size(), &value);
        napi_set_element(env, array, i, value);
    }
    state.events.clear();
    return array;
}

static napi_value Complete(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    if (argc == 1) IntArg(env, args[0], id);
    if (id > 0) CompleteJob(static_cast<uintptr_t>(id));
    else Notify(false);
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

static napi_value Cancel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    if (argc == 1) IntArg(env, args[0], id);
    CancelJob(static_cast<uintptr_t>(id));
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

static napi_value CloseSessionJs(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string key;
    if (argc == 1 && StringArg(env, args[0], key) && !key.empty()) CloseSession(key);
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeEvents", nullptr, TakeEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"complete", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeSession", nullptr, CloseSessionJs, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 5, properties);
    return exports;
}
static napi_module module = {1, 0, nullptr, Init, "gewu_probe", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterProbe() { napi_module_register(&module); }

#else
void TestUtf8Carry()
{
    Job split;
    const std::string head = std::string("{\"message\":{\"role\":\"assistant\",\"content\":\"") + "\xE6\xB7" +
        "\"},\"finish_reason\":null}";
    const std::string held = RepairResponse(split, head);
    if (split.utf8Pending.size() != 2 || held.find("\"content\":\"\"") == std::string::npos) std::abort();
    const std::string tail = std::string("{\"message\":{\"role\":\"assistant\",\"content\":\"") + "\xB1\xE5\x9C\xB3\xE5\x8C\x97" +
        "\"},\"finish_reason\":null}";
    const std::string joined = RepairResponse(split, tail);
    const std::string station = std::string("\xE6\xB7\xB1\xE5\x9C\xB3\xE5\x8C\x97");
    if (!split.utf8Pending.empty() || joined.find(station) == std::string::npos) std::abort();

    Job around;
    RepairResponse(around, std::string("{\"message\":{\"content\":\"") + "\xE6\x9D" + "\"}}");
    const std::string hangzhou = RepairResponse(around, std::string("{\"message\":{\"content\":\"") + "\xAD\xE5\xB7\x9E\xE4\xB8\x9C" + "\"}}");
    if (!around.utf8Pending.empty() || hangzhou.find(std::string("\xE6\x9D\xAD\xE5\xB7\x9E\xE4\xB8\x9C")) == std::string::npos) std::abort();

    Job whole;
    const std::string plain = "{\"message\":{\"content\":\"hello\"}}";
    if (RepairResponse(whole, plain) != plain || !whole.utf8Pending.empty()) std::abort();

    Job untouched;
    untouched.utf8Pending = "\xE6";
    if (RepairResponse(untouched, "synchronous response") != "synchronous response" || untouched.utf8Pending != "\xE6") std::abort();
}
#endif
