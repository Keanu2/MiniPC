#include <napi/native_api.h>
#include "vl_runtime.h"

namespace {
void Run(std::string modelDir, std::string imagePath, std::string prompt, uintptr_t generation)
{
    auto t0 = std::chrono::steady_clock::now();
    auto& s = S();
    {
        char db[320];
        snprintf(db, sizeof(db), "Run in: imageLen=%zu imageHead=%.40s promptHead=%.60s",
            imagePath.size(), imagePath.c_str(), prompt.c_str());
        AppendDiag(db);
    }
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.active && reinterpret_cast<uintptr_t>(&s) == generation) {
            EventLocked(s, "load", "loading");
        }
    }

    // VL runs in the HAP process. Device access is configured separately by
    // the administrator; an old worker marker must never change this route.
    std::string failure;
    if (!EnsureEngine(s, modelDir, failure)) {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.active && reinterpret_cast<uintptr_t>(&s) == generation) {
            EventLocked(s, "error", failure);
            EventLocked(s, "end", "error");
            s.active = false;
            s.started = false;
        }
        return;
    }

    Qwen2vlEngine* e = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        e = s.engine;
    }
    int rc = qwen2vl_chat(e, imagePath.c_str(), prompt.c_str(), OnToken, &s);

    {
        char db[200];
        const std::string ler = qwen2vl_last_error(e);
        snprintf(db, sizeof(db), "chat rc=%d %lldms gen=%llu last_err=%s",
            rc,
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count(),
            (unsigned long long)generation, ler.c_str());
        AppendDiag(db);
    }

    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.active && reinterpret_cast<uintptr_t>(&s) == generation) {
        if (rc == QWEN2VL_ERR_CANCELLED) {
            // M25：重复循环被 OnToken 自动掐断视为正常结束（stop），
            // 上层不会显示"已停止生成"；用户主动取消仍是 cancelled。
            EventLocked(s, "end", s.repetitionCut ? "stop" : "cancelled");
        } else if (rc != QWEN2VL_OK) {
            const std::string accessFailure = DriverAccessFailure();
            EventLocked(s, "error", accessFailure.empty() ? qwen2vl_last_error(e) : accessFailure);
            EventLocked(s, "end", "error");
        } else {
            EventLocked(s, "end", "stop");
        }
        s.active = false;
        s.started = false;
    }
    s.wake.notify_all();
}

/* ---------------- NAPI ---------------- */

napi_value Start(napi_env env, napi_callback_info info)
{
    AppendDiag("NAPI-Start entered");
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string modelDir, imagePath, prompt;
    auto readStr = [&](napi_value v, std::string& out) {
        size_t len = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &len);
        out.resize(len);
        napi_get_value_string_utf8(env, v, out.data(), len + 1, &len);
    };
    if (argc >= 1) {
        readStr(argv[0], modelDir);
    }
    if (argc >= 2) {
        readStr(argv[1], imagePath);
    }
    if (argc >= 3) {
        readStr(argv[2], prompt);
    }

    auto& s = S();
    uintptr_t gen = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.started) {
            napi_value ret;
            napi_get_boolean(env, false, &ret);
            return ret;
        }
        s.started = true;
        s.active = true;
        s.cancelled = false;
        s.completed = false;
        s.events.clear();
        s.recentPieces.clear();
        s.repetitionCut = false;
        s.generation = reinterpret_cast<uintptr_t>(&s);
        gen = s.generation;
        EventLocked(s, "load", "loading");
    }

    std::thread([modelDir, imagePath, prompt, gen] {
        Run(modelDir, imagePath, prompt, gen);
    }).detach();

    napi_value ret;
    napi_get_boolean(env, true, &ret);
    return ret;
}

napi_value TakeEvents(napi_env env, napi_callback_info info)
{
    auto& s = S();
    std::lock_guard<std::mutex> lock(s.mutex);
    napi_value arr;
    napi_create_array_with_length(env, s.events.size(), &arr);
    for (size_t i = 0; i < s.events.size(); ++i) {
        napi_value v;
        napi_create_string_utf8(env, s.events[i].c_str(), s.events[i].size(), &v);
        napi_set_element(env, arr, i, v);
    }
    s.events.clear();
    return arr;
}

napi_value Complete(napi_env env, napi_callback_info info)
{
    auto& s = S();
    std::lock_guard<std::mutex> lock(s.mutex);
    s.completed = true;
    s.wake.notify_all();
    return nullptr;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    auto& s = S();
    Qwen2vlEngine* e = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        s.cancelled = true;
        e = s.engine;
    }
    if (e != nullptr) {
        qwen2vl_cancel(e);
    }
    return nullptr;
}

napi_value Release(napi_env env, napi_callback_info info)
{
    auto& s = S();
    Qwen2vlEngine* e = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.started) s.cancelled = true;
        e = s.engine;
        s.engine = nullptr;
        s.engineModelDir.clear();
        s.engineFailed = false;
        s.engineFailure.clear();
    }
    if (e != nullptr) {
        qwen2vl_destroy(e);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    // available：本模块是真引擎还是空实现。两条 CMake 分支的模块名与导出面完全一致，
    // ArkTS 侧靠它把「引擎未编入」和「模型未部署」区分开，避免误导性报错。
    napi_value available;
    napi_get_boolean(env, true, &available);
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeEvents", nullptr, TakeEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"complete", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"available", nullptr, nullptr, nullptr, nullptr, available, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

} // namespace

static napi_module module = {1, 0, nullptr, Init, "qwenvl_engine", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterQwenVlEngine()
{
    // Initialize SDK logging inside EnsureEngine, once an actual request runs
    // in the application process. Module preload must not initialize SDK state
    // or bind a logger before the app's writable cache is ready.
    napi_module_register(&module);
}
