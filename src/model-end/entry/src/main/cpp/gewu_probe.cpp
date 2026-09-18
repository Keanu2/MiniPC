#ifndef GEWU_PROBE_TEST
#include <napi/native_api.h>
#include <qos/qos.h>
#include <hilog/log.h>
#endif
#include <cstdint>
#include <cstdio>
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
};

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

static int64_t NowMs()
{
    timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
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
    std::string line = "{\"event\":" + Quote(event) + ",\"id\":" + Quote(std::to_string(id)) +
        ",\"t\":" + std::to_string(t) + ",\"payload\":" + Quote(payload) + "}";
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

static void OnResponse(void* context, const char* response)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const uintptr_t id = reinterpret_cast<uintptr_t>(context);
    Job* job = FindJobLocked(state, id);
    if (job == nullptr || !job->active || response == nullptr) return;
    EventLocked(state, id, "response", response);
    if (!job->gotResponse) {
        job->gotResponse = true;
        EventLocked(state, id, "mem_first", ReadMem());
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

static void Run(std::string modelPath, std::string request, uintptr_t id, Job* owned)
{
    auto& state = State();
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
    std::string attributes = "{\"model\":" + Quote(modelPath) +
        ",\"eval_settings\":{\"backend\":\"knpu\",\"max_ctx\":2048}}";
    Event(id, "attributes", attributes);
    auto created = OH_QoS_GewuCreateSession(attributes.c_str());
    Event(id, "create", std::to_string(created.error));
    Event(id, "mem_after_create", ReadMem());
    if (created.error != OH_QOS_GEWU_OK) {
        FinishJob(*owned, "create_failed");
        return;
    }
    bool shouldSubmit = false;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (owned->id == id && !owned->cancelled) {
            owned->active = true;
            shouldSubmit = true;
        }
    }
    if (shouldSubmit) {
        Event(id, "request", request);
        auto submitted = OH_QoS_GewuSubmitRequest(created.session, request.c_str(), OnResponse,
            reinterpret_cast<void*>(id));
        Event(id, "submit", std::to_string(submitted.error));
        if (submitted.error == OH_QOS_GEWU_OK) {
            std::unique_lock<std::mutex> lock(state.mutex);
            state.wake.wait(lock, [owned, id] {
                return owned->id != id || owned->completed || owned->cancelled;
            });
            bool abort = owned->id == id && owned->cancelled && !owned->completed;
            owned->active = false;
            lock.unlock();
            if (abort) Event(id, "abort", std::to_string(OH_QoS_GewuAbortRequest(created.session, submitted.request)));
        }
    }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (owned->id == id) owned->active = false;
    }
    Event(id, "destroy", std::to_string(OH_QoS_GewuDestroySession(created.session)));
    FinishJob(*owned, "closed");
}

static uintptr_t Begin(const std::string& modelPath, const std::string& request, const std::string& path)
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
    job->running = true;
    state.started = true;
    const uintptr_t id = job->id;
    try {
        std::thread(Run, modelPath, request, id, job).detach();
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
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string modelPath, request, path;
    if (argc != 3 || !StringArg(env, args[0], modelPath) || !StringArg(env, args[1], request) ||
        !StringArg(env, args[2], path) || path.find('\0') != std::string::npos) {
        napi_throw_type_error(env, nullptr, "Expected model path, request and log path strings");
        return nullptr;
    }
    const uintptr_t id = Begin(modelPath, request, path);
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

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeEvents", nullptr, TakeEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"complete", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 4, properties);
    return exports;
}
static napi_module module = {1, 0, nullptr, Init, "gewu_probe", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterProbe() { napi_module_register(&module); }

#endif
