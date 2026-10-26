# 普通应用接入 NPU 的调查（2026-10-16）

## 结论

Release 系统支持通过正式接口使用 NPU；当前私有 VL SDK 在 HAP 内打开底层驱动失败，不能推导为“Release 禁止 NPU 开发”。本次已在 Pro S 验证 NNRT 单算子计算，但未在普通 HAP 内完成 NNRT 测试，也没有完成现有 Qwen2.5-VL 模型到正式接口的迁移。

目前可以推进的正式路线是匹配设备版本的 CANN/NNRT/GEWU 应用接口适配。HDC 辅助进程继续作为现有模型的已验证临时执行路径。

## 1. 设备实测

Pro S 为 `MOR-M1`，系统报告 API 26、`OpenHarmony-7.0.0.113`。诊断程序在载入运行时前切换到 UID 20020176，只保留组 1097/3099，清空 capabilities，没有加入驱动组 3070/3094。

| 检查 | 结果 |
| --- | --- |
| 打开 `/dev/dma_heap/system_heap` | EACCES |
| 打开 `/dev/npu0` | EACCES |
| 加载公开 NDK `libneural_network_runtime.so` | 成功 |
| 枚举 NNRT 后端 | 返回 0，共 2 个 |
| `HIAI_F` 编译 Add 测试图 | 返回 2，INVALID_PARAMETER，原因未继续定位 |
| `NPU_ohos.boot.hardware.KirinXE90_v2_0` 编译 Add 测试图 | 返回 0 |
| 指定该 NPU 后端执行 `[1,2]+[3,4]` | 返回 0，输出 `[4,6]` |

因此，无需让调用者直接打开两个驱动节点，也存在能完成计算的系统接口。**诊断仍处于 HDC 的 su 域，AccessToken 也不等同于 HAP；这不是普通应用权限验证。** 后端枚举名称也不能单独当作芯片硬件鉴定结论。

独立程序源码和运行方式见 [tools/npu-api-probe](../tools/npu-api-probe/README.md)。当前代码使用 `_exit` 跳过独立程序退出时的第三方库静态清理；首次枚举后正常退出发生过 SIGSEGV，尚未定位。不能将后续诊断退出码 0 解读为应用生命周期已验证。

尝试使用官方 `aa process ... -S` 在应用沙箱中运行诊断，两次都在能力信息查询阶段返回 10105002，未启动诊断程序。补全 `-m entry` 后结果相同，不能因此判断 NNRT 在 HAP 中失败。BMS 查询确认应用 1.0.40、debug=true，包含 EntryAbility。没有替换 HAP 或修改启动器。

## 2. 当前 VL SDK 卡在什么位置

当前 SDK 导出了以下 GEWU 内部函数：

- `llm::knpu_runtime::KnpuRtMalloc(void**, size_t, tagRtMemType)`
- `KnpuRtFree`、`KnpuRtPopulate`、`KnpuRtFlushCache`、`KnpuRtInvalidCache`
- `llm::KNPUGlobalMemoryManager::alloc/free/populate`
- `KnpuRtStreamCreateWithConfig`、`KnpuRtKernelLaunch`、`KnpuRtModelExecute`

对当前库的反汇编确认，`KnpuRtMalloc` 自己执行 DMA heap ioctl、mmap、fd 管理，并非简单转发到公开模型推理 API。此前实际 HAP 已确认在打开 system_heap 时被拒绝。

用户提供的 `qwen2vl_sdk_npu.cpp` 只调用 GEWU 内部模型/session，没有应用级运行时后端或分配器替换接口。修改 wrapper 无法自动把下层计算变成 NNRT 图。即使只替换内存分配，stream/kernel 的访问方式、设备地址和同步生命周期也必须核对，不能简单把函数名替换成公开 allocator。

优先需要 SDK 提供方确认：

1. 是否已有面向普通 HarmonyOS HAP、适配本机固件的 Qwen2.5-VL NPU SDK，而非直接访问设备节点的命令行版本。
2. GEWU KNPU 内存及执行后端是否已有系统服务/CANN 接入方式，以及所需头文件、接口库和设备支持清单。
3. 若需源码适配，提供上述 `KnpuRt*` 实现和构建配置。库中可确认的调用层文件包括 `src/memory/mm/knpu_gmm.cpp` 和 `src/knpu/knpu_shmem_stream.cpp`；`KnpuRtMalloc` 所在源文件名尚未确认，应按函数名查找。现有三个 wrapper 文件不包含这部分实现。

## 3. GEWU 与 CANN LLM 接口的边界

