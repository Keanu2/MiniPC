#pragma once

#include <functional>
#include <string>

namespace vlworker {

struct Result {
    bool handled = false;
    std::string error;
    std::string finishReason = "error";
};

Result Infer(const std::string& cacheDir, const std::string& modelDir,
    const std::string& imagePath, const std::string& prompt,
    const std::function<void(const char*)>& token,
    const std::function<bool()>& cancelled);

void Release(const std::string& cacheDir);

} // namespace vlworker
