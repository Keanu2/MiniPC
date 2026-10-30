// ============================================================================
//  llm_bridge.cpp — AKI 桥接层: 把 qos.h 的 C 函数指针回调
//  包装为 ArkTS 可调用的 aki::SafetyCallback。
// ============================================================================

#include "qos.h"
#include <aki/jsbind.h>
#include <atomic>
#include <cstdint>
#include <dlfcn.h>
#include <exception>
#include <hilog/log.h>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// --- Callback 生命周期管理 ---

struct CallbackEntry {
    OH_QoS_GewuSession session;
    OH_QoS_GewuRequest request;
    aki::SafetyCallback<void(std::string)> callback;
    std::atomic<bool> active {true};
    // Tail bytes of a multibyte character split across streamed callbacks.
    std::string utf8Pending;
};

using CallbackEntryPtr = std::unique_ptr<CallbackEntry>;

static std::unordered_map<OH_QoS_GewuRequest, CallbackEntryPtr> g_callbackMap;
// Gewu owns the opaque context pointer and does not expose a callback-drained
// acknowledgement. Keep inactive contexts alive until process exit so a late
// OnChatResponse cannot dereference memory released by abort/destroy.
static std::vector<CallbackEntryPtr> g_retiredCallbacks;
static std::mutex g_mutex;

using EnableCollaborationFn = OH_QoS_GewuErrorCode (*)(const char*);
using DisableCollaborationFn = OH_QoS_GewuErrorCode (*)();

static void* GetQosLibraryHandle() {
    // libllm.so is loaded as a NAPI addon. On HarmonyOS its DT_NEEDED
    // dependencies can remain outside RTLD_DEFAULT's global lookup scope until
    // another Gewu entry point loads the client implementation. Resolve the
    // optional collaboration APIs from libqos itself so capability detection
    // does not depend on which Gewu call happened first in this process.
    static void* handle = []() -> void* {
        dlerror();
        void* qos = dlopen("libqos.so", RTLD_NOW | RTLD_LOCAL);
        if (qos == nullptr) {
            const char* error = dlerror();
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "LlmBridge",
                "Failed to open libqos.so: %{public}s", error == nullptr ? "unknown error" : error);
        }
        return qos;
    }();
    return handle;
}

template<typename Function>
static Function ResolveQosSymbol(const char* name) {
    void* qos = GetQosLibraryHandle();
    if (qos == nullptr) {
        return nullptr;
    }
    dlerror();
    void* symbol = dlsym(qos, name);
    const char* error = dlerror();
    if (error != nullptr || symbol == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "LlmBridge",
            "Failed to resolve %{public}s from libqos.so: %{public}s", name,
            error == nullptr ? "symbol not found" : error);
        return nullptr;
    }
    return reinterpret_cast<Function>(symbol);
}

static EnableCollaborationFn ResolveEnableCollaboration() {
    static auto fn = ResolveQosSymbol<EnableCollaborationFn>("OH_QoS_GewuEnableCollaboration");
    return fn;
}

static DisableCollaborationFn ResolveDisableCollaboration() {
    static auto fn = ResolveQosSymbol<DisableCollaborationFn>("OH_QoS_GewuDisableCollaboration");
    return fn;
}

// Streamed chunks can split a multibyte character inside "content". Hold the incomplete tail and
// prepend it to the next chunk so JS never sees a replacement character. Callbacks of one request
// are delivered serially, so the per-entry state needs no lock.
static bool ContentSpan(const std::string& json, size_t& open, size_t& close) {
    const std::string key = "\"content\"";
    size_t pos = json.find(key);
    if (pos == std::string::npos) return false;
    pos += key.size();
    auto skip = [&]() { while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n' || json[pos] == '\r')) ++pos; };
    skip();
    if (pos >= json.size() || json[pos] != ':') return false;
    ++pos;
    skip();
    if (pos >= json.size() || json[pos] != '"') return false;
    open = pos++;
    while (pos < json.size()) {
        if (json[pos] == '\\') { if (pos + 1 >= json.size()) return false; pos += 2; continue; }
        if (json[pos] == '"') { close = pos; return true; }
        ++pos;
    }
    return false;
}

static size_t CompleteUtf8End(const std::string& bytes) {
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
        else { ++index; continue; }
        if (index + need > length) return index;
        bool complete = true;
        for (size_t extra = 1; extra < need; ++extra) {
            if ((data[index + extra] & 0xC0) != 0x80) { complete = false; break; }
        }
        if (!complete) { ++index; continue; }
        index += need;
    }
    return length;
}

static std::string CarryUtf8(CallbackEntry& entry, const std::string& raw) {
    size_t open = 0, close = 0;
    if (!ContentSpan(raw, open, close)) return raw;
    const std::string content = entry.utf8Pending + raw.substr(open + 1, close - open - 1);
    const size_t keep = CompleteUtf8End(content);
    entry.utf8Pending = content.substr(keep);
    return raw.substr(0, open + 1) + content.substr(0, keep) + raw.substr(close);
}
static void OnResponseTrampoline(void* context, const char* response) {
    if (context == nullptr || response == nullptr) return;
    auto* entry = static_cast<CallbackEntry*>(context);
    if (!entry->active.load(std::memory_order_acquire)) return;
    try {
        entry->callback(CarryUtf8(*entry, std::string(response)));
        // 阻塞直到 ArkTS 回调执行完毕
    } catch (const std::exception&) {
        // env 失效、JS 回调超时等情况均静默丢弃；不能让 IPC
        // observer 线程上的异常终止 App 进程。
    } catch (...) {
        // Native callback boundaries must never propagate exceptions.
    }
}

