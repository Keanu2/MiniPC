# Qwen2VL SDK 源码审查（2026-10-16）

已只读取得 Mate 80 `/data/oh-server/lib` 下的 `qwen2vl_sdk.cpp`、`qwen2vl_sdk_npu.cpp`、`qwen2vl_sdk.h`。未修改手机上的源码、库或已安装应用。

## 应用无法加载的直接原因

注意：Release 系统并不等于禁止三方应用使用 NPU。HarmonyOS 提供 CANN Kit、NNRT/MindSpore Lite 等应用接入方式；当前结论仅针对这套私有 SDK 在 HAP 内直接访问设备节点的路径。系统接口是否能承载现有 GEWU VL 算子、私有权重和动态推理流程仍需验证，不能因存在公开 NPU 接口就认定现有 `.so` 可直接替换，也不能因设备访问失败就认定只能使用 CPU 或 HDC 服务。

MateBook Pro S 的应用进程实际执行 `openat(..., "/dev/dma_heap/system_heap", ...)` 返回 `-13`（EACCES）。GEWU 分配器无法分配 NPU 内存，模型加载返回 -3，此时尚未读取大权重。相同设备的 HDC 独立程序能完成看图回答，因此不能把 Pro S 的这次加载失败归结为权重或算子不支持。

临时调整设备节点所有者后，应用仍被拒绝；这些临时调整已经恢复。具体是哪条应用安全策略造成额外拒绝尚未完全确定。Mate 80 为 SELinux Permissive，Pro S 为 Enforcing，也是两者安全环境的重要差异，但这不能单独证明具体拦截规则。

NPU 版源码第 225 行只是调用 `impl->model->load(...)`，驱动访问发生在其下层 GEWU/KNPU 内存分配实现中。提供的三份文件没有驱动授权、内存服务或内存分配器注册接口。改这层封装、重新链接同一套 GEWU 内核，无法赋予普通 HAP 原本没有的驱动访问权。

若要支持 HAP 进程内推理，需要在 GEWU/运行时层提供应用可用的授权服务或受支持的内存分配后端，并配套设备侧接入配置；具体代码位置需要完整引擎源码与构建工程才能确定。当前选择 HDC 启动的辅助进程处理推理，HAP 在自己的私有缓存目录中发送请求、接收流式结果。

## 可以立即修改的 SDK 封装错误

以本次取得的 `qwen2vl_sdk_npu.cpp` 原始行号为准；CPU 版本也有相同问题。

| 位置 | 问题 | 修改 |
| --- | --- | --- |
| `qwen2vl_chat`，第 276 行 | `stbi_load(..., 3)` 输出 RGB，但 `ic` 是原图通道数；灰度/RGBA 图片可能按错误通道处理 | 构造 `Image(iw, ih, 3, image_data)` |
| `qwen2vl_chat`，第 312–329 行 | `eval` 失败直接退出循环；取消设置的错误码也被循环后无条件 `result=OK` 覆盖 | 显式检查 eval 返回值，在 eval 前后检查取消，保留错误码 |
| `qwen2vl_destroy`，第 365–373 行 | `chat_lock` 的生命周期超过 `delete impl`；析构时对已经释放的 mutex 解锁，属于未定义行为 | 两个锁都在 `delete impl` 之前结束作用域；调用者仍须阻止销毁期间的新请求 |

补丁：[qwen2vl-sdk-lifecycle.patch](patches/qwen2vl-sdk-lifecycle.patch)。在同时包含两个 cpp 文件的目录使用 `git apply --check <补丁路径>`、`git apply <补丁路径>`；若工程只编译 NPU 版，可仅应用 `--include=qwen2vl_sdk_npu.cpp`。

补丁已对下载的原始文件执行 `git apply --check` 通过。**尚未编译 SDK，也未用补丁替换任何设备上的 `.so`。** 现有文件缺少 `gewu/engine/...`、`gewu_sdk.h`、`qwen2_5vl_cli_main.hpp` 及静态引擎库/构建配置，不能单凭三个文件重建原库。

`BootstrapOnce` 已使用进程级 `static llm::InitHelper`，这一修复已经存在，应保留。NPU 版默认 3B/knpu 配置与 CPU 版的 7B/cpu 配置不同，重新构建时要确认选择的是 NPU 源文件，不可直接混用默认配置。

## 还需引擎侧排查的问题

现有已安装 SDK 在同一进程多次推理时，对完全相同图片/提示出现不一致输出；调用 destroy/create 也没有可靠恢复。提供的源码每轮创建 session，但 `gewu_reset` 仅返回成功。仍需检查模型/KNPU 进程全局缓冲区和 session 缓存的实际生命周期，不能只凭该注释认定已清理状态。

辅助进程改为每轮 `fork + exec` 全新的推理子进程，结束后退出并释放该进程资源，避免复用私有 SDK 状态。代价是每轮重新加载模型。其应用桥接尚需新 HAP 安装后验证，不能把独立进程推理成功等同于应用界面已跑通。
