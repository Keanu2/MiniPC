# Pro S 应用内 VL 权限对照（2026-10-20）

## 实测结论

现有 Pro S 算力应用 1.0.45 在 **SELinux Permissive + 仅当前应用的四个驱动节点临时访问权** 条件下，已连续两次直接运行 Qwen2.5-VL，并在界面正确回答图片中是一只狗。本次没有编译、替换 SDK 或安装 HAP，没有修改模型或算子库。

仅 `setenforce 0` 不足以使本机现有应用直接推理：文件所有者/组权限仍然生效。此前只处理了三个节点，遗漏的 `/dev/npu_manager` 是这次确认的新拦截点。

## 目标与身份

- MateBook Pro S：`7QB0126509000160`，系统产品型号 MOR-M1。
- 应用：`com.jiuwen.registrychatui`，已安装版本 1.0.45，UID 20020176。
- 实际进程安全域：`u:r:normal_hap:s0`；补充组 1097、3099，没有 3070/3094。
- 模型：`Qwen-2.5-vl-3B-instruct-Q4_N_0_G128`。
- 使用系统选择器里的既有 `minipc-vl-sample.jpg` 狗图；成功两次均使用应用默认的“请描述这张图片。”。
- MateBook Pro 保持之前的文本模型配置，其他设备未参与本次权限调整。

## 对照结果

| 条件 | 实际应用内结果 |
| --- | --- |
| 只执行 `setenforce 0`，节点保持原所有者及 660 | 加载失败；打开 `/dev/dma_heap/system_heap` 返回 errno 13，SDK 加载返回 -3 |
| Permissive，临时授予 npu0、system_heap、npu_device_hugepage_heap 的所有权给当前应用，组及 660 保持不变 | 模型加载返回 0，2196 ms；会话创建失败，`KnpuRtSetDevice(0)` 返回 `5608000e` |
| 上述条件再加入 npu_manager | 模型加载返回 0，1544 ms；第一次 chat rc=0，14128 ms，界面首字 4.4 s、请求 14.2 s，输出 103 字，正确识别狗 |
| 相同应用进程、相同权限条件，连续第二次发送相同图片 | chat rc=0，12097 ms；界面首字 2.9 s、请求 12.1 s，输出 99 字，仍正确识别狗 |

在补充第四个节点之前，实际进程的系统调用跟踪记录为：

```text
OPEN tid=12321 flags=20000 ret=-13 path=/dev/npu_manager
```

因此这次的 `5608000e` 有明确的管理节点访问失败证据；不再仅凭错误码推测 SDK 或芯片不兼容。

## 排除辅助进程介入

原有 `vl-worker` 服务没有停止。测试时把应用缓存 `vl-worker/enabled` 标记临时移走，使现有 HAP 桥接走直接 SDK 分支。两次成功时，进程仍为 normal_hap，UID/补充组没有变化；辅助进程 `worker.log` 保持 2026-10-19 16:21 的修改时间和 881 字节，未处理本次请求。应用自身的 `qwenvl_preflight.txt` 则记录了加载成功与两次 chat rc=0。

## 恢复核对

为两轮权限调整分别设置了自动恢复，并在测试结束主动恢复、复核。应用已重新启动以释放本轮直接 SDK 的模型与设备句柄。最终状态：

```text
SELinux: Enforcing
3094 3094 660 /dev/npu0
3094 3094 660 /dev/npu_manager
3070 3070 660 /dev/dma_heap/system_heap
3070 3070 660 /dev/dma_heap/npu_device_hugepage_heap
WORKER_ENABLED_RESTORED
TEST_INACTIVE
```

辅助进程原启用标记已恢复，仍运行原服务。没有留下开机放宽权限配置。

## 验证范围与后续

这次证明现有 HAP/SDK 可以在 Pro S 普通应用进程内完成这张图片的连续两次推理。未验证所有图片、取消、长时间连续运行或无需管理员介入的应用部署。应用内长期使用仍需把四个节点的访问和安全域策略作为完整的系统配置处理；本次没有修改永久策略，当前设备继续使用恢复后的辅助进程配置。

本地原始证据保存在 `.hvigor/selinux-test-2026-10-20/`：`app-success-preflight.log`、`app-trace.log`、`success-detail.json`、`second-detail.json`、`success.png`、`second-success.png`。这些是真机结果，非界面模拟数据。
