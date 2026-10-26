# MateBook 多模态适配排查（2026-10-16）

**后续部署：** 算力端 VL 入口已改为固定应用内 SDK；新增 [直连权限启停脚本](vl-direct-mode.md)。Pro S 当前已停用旧辅助进程并开启直连权限，系统模式为 Permissive；可用 Stop 恢复原模式和节点所有者。[Qwen3.5 迁移与运行验证](qwen35-pros-deployment-2026-10-20.md) 另行记录。

**2026-10-20 更新：** 已在 Pro S 现有 1.0.45 HAP 内，临时 Permissive 并授予当前应用四个驱动节点访问后，连续两次直接 VL 图片推理成功。第四个节点 `/dev/npu_manager` 此前被遗漏。测试后已恢复 Enforcing、原节点权限和辅助进程配置。见 [应用内权限对照实测](vl-selinux-validation-2026-10-20.md)。下文保留 10 月 16 日的调查背景。

MateBook Pro S 已在独立程序及本机辅助进程完成真实图片推理。**更新后的应用 HAP 尚未安装验证，不能称应用已跑通。** Mate 80 保留原来的 1.0.19，未安装或替换其应用/库。

## 两台电脑的结果不同

### 后续调整：Pro 仅使用文本模型（2026-10-16）

按用户要求，MateBook Pro（`3QC0124C20000251`）停止使用 VL：已停止该机 VL 辅助进程，将辅助进程的 `enabled` 标记改为 `disabled`，并将应用 `files/models/Qwen-2.5-vl-3B-instruct-Q4_N_0_G128` 移至 `files/disabled-models/` 下保留。当前 `files/models/` 仅有 `Qwen2.5-7B-Instruct-Q4_N_0`，因此模型发现、设备能力上报和请求选模只覆盖文本模型。

已重启 Pro 的现有应用，读取界面布局确认本机卡片显示 `Qwen2.5-7B · T2`，不再显示 VL。此次为设备部署配置调整，未重新编译或安装 HAP，未重新发起推理。Pro S 的 VL 部署保持原状。

| 设备 | 当前结果 |
| --- | --- |
| MateBook Pro（3QC0124C20000251） | 独立程序加载后 NPU 执行报 56060020/TASK_FAILURE，尚未完成推理 |
| MateBook Pro S（7QB0126509000160） | 相同权重及配套运行时可识别测试图中的狗；当前优先接入这台 |

三台设备已安装的 SDK、kernel、base、ai_runtime 哈希一致。`make_cpu_gmm` 查找失败的警告在成功手机链路也出现，不能单凭它认定失败原因。旧系统算子库缺少视觉接口；仅将 backend 改成 CPU 也不支持当前 q4_n_0_g128 权重，不能作为回退方案。

## Pro S 应用加载失败的证据

补充只读核对的系统构建/安全参数：Mate 80 的 `const.ohos.releasetype=Beta2`，版本为 `SGT-AL10 7.0.0.40(SP20C00E100R3P1log)`；Pro S 为 `Release`，版本为 `MOR-W52 7.0.0.113(SP50C00E101R9P2log)`。两台都显示 `const.debuggable=1`、`const.secure=0`、`const.logsystem.versiontype=beta`，因此不能仅根据 Release 字段认定 Pro S 是完全未经调试的零售正式构建。

直接相关的访问控制差异已经确认：手机为 SELinux Permissive，`npu0` 和 `system_heap` 都是 666；Pro S 为 Enforcing，两个节点为 660。该差异强烈支持系统安全配置是应用可运行性差异的关键因素，但尚未完成只改变单一安全策略的因果对照。核对过程中未修改任何系统参数、节点权限或安全模式。

- 实际 HAP 的系统调用跟踪：打开 `/dev/dma_heap/system_heap` 返回 `-13/EACCES`。
- GEWU 错误日志：无法打开该节点，6025216 字节 DMA 分配失败，随后模型加载失败。
- 模型文件的落盘、大小和应用可读性已核对。失败发生在 NPU 内存分配阶段。
- HDC 独立程序与 HAP 的身份/安全环境不同。HAP 为 `normal_hap`，HDC 程序为 `su` 域；Pro S 全局 SELinux Enforcing，手机为 Permissive。
- 经用户明确授权，曾仅临时改变三个驱动节点的所有者，保留组和 660 模式；同 UID 的独立程序可执行，但实际 HAP 仍被拒绝。所有临时变更已恢复。尚未确定具体的附加拦截策略。

这些证据支持“应用访问 NPU 驱动受限”，并不证明某一条 SELinux 规则就是唯一原因。

## 当前实现

- `vl_runtime.h`：复用真实 SDK 加载器，失败可重试、保留 SDK 文件日志，返回具体错误和驱动访问诊断；避免模块构造阶段提前初始化 SDK。
- `vl_worker_client.cpp`、`vl_worker_protocol.h`：HAP 与辅助进程在应用私有缓存目录 `vl-worker` 中交换有大小限制的请求/流式响应，包含超时、取消、心跳、实例标识及异常结束处理。没有监听网络端口。
- `vl_worker.cpp`：由 HDC 启动，处理模型和请求前降到应用 UID，清空 Linux capabilities，保留所需的驱动补充组；不修改设备节点和全局安全模式。
- 现有 SDK 在同一进程连续推理时存在输出不一致，destroy/create 也未完全消除。因此辅助进程每轮使用 `fork + exec` 启动新的推理子进程，结束后退出，不复用 SDK 进程状态。每轮需要重新加载模型。
- `napi_engine.cpp`：检测辅助进程标记后转交请求、消费流式结果；未启用时沿用直接 SDK 路径。启用后服务失联会明确报错，不会无限等待。

## 已验证与尚待验证

- 初始独立程序：识别狗，约 7.06 token/s，约 4.1GB 内存。
- 每请求新进程版本：连续两轮相同图片均输出“图片中的主要物体是一只狗。”，约 7.4/7.3 秒；取消返回约 3.3 秒；取消后的下一轮再次正确输出，约 7.3 秒。
- 辅助进程原生编译成功，HAP 桥接通过 NDK C++ 语法检查。这些结果不等于 HAP 安装、沙箱文件通信和界面端到端验证通过。
- SDK 源码补丁仅通过原文件的 `git apply --check`，未重编或安装新的 SDK。

## 使用与下一步

HAP 仍按用户最后约定由用户编译签名。需安装包含本次 C++ 桥接的算力端 HAP，在 Pro S 执行：

```powershell
.\scripts\vl-worker.ps1 -Device 7QB0126509000160 -Action Start
.\scripts\vl-worker.ps1 -Device 7QB0126509000160 -Action Status
.\scripts\vl-worker.ps1 -Device 7QB0126509000160 -Action Stop
```

已有服务需要换为当前构建时使用 `-Action Start -Restart`。安装 HAP、设备重启或应用 UID 改变后需重新启动辅助进程；应用私有缓存清理会移除服务标记。停止服务保留启用标记，HAP 会提示服务未运行；重新启动即可恢复。

启动脚本检查安装库与本地关键私有库哈希、编译独立程序并部署到随机的 root 私有目录，不会安装 HAP。依赖已经可用的 root HDC 会话。当前方案用于用户接受的电脑验证接入，尚不是无需 HDC 的正式发布方案。

本次新提供的 SDK 源码审查、修复位置和补丁见 [qwen2vl-sdk-source-review.md](qwen2vl-sdk-source-review.md)。修改封装不能赋予应用驱动访问权；正式应用内推理需 GEWU/设备平台支持的服务或内存后端。
