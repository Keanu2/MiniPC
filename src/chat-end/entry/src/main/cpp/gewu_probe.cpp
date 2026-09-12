#ifndef GEWU_PROBE_TEST
#include <napi/native_api.h>
#include <qos/qos.h>
#include <hilog/log.h>
#endif
#include <cstdint>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>

struct Probe {
    std::mutex mutex;
    std::condition_variable wake;
    bool started = false;
    uintptr_t generation = 0;
    bool completed = false;
    bool cancelled = false;
    bool active = false;
    std::ofstream log;
    std::vector<std::string> events;
};

// Process-lifetime manager; opaque generations never point at request memory.
static Probe& State() { static auto* state = new Probe; return *state; }

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

static void EventLocked(Probe& state, const std::string& event, const std::string& payload)
{
    std::string line = "{\"event\":" + Quote(event) + ",\"payload\":" + Quote(payload) + "}";
    state.log << line << std::endl;
    state.events.push_back(line);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xD003F00, "GewuProbe", "%{public}s", line.c_str());
}

static void Event(const std::string& event, const std::string& payload)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    EventLocked(state, event, payload);
}

static void OnResponse(void* context, const char* response)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.active || reinterpret_cast<uintptr_t>(context) != state.generation ||
        response == nullptr) return;
    EventLocked(state, "response", response);
}

static void Finish(const std::string& reason)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    state.active = false;
    EventLocked(state, "end", reason);
    state.log.close();
    state.started = false;
}

static void Run(std::string modelPath, std::string request, uintptr_t generation)
{
    auto& state = State();
    for (const char* name : {"api_config.json", "tokenizer.json", "params"}) {
        std::string path = modelPath + "/" + name;
        struct stat details {};
        std::ifstream file(path, std::ios::binary);
        char firstByte = 0;
        if (stat(path.c_str(), &details) != 0 || !file.get(firstByte)) {
            Event("file_error", name);
            Finish("model_unreadable");
            return;
        }
        Event("file_readable", std::string(name) + " bytes=" + std::to_string(details.st_size));
    }
    std::string attributes = "{\"model\":" + Quote(modelPath) +
        ",\"eval_settings\":{\"backend\":\"knpu\",\"max_ctx\":2048}}";
    Event("attributes", attributes);
    auto created = OH_QoS_GewuCreateSession(attributes.c_str());
    Event("create", std::to_string(created.error));
    if (created.error != OH_QOS_GEWU_OK) { Finish("create_failed"); return; }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.active = !state.cancelled;
    }
    bool shouldSubmit;
    { std::lock_guard<std::mutex> lock(state.mutex); shouldSubmit = state.active; }
    if (shouldSubmit) {
        Event("request", request);
        auto submitted = OH_QoS_GewuSubmitRequest(created.session, request.c_str(), OnResponse, reinterpret_cast<void*>(generation));
        Event("submit", std::to_string(submitted.error));
        if (submitted.error == OH_QOS_GEWU_OK) {
            std::unique_lock<std::mutex> lock(state.mutex);
            state.wake.wait(lock, [&state] { return state.completed || state.cancelled; });
            bool abort = state.cancelled && !state.completed;
            state.active = false;
            lock.unlock();
            if (abort) Event("abort", std::to_string(OH_QoS_GewuAbortRequest(created.session, submitted.request)));
        }
    }
    { std::lock_guard<std::mutex> lock(state.mutex); state.active = false; }
    Event("destroy", std::to_string(OH_QoS_GewuDestroySession(created.session)));
    Finish("closed");
}

static bool Begin(const std::string& modelPath, const std::string& request, const std::string& path)
{
    auto& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.started) return false;
    state.log.clear();
    state.log.open(path, std::ios::out | std::ios::trunc);
    if (!state.log.is_open()) return false;
    state.started = true;
    state.completed = false;
    state.cancelled = false;
    state.active = false;
    state.events.clear();
    ++state.generation;
    try {
        std::thread(Run, modelPath, request, state.generation).detach();
    } catch (...) {
        state.started = false;
        state.log.close();
        return false;
    }
    return true;
}

static void Notify(bool cancel)
{
    auto& state = State();
    { std::lock_guard<std::mutex> lock(state.mutex);
      if (!state.started) return;
      if (cancel) { state.cancelled = true; state.active = false; }
      else state.completed = true; }
    state.wake.notify_one();
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
    bool started = Begin(modelPath, request, path);
    napi_value value;
    napi_get_boolean(env, started, &value);
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

static napi_value Signal(napi_env env, bool cancel)
{
    Notify(cancel);
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}
static napi_value Complete(napi_env env, napi_callback_info) { return Signal(env, false); }
static napi_value Cancel(napi_env env, napi_callback_info) { return Signal(env, true); }

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
