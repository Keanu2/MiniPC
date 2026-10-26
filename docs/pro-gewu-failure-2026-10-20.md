# Pro 的 Qwen3.5 初始化失败

2026-10-20 15:22，MateBook Pro（3QC0124C20000251，HAD-W32，算力 HAP 1.0.46）选用 Qwen3.5-9B。授权已经生效：SELinux 为 Permissive，三个现有 NPU/heap 节点属于应用 UID 20020179，组和 660 模式保留。

## 已确认的失败链路

1. GEWU 使用应用沙箱模型路径创建 KNPU 会话，运行时接口 major=1、minor=2。
2. `libgewurt_base.so` 加载 `/vendor/lib64/passthrough/indirect/libgewurt_kernel.so` 时，找不到 `binary_op_sub_float_float_launch`。
3. 日志明确写出 `Some CCE kernel symbols failed to load, KNPU backend disabled.` 和 `is_npu_supported_dtype_ptr is nullptr`。
4. `gewu_service` 随后在 `llm::KirinNPU::Context::Context()` 中空指针跳转，SIGSEGV，PC=0。崩溃时间 15:22:23.122，进程 UID 7842，PID 18307。

销毁会话阶段的 `permission denied` 出现在服务崩溃并重启之后，不能把它当成本轮初始化失败的首因。

## 与 Pro S 对照

两台设备的 `libgewurt_base.so`、`libgewurt_runtime.so`、`libgewurt_qw35.so` 和 `libgewusvc_model.so` SHA-256 均一致。但 kernel 不同：

| 文件 | Pro | Pro S |
| --- | --- | --- |
| kernel 字节数 | 630760 | 1019720 |
| kernel SHA-256 | a360862c31ac8f3cc74cd3959ae956b8390723ebb1ae3dc5e1d908e5661f7f23 | eef5cc56bb9e1a5f592fdd38eb3142ef763c7015497afff848de49cef773303c |
| 导出 binary_op_sub_float_float_launch | 无 | 有 |
| 导出 is_npu_supported_dtype | 无 | 有 |

已用 llvm-nm 检查两个设备实际库文件的动态导出。直接故障是新运行库与 Pro 上保留的旧 kernel 接口不配套，不是本次应用驱动授权未生效。

需要提供与当前 GEWU 版本、Pro 芯片及驱动匹配的 kernel。首次定位仅对照接口，未替换系统库、改变模型选择或安装应用；后续授权验证结果如下。

## 授权验证：Pro S kernel 在 Pro 上仍无法完成推理

用户授权后，将 Pro 原库备份到设备 `/data/local/tmp/minipc-kernel-test-20261020-1526/original-kernel.so`，临时替换为 Pro S 的 kernel，校验 SHA-256 为 `eef5cc56bb9e1a5f592fdd38eb3142ef763c7015497afff848de49cef773303c`。没有编译或安装 HAP，重开现有 1.0.46 应用，在本机输入 `1+1=`。

- 缺失算子符号报错消失，运行时识别平台为 `changsha`，`KNPU Standalone Runnable: Yes`。
- 正式应用接口 `create=0`、`submit=0`，打开 `/dev/dma_heap/system_heap` 并进入模型运行初始化。
- 15:29:18.930 报 `[KirinNPU] Captured TASK_FAILURE exception from KNPU runtime.`、`NPU HARDWARE TIMEOUT OR FAULT` 和错误码 `56060020`（`KnpuRtStreamSynchronize`）。
- 服务以 `GEWURT_ERR_EXCEPTION` 未捕获异常退出（SIGABRT，PID 21349）。应用收到空内容、`finish_reason=abort`，没有答案；不是推理成功。

这次验证证明补齐接口只能解决第一层加载问题，Pro S 的 kernel 尚不能在该 Pro 的当前软硬件组合上直接工作。仅凭此日志不能区分具体算子、编译芯片目标或驱动运行时版本问题，也不能据此认定设备物理损坏。

测试结束已恢复原 kernel，SHA-256 再次确认为 `a360862c31ac8f3cc74cd3959ae956b8390723ebb1ae3dc5e1d908e5661f7f23`，所有者/组 root:root、模式 644、SELinux 标签 `vendor_lib_file` 保留，并重新打开应用。权限授权及原 Qwen3.5 模型选择保持原状。首次 HDC 上传将相对本地路径展开为远端目录，替换失败后立即恢复并核对原库，再使用绝对本地路径上传、核验普通文件类型与哈希后完成正式验证。

原始 GEWU 进程日志、应用回调、崩溃转储和内核日志位于 `.hvigor/pro-gewu-2026-10-20/pros-kernel-test-*`。后续需要 Pro 平台适配的 kernel（日志平台 `changsha`），以及提供方确认与当前 GEWU、NPU 驱动运行时的配套关系。

原始日志、崩溃转储和两个 kernel 的只读副本保存在 `.hvigor/pro-gewu-2026-10-20/`。
