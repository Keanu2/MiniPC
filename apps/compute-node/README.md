# Agent 算力端

HarmonyOS NEXT 算力应用，使用 GEWU/KNPU 运行本地模型，并作为近场算力中心或执行节点处理请求。角色设置位于 entry/src/main/ets/nearby/NearbyConfig.ets，IS_SERVER=true。

文本推理允许同机多请求并发，优先使用空闲且能力匹配的节点，再按负载、模型档位、会话亲和与实测速率选择。图片仍使用单会话 VL 通道，避免与本机文本引擎同时加载。完整文本响应在生成结束时即返回，Native 清理独立完成；设备推理数量只计算仍在生成的本机请求。

应用退到后台时保留推理与现有近场连接，并通过多设备连接后台任务维持运行；回前台重新准备近场服务。主动断开和应用销毁仍释放资源。

## 构建与部署

在 DevEco Studio 中打开本目录，或从仓库根目录运行：

```powershell
.\scripts\build-hap.ps1 -Target compute-node -InstallDependencies
```

部署模型与签名步骤见 [构建与运行](../../docs/build-and-run.md)。模型从应用 filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0 读取。版本号以 [AppScope](AppScope/app.json5) 为准。

## 执行入口

- pages/Index：看板、近场生命周期和请求分派。
- llm/InferenceRelay：中心选点、转发和响应映射。
- llm/InferenceHost：一台设备的多请求、准入和结果发送。
- llm/LocalChat 与 cpp/gewu_probe.cpp：Native 模型请求和清理。
- cluster/DevicePool：能力、档位和负载选点；nearby/LinkEnhanceChannel：组网、编号和接管。

## 多模态（Qwen2.5-VL-3B-NPU）

带图请求走本机 VL 引擎（`libqwenvl_engine.so` + NPU 版 `libqwen2vl_sdk.so` + 22 库 `libai_runtime` 闭包）。这些 `.so` 是**私有预编译产物，不在仓库内**，需本机放置到 `entry/src/main/cpp/libs/arm64-v8a/` 后随 HAP 打包：清单见 `entry/src/main/cpp/libs.manifest.json`，放置脚本 `scripts/place-vl-libs.ps1`。

缺库时 CMake 自动改编空实现（`napi_engine_stub.cpp`），应用仍可构建并只跑纯文本——多模态是可整体摘除的模块，不影响其余功能。

模型目录与文本模型并列：

```
filesDir/models/Qwen2.5-VL-3B-NPU/
  ├── vl_params        # VL 权重（NPU/CPU 版均可，容忍加载失败回退）
  ├── tokenizer.json
  └── manifest.json    # 可选：{"capabilities":["text","vision"]}
                       # 缺省时按 VL 布局自动声明 text+vision
```

- **就绪判定**：目录存在 `vl_params` 即按 VL 文件集（vl_params + tokenizer.json）检查，不再要求 `api_config.json/params`。
- **调度**：带图请求带 `needs:['vision']`；设备能力 = 所有就绪模型能力并集，VL 目录就绪即自动上报 `vision`。聊天端发图 → Hub 本机有能力则本机 VL 直答，否则路由到集群里有 VL 的算力端，全集群无 vision 时 fail closed（不会降级给纯文本模型）。
- **本地分流**：`Index.startModel` 中带图请求优先走 `VlLlmTransport`（裸 base64 解码落盘 → VL 引擎），纯文本仍走 GEWU `LocalChat`。
- **首次加载**：约 5.3GB 权重，数十秒到数分钟；加载期 UI 为 busy 态。诊断落盘 `/data/storage/el2/base/cache/qwenvl_preflight.txt`（native）与 `qwenvl_ets.txt`（ETS 层）。
- **取消**：VL 引擎为单任务，`cancel` 停在下一个 token 边界；`release` 卸载权重释放内存。

源码在 `entry/src/main/ets`。选点看 `cluster/ComputeRouter.ets`，页面在 `pages`，VL 引擎管理在 `llm/QwenVlManager.ets`、传输适配在 `llm/VlLlmTransport.ets`，模型发现在 `llm/ModelRegistry.ets`。