static void RetireCallback(OH_QoS_GewuRequest req) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_callbackMap.find(req);
    if (it == g_callbackMap.end()) return;
    it->second->active.store(false, std::memory_order_release);
    g_retiredCallbacks.emplace_back(std::move(it->second));
    g_callbackMap.erase(it);
}

static void RetireSessionCallbacks(OH_QoS_GewuSession session) {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (auto it = g_callbackMap.begin(); it != g_callbackMap.end();) {
        if (it->second->session != session) {
            ++it;
            continue;
        }
        it->second->active.store(false, std::memory_order_release);
        g_retiredCallbacks.emplace_back(std::move(it->second));
        it = g_callbackMap.erase(it);
    }
}

// --- 暴露给 ArkTS 的桥接函数 ---

// Keep unsigned Gewu handles away from the AKI boundary. The vendored AKI
// version has no NapiValue<uint32_t> specialization and treats uint32_t as a
// bound C++ object when converting a return value, which dereferences a null
// Class<unsigned int> reference. int64_t preserves the complete uint32_t
// handle range while mapping to an ArkTS number through AKI's numeric path.
struct CreateSessionResult { int64_t session; int32_t error; };

CreateSessionResult llmCreateSession(std::string attributes) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "GEWU",
        "Loopy CreateSession attributes=%{public}s", attributes.c_str());
    auto r = OH_QoS_GewuCreateSession(attributes.c_str());
    if (r.error != OH_QOS_GEWU_OK) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, "GEWU",
            "Loopy CreateSession failed error=%{public}d attributes=%{public}s",
            static_cast<int>(r.error), attributes.c_str());
    } else {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "GEWU",
            "Loopy CreateSession succeeded session=%{public}u", r.session);
    }
    return {static_cast<int64_t>(r.session), static_cast<int32_t>(r.error)};
}

int32_t llmDestroySession(int64_t session) {
    RetireSessionCallbacks(static_cast<OH_QoS_GewuSession>(session));
    return static_cast<int32_t>(OH_QoS_GewuDestroySession(static_cast<OH_QoS_GewuSession>(session)));
}

struct SubmitRequestResult { int64_t request; int32_t error; };

SubmitRequestResult llmSubmitRequest(
    int64_t session, std::string request,
    aki::SafetyCallback<void(std::string)> callback
) {
    CallbackEntryPtr entry(new CallbackEntry{
        static_cast<OH_QoS_GewuSession>(session),
        0,
        callback
    });
    auto* context = entry.get();
    auto r = OH_QoS_GewuSubmitRequest(
        static_cast<OH_QoS_GewuSession>(session),
        request.c_str(),
        OnResponseTrampoline,
        context
    );
    if (r.error == OH_QOS_GEWU_OK) {
        entry->request = r.request;
        std::lock_guard<std::mutex> lock(g_mutex);
        auto existing = g_callbackMap.find(r.request);
        if (existing != g_callbackMap.end()) {
            existing->second->active.store(false, std::memory_order_release);
            g_retiredCallbacks.emplace_back(std::move(existing->second));
            g_callbackMap.erase(existing);
        }
        g_callbackMap.emplace(r.request, std::move(entry));
    }
    return {static_cast<int64_t>(r.request), static_cast<int32_t>(r.error)};
}

int32_t llmAbortRequest(int64_t session, int64_t request) {
    // Make callbacks inert before asking Gewu to abort. Some runtime versions
    // emit a final observer callback synchronously from AbortRequest.
    RetireCallback(static_cast<OH_QoS_GewuRequest>(request));
    auto ret = OH_QoS_GewuAbortRequest(
        static_cast<OH_QoS_GewuSession>(session),
        static_cast<OH_QoS_GewuRequest>(request)
    );
    return static_cast<int32_t>(ret);
}

int32_t llmEnableCollaboration(std::string info) {
    auto fn = ResolveEnableCollaboration();
    if (fn == nullptr) {
        return static_cast<int32_t>(OH_QOS_GEWU_NOSYS);
    }
    return static_cast<int32_t>(fn(info.c_str()));
}

int32_t llmDisableCollaboration() {
    auto fn = ResolveDisableCollaboration();
    if (fn == nullptr) {
        return static_cast<int32_t>(OH_QOS_GEWU_NOSYS);
    }
    return static_cast<int32_t>(fn());
}

bool llmIsCollaborationSupported() {
    return ResolveEnableCollaboration() != nullptr && ResolveDisableCollaboration() != nullptr;
}

// --- AKI 绑定注册 ---

JSBIND_CLASS(CreateSessionResult) {
    JSBIND_PROPERTY(session);
    JSBIND_PROPERTY(error);
}

JSBIND_CLASS(SubmitRequestResult) {
    JSBIND_PROPERTY(request);
    JSBIND_PROPERTY(error);
}

JSBIND_GLOBAL() {
    JSBIND_FUNCTION(llmCreateSession);
    JSBIND_FUNCTION(llmDestroySession);
    JSBIND_FUNCTION(llmSubmitRequest);
    JSBIND_FUNCTION(llmAbortRequest);
    JSBIND_FUNCTION(llmEnableCollaboration);
    JSBIND_FUNCTION(llmDisableCollaboration);
    JSBIND_FUNCTION(llmIsCollaborationSupported);
}

JSBIND_ADDON(llm);  // 生成 libllm.so