### GEWU

Qwen2.5-7B 文本推理是重要的成功对照。工程 `gewu_probe.cpp` 经 `OH_QoS_GewuCreateSession` 和 `OH_QoS_GewuSubmitRequest` 访问系统 GEWU，显式指定 knpu。它不是直接调用当前 `qwen2vl_*` SDK。设备上应用加载了系统 `libgewu_client.z.so`；该库依赖 IPC/SAMgr 并提供 GEWU 会话/请求客户端。

设备 `/system/etc/init/gewu_service.cfg` 确认系统有按需启动的 GEWU 服务，执行 `/system/bin/sa_main /system/profile/gewu_service.json`，UID 为 `gewu`，补充组包含 `hiaiserver` 和 `dev_dma_heap`，安全域为 `u:r:gewu_service:s0`。因此 7B 的应用请求走系统服务的资源访问路径，普通 HAP 不需要具备同样的驱动直连权限。当前 VL SDK 则在调用者进程内直接访问 DMA heap，失败位置不同。

7B 仍需要 NPU 内存；本次未对成功的 7B 请求逐条跟踪驱动分配系统调用，不能断言其具体使用的 heap 节点、分配器或所有驱动调用均与 VL 相同。系统服务具备所需用户组也不能单独替代成功运行时的调用跟踪证据。

本机 API 头文件 `openharmony/native/sysroot/usr/include/qos/qos.h` 对 `OH_QoS_GewuSubmitRequest` 的契约为 messages、role、字符串 content 和 stream，没有图片路径、图片数组、视觉 embeddings 的公开字段。当前 Pro S 的 `libgewusvc_model.so` 可见 Qwen2 文本模型实现；运行时导出也未找到与现有 VL SDK 对等的 VL session/image eval 接口。

这是“当前公开契约和所检查的库未找到接入方式”，不是证明所有 GEWU 版本永远不支持多模态。不能把图片路径拼进 content 当作视觉输入。

### CANN LLM

本机 HMS SDK 发现 `CANNKit/llm_engine.h`，从 API 24 声明 `HMS_LLMEngine*` 上下文、执行器、文本/token 输入及生成 API。该头文件没有图片输入接口。

本次静态检查本机链接库和 Pro S 的 `/system/lib64/ndk/libhiai_foundation.so`，未见所检查的 `HMS_LLMEngine*` 名称；设备动态 `dlsym` 也确认五个核心函数不存在。不能仅因头文件存在就直接按该接口改 HAP。

设备内部 `libhiai_llm_engine.so` 则存在 `HIAI_LLMEngine_Executor_InitVisionModel`、`Prompt_SetImageBufs`、`Prompt_SetEncodedImageBufInfos` 等视觉相关导出。但这些不是当前头文件给出的接口；缺少匹配的结构定义、模型格式和应用可访问契约。不能凭函数名猜 ABI 并强行调用。

官方 [CANN LLM 示例](https://gitee.com/harmonyos_samples/cannkit_samplecode_lm_engine_cpp) 的流程为原始模型量化、导出 ONNX、转换为 CANN 模型再集成，包含 HarmonyOS Next 对话应用示例。[集成指南](https://gitee.com/harmonyos_samples/cannkit_samplecode_lm_engine_cpp/blob/master/CANN_LLM/CANN_LLM_Engine_Guide/CANN%20LLM%20%E5%A4%A7%E8%AF%AD%E8%A8%80%E6%A8%A1%E5%9E%8B%E8%A7%A3%E5%86%B3%E6%96%B9%E6%A1%88.md) 当前列出的模型为若干 Qwen2.5/DeepSeek/GLM/Qwen3 文本模型，硬件范围含 kirinx90；未列出 Qwen2.5-VL。该指南不能作为现有 `vl_params` 可直接使用的证明，也不能作为所有新版 CANN 都不支持 VL 的证明。

## 4. 下一步验证顺序

1. 在实际 HAP 内执行不加载业务权重的 NNRT Add 测试，核对 normal_hap、应用 Token、动态库命名空间及生命周期。
2. 优先取得 SDK 提供方已有的应用接入包或完整 KNPU 后端源码，保留现有权重的机会最大。
3. 若采用 CANN 模型路线，需要配套平台工具和原始模型，分别验证视觉编码、投影、语言模型及输入协议；不是替换一个 so 的改动。

本次仅增加独立诊断源码和调查文档；没有改变 HAP 的推理流程，没有调整设备节点、安全策略或系统库，没有停止已有辅助进程。
