#include "vl_worker_client.h"
#include "vl_worker_protocol.h"

#include <thread>

namespace vlworker {

void Release(const std::string& cacheDir)
{
    const std::string directory = cacheDir + "/vl-worker";
    Ready ready;
    if (ReadReady(directory, ready)) WriteFile(directory + "/release", ready.instance, sizeof(ready.instance));
}

Result Infer(const std::string& cacheDir, const std::string& modelDir,
    const std::string& imagePath, const std::string& prompt,
    const std::function<void(const char*)>& token,
    const std::function<bool()>& cancelled)
{
    Result result;
    const std::string directory = cacheDir + "/vl-worker";
    if (!RegularFile(directory + "/enabled")) return result;
    result.handled = true;
    Ready ready;
    if (!ReadReady(directory, ready)) {
        result.error = "本机推理服务未运行，请重新启动算力服务";
        return result;
    }
    const std::string model = ModelName(modelDir);
    if (model != ready.model) {
        result.error = "本机推理服务加载的模型与当前模型不一致";
        return result;
    }
    std::string image;
    if (prompt.empty() || prompt.size() > MAX_PROMPT ||
        !ReadFile(imagePath, MAX_IMAGE, image) || image.empty()) {
        result.error = "图片无法读取，或图文请求超过大小限制";
        return result;
    }
    if (!EnsureDirectory(directory + "/jobs")) {
        result.error = "无法创建本机推理请求目录";
        return result;
    }
    static std::atomic<unsigned> sequence {0};
    char name[80];
    snprintf(name, sizeof(name), "r-%016llx-%x-%x", static_cast<unsigned long long>(NowMs()),
        static_cast<unsigned>(getpid()), ++sequence);
    const std::string job = directory + "/jobs/" + name;
    if (mkdir(job.c_str(), 0700) != 0) {
        result.error = "无法创建本机推理请求";
        return result;
    }
    Request request;
    request.clientPid = getpid();
    request.created = NowMs();
    memcpy(request.instance, ready.instance, sizeof(request.instance));
    if (!WriteFile(job + "/model", model) || !WriteFile(job + "/prompt", prompt) ||
        !WriteFile(job + "/image.jpg", image) || !WriteFile(job + "/request", &request, sizeof(request))) {
        RemoveJob(job);
        result.error = "写入本机推理请求失败";
        return result;
    }
    image.clear();
    int events = -1;
    off_t offset = 0;
    uint64_t cancelSince = 0;
    bool timedOut = false;
    bool terminal = false;
    while (!terminal) {
        const uint64_t now = NowMs();
        if (!cancelSince && (cancelled() || now - request.created >= request.timeout)) {
            timedOut = now - request.created >= request.timeout;
            cancelSince = now;
            WriteFile(job + "/cancel", "cancel");
        }
        if (cancelSince && now - cancelSince >= 5000) {
            result.finishReason = timedOut ? "error" : "cancelled";
            if (timedOut) result.error = "本机图文推理超时";
            break;
        }
        Ready current;
        if (!ReadReady(directory, current) || memcmp(current.instance, ready.instance, sizeof(ready.instance)) != 0) {
            if (cancelSince && !timedOut) result.finishReason = "cancelled";
            else result.error = "本机推理服务已断开，请重新启动算力服务";
            break;
        }
        if (events < 0) events = open((job + "/events").c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (events >= 0) {
            for (unsigned count = 0; count < 256; count++) {
                Frame frame {};
                const ssize_t n = pread(events, &frame, sizeof(frame), offset);
                if (n != sizeof(frame)) break; // writer may be between header and body
                if (frame.length > MAX_EVENT || frame.type < EventType::Response || frame.type > EventType::End) {
                    result.error = "本机推理服务返回了无效数据";
                    terminal = true;
                    break;
                }
                std::string payload(frame.length, '\0');
                if (frame.length && pread(events, &payload[0], frame.length, offset + sizeof(frame)) != frame.length) break;
                offset += sizeof(frame) + frame.length;
                if (frame.type == EventType::Response) {
                    if (!cancelSince) token(payload.c_str());
                } else if (frame.type == EventType::Error) {
                    result.error = payload.empty() ? "本机图文推理失败" : payload;
                } else {
                    if (payload != "stop" && payload != "cancelled" && payload != "error") {
                        result.error = "本机推理服务返回了无效结束状态";
                    } else result.finishReason = payload;
                    terminal = true;
                    break;
                }
            }
        }
        if (!terminal) std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    if (events >= 0) close(events);
    if (timedOut) {
        result.error = "本机图文推理超时";
        result.finishReason = "error";
    } else if (!result.error.empty()) result.finishReason = "error";
    if (!RegularFile(job + "/done")) WriteFile(job + "/cancel", "cancel");
    else RemoveJob(job);
    return result;
}

} // namespace vlworker