工具执行位于聊天端。Agent infer.* v2 与基础聊天 request 分别处理，不能混用输入预算。当前 Native max_ctx=32768，最大输出 2048 tokens，提示内容预算 32768 UTF-8 bytes；能力公告不是模型能力认证。

协议见 [通信协议](../../docs/protocol.md)，调度见 [多算力协作](../../docs/multi-compute.md)。默认保留最多 40 条已完成任务记录，服务前台监听或任务运行时保持窗口唤醒。

## 测试

从仓库根目录运行 `node scripts/test-all.cjs agent`，其中包含本工程的连接、路由、Native 生命周期适配及窗口测试。覆盖范围见 [测试](../../docs/testing.md)。

选点测试是 `cluster/ComputeRouter.test.cjs`；模型发现/能力测试 `llm/ModelRegistry.test.cjs`；VL 通道测试 `llm/VlLlmTransport.test.cjs`；页面分流测试 `pages/IndexFocus.test.cjs`。


## 设备协同视图

首页默认显示真实设备、路由层和推理/排队任务，保留“任务历史”和推理详情。任务图标使用请求里的图片元数据，设备优先按稳定 ID 关联；来源不明时单独标示，不凭名称合并不同设备。设备下方展示内存占用，超过 50% 为黄色，50% 及以下为绿色，缺失值显示“—”。

发送任务沿来源设备 → 路由层 → 执行设备的高亮路径移动。远端请求收到受理确认后进入推理区；本机快速受理的请求短暂回放分派路径。完成、失败或取消后从运行图移除，原请求结果仍可在历史中查看。推理计时从执行端受理阶段开始，包含模型准备/加载；不把首字返回当作推理开始，也不伪造引擎执行百分比。计时在页面本地刷新，不向设备发送计时轮询。

已分配设备的真实 queued 子任务显示在对应设备的排队区；未分配设备的繁忙重试显示在“等待分配”。后者由聊天端 `InferenceClient` 发送小型 `infer.status` / `queue-display` 通知，重试与取消清理原等待项，因此完整等待展示需要同时更新聊天端。旧端仍可推理，只能展示其已提供的状态；子任务排队时间从本页面首次收到等待状态开始计算。

中心端通过 `infer.status` / `flow-display` 向工作节点同步其他设备的任务类型和阶段。状态只在阶段/设备变化时传输，不携带提示词、回答或图片载荷；消息用版本号防止迟到状态复活已结束任务。等待时间以时长传递并在接收端重建本地计时，避免跨设备时钟偏差。显示通知不会改变请求准入、调度或并发策略。窄屏可在协同视图内横向滚动。

新增验证覆盖 `ui/CollaborationFlow.test.cjs` 和 `pages/IndexFocus.test.cjs` 中的等待生命周期、跨设备同步、状态隔离和清理；真实页面另用浏览器检查移动路径、计时、历史详情和窄屏滚动。

### 传输等待与诊断（1.0.48）

分片格式保持兼容：480 字节原文、Base64 封装，每条消息最多 64 KiB、每会话最多 8 条待重组消息。
重组超时按每条消息最后一片新分片计：连续 15 秒没有新进展才判停滞；重复分片、其他消息不能续期，单条上传总时长上限为 120 秒。
中心端为远端请求立即回复 `infer.accepted(state=queued)`，表示已进入中心端转发队列，避免聊天端把第二跳传输误判为未接单。
工作节点自己的受理回执才切换实际推理状态，中心端预确认不会改变工作节点受理标记或路由负载。

`NearbyChat` 日志以分片 `id` 关联两端（两台时钟可能不同）：
`le-write-start` 包含请求编号、片数、应用发送排队耗时；`le-frame-submit` 表示调用 SDK 提交成功，**不代表对端已收到**；
`le-frame-recv` 包含片索引、总片数、累计收片数/字节数、从首片起的耗时与新分片间隔；
超时包含未完成消息的 id、收片数、总耗时和停滞时间。日志不含分片内容、提示词、回答或图片。
