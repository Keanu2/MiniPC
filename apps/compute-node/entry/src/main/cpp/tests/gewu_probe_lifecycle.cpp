// c++ -std=c++17 -pthread gewu_probe_lifecycle.cpp -o /tmp/gewu-probe-test && /tmp/gewu-probe-test
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#define GEWU_PROBE_TEST
#define OH_LOG_Print(...) ((void)0)
constexpr int OH_QOS_GEWU_OK = 0;
struct Result { int error; int session; int request; };
static std::atomic<int> creates{0}, submits{0}, destroys{0}, aborts{0};
static std::atomic<bool> holdCreate{false}, inCreate{false};
static int mode = 0;
static void* savedContext;
static void (*savedCallback)(void*, const char*);
static void CompleteJob(uintptr_t);
static void Notify(bool);
static Result OH_QoS_GewuCreateSession(const char*) {
    ++creates;
    inCreate = true;
    while (holdCreate) std::this_thread::yield();
    return {mode == 1 ? 401 : 0, 1, 0};
}
static Result OH_QoS_GewuSubmitRequest(int, const char*, void (*cb)(void*, const char*), void* ctx) {
    ++submits;
    savedCallback = cb; savedContext = ctx;
    if (mode == 4) return {0, 1, 2};
    cb(ctx, "synchronous response");
    if (mode == 0) CompleteJob(reinterpret_cast<uintptr_t>(ctx));
    return {mode == 2 ? 401 : 0, 1, 2};
}
static int OH_QoS_GewuAbortRequest(int, int) { ++aborts; return 0; }
static int OH_QoS_GewuDestroySession(int) { ++destroys; return 0; }
void TestUtf8Carry();
#include "../gewu_probe.cpp"
static void WaitDone() {
    for (int i = 0; i < 5000; ++i) {
        { std::lock_guard<std::mutex> lock(State().mutex); if (!State().started) return; }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(false && "worker never completed");
}
int main() {
    TestUtf8Carry();
    const auto root = std::filesystem::temp_directory_path() / "gewu-probe-lifecycle";
    std::filesystem::create_directories(root);
    for (auto name : {"api_config.json", "tokenizer.json", "params"}) std::ofstream(root / name) << "x";
    auto start = [&] { return Begin(root.string(), "{}", (root / "events.jsonl").string()); };
    for (int i = 0; i < 20; ++i) { assert(start()); WaitDone(); }
    assert(creates == 20 && submits == 20 && destroys == 20);
    {
      std::lock_guard<std::mutex> lock(State().mutex);
      int timedResponses=0;
      for (const auto& event : State().events) {
        if (event.find("\"event\":\"response\"") == std::string::npos) continue;
        assert(event.find("\"elapsedMs\":") != std::string::npos);
        ++timedResponses;
      }
      assert(timedResponses==20);
    }
    auto oldContext = savedContext;
    mode = 3; holdCreate = true; inCreate = false;
    assert(start()); assert(start()); assert(start());
    while (!inCreate) std::this_thread::yield();
    Notify(true); holdCreate = false; WaitDone();
    assert(submits == 20 && destroys == 23); // three jobs cancelled before submit
    mode = 1; assert(start()); WaitDone(); // create failure still allows retry
    mode = 2; assert(start()); WaitDone(); // submit failure destroys session
    const int submittedBefore = submits.load();
    mode = 3; assert(start());
    while (submits.load() == submittedBefore) std::this_thread::yield();
    savedCallback(oldContext, "STALE");
    { std::lock_guard<std::mutex> lock(State().mutex);
      for (const auto& e : State().events) assert(e.find("STALE") == std::string::npos); }
    Notify(true); WaitDone(); assert(aborts == 1);
    mode = 0; assert(start()); WaitDone();
    mode = 3;
    const uintptr_t a = start();
    const uintptr_t b = start();
    const uintptr_t c = start();
    assert(a && b && c && a != b && b != c && a != c);
    Notify(true); WaitDone();
    mode = 0;
    assert(Begin("/does-not-exist", "{}", (root / "events.jsonl").string())); WaitDone();
    assert(start()); WaitDone();
    mode = 3;
    const int abortsBeforeSingle = aborts.load();
    assert(Begin(root.string(), "{\"stream\":false}", (root / "events.jsonl").string())); WaitDone();
    assert(aborts == abortsBeforeSingle); // the one stream:false callback is terminal
    mode = 4;
    const int abortsBeforeDeadline = aborts.load();
    assert(Begin(root.string(), "{}", (root / "events.jsonl").string(), 1)); WaitDone();
    assert(aborts == abortsBeforeDeadline + 1); // requester deadline shortens the wait
    mode = 0;
    probeWaitSeconds = 1;
    mode = 4;
    const int createsBefore = creates.load();
    const int submitsBefore = submits.load();
    const int abortsBefore = aborts.load();
    const int destroysBefore = destroys.load();
    assert(start()); WaitDone();
    assert(creates == createsBefore + 1 && submits == submitsBefore + 1);
    assert(aborts == abortsBefore + 1 && destroys == destroysBefore + 1);
    // Keyed requests keep one native session; unkeyed requests are unchanged.
    {
        mode = 0; probeWaitSeconds = 45;
        const auto events = (root / "events.jsonl").string();
        const int c0 = creates.load(), s0 = submits.load(), d0 = destroys.load();
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k1")); WaitDone();
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k1")); WaitDone();
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k1")); WaitDone();
        assert(creates == c0 + 1 && submits == s0 + 3 && destroys == d0); // one session, three requests
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k2")); WaitDone();
        assert(creates == c0 + 2 && destroys == d0); // another key gets its own session
        CloseSession("k1");
        assert(destroys == d0 + 1);
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k1")); WaitDone();
        assert(creates == c0 + 3); // closed key starts fresh
        // A stalled keyed request destroys its session instead of caching it.
        mode = 4; probeWaitSeconds = 1;
        const int d1 = destroys.load();
        assert(Begin(root.string(), "{}", events, 1, "k1")); WaitDone();
        assert(destroys == d1 + 1);
        mode = 0; probeWaitSeconds = 45;
        const int c1 = creates.load();
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k1")); WaitDone();
        assert(creates == c1 + 1); // the stalled session was not reused
        // Submit failure never leaves a cached session behind.
        mode = 2;
        const int d2 = destroys.load();
        assert(Begin(root.string(), "{}", events, 0, "k3")); WaitDone();
        assert(destroys == d2 + 1);
        mode = 0;
        const int c2 = creates.load();
        assert(Begin(root.string(), "{\"stream\":false}", events, 0, "k3")); WaitDone();
        assert(creates == c2 + 1);
        // The cache holds at most four idle sessions; the oldest is evicted.
        const int d3 = destroys.load();
        for (const char* key : {"a1", "a2", "a3", "a4", "a5", "a6"}) {
            assert(Begin(root.string(), "{\"stream\":false}", events, 0, key)); WaitDone();
        }
        assert(destroys > d3);
        { std::lock_guard<std::mutex> lock(g_cachedMutex); assert(g_cached.size() <= 4); }
        for (const char* key : {"k1", "k2", "k3", "a1", "a2", "a3", "a4", "a5", "a6"}) CloseSession(key);
        { std::lock_guard<std::mutex> lock(g_cachedMutex); assert(g_cached.empty()); }
    }
    {
        std::lock_guard<std::mutex> lock(State().mutex);
        State().log.close();
    }
    std::filesystem::remove_all(root);
    std::cout << "PASS repeated requests, concurrent jobs, pre-submit cancellation, synchronous callbacks, failures, late callbacks, retry, single-shot completion, requester deadline\n";
}
