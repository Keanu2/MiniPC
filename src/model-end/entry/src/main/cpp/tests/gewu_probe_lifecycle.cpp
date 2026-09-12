// c++ -std=c++17 -pthread gewu_probe_lifecycle.cpp -o /tmp/gewu-probe-test && /tmp/gewu-probe-test
#include <atomic>
#include <cassert>
#include <chrono>
#include <filesystem>
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
    cb(ctx, "synchronous response");
    if (mode == 0) Notify(false); // completion before SubmitRequest returns
    return {mode == 2 ? 401 : 0, 1, 2};
}
static int OH_QoS_GewuAbortRequest(int, int) { ++aborts; return 0; }
static int OH_QoS_GewuDestroySession(int) { ++destroys; return 0; }
#include "../gewu_probe.cpp"
static void WaitDone() {
    for (int i = 0; i < 5000; ++i) {
        { std::lock_guard<std::mutex> lock(State().mutex); if (!State().started) return; }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(false && "worker never completed");
}
int main() {
    const auto root = std::filesystem::temp_directory_path() / "gewu-probe-lifecycle";
    std::filesystem::create_directories(root);
    for (auto name : {"api_config.json", "tokenizer.json", "params"}) std::ofstream(root / name) << "x";
    auto start = [&] { return Begin(root.string(), "{}", (root / "events.jsonl").string()); };
    for (int i = 0; i < 20; ++i) { assert(start()); WaitDone(); }
    assert(creates == 20 && submits == 20 && destroys == 20);
    auto oldContext = savedContext;
    mode = 3; holdCreate = true; inCreate = false;
    assert(start()); assert(!start());
    while (!inCreate) std::this_thread::yield();
    Notify(true); holdCreate = false; WaitDone();
    assert(submits == 20 && destroys == 21); // cancel before submit
    mode = 1; assert(start()); WaitDone(); // create failure still allows retry
    mode = 2; assert(start()); WaitDone(); // submit failure destroys session
    mode = 3; assert(start());
    for (;;) {
        { std::lock_guard<std::mutex> lock(State().mutex);
          bool submitted = false;
          for (const auto& e : State().events) if (e.find("\"submit\"") != std::string::npos) submitted = true;
          if (submitted) break; }
        std::this_thread::yield();
    }
    savedCallback(oldContext, "STALE");
    { std::lock_guard<std::mutex> lock(State().mutex);
      for (const auto& e : State().events) assert(e.find("STALE") == std::string::npos); }
    Notify(true); WaitDone(); assert(aborts == 1);
    mode = 0; assert(start()); WaitDone();
    assert(Begin("/does-not-exist", "{}", (root / "events.jsonl").string())); WaitDone();
    assert(start()); WaitDone();
    std::filesystem::remove_all(root);
    std::cout << "PASS repeated requests, busy, pre-submit cancellation, synchronous callbacks, failures, late callbacks, retry\n";
}
