# MiniPC 近场聊天

HarmonyOS 两台独立 HAP：一台算力机跑 Qwen，若干聊天机靠近场连上去提问。版本记录见 [CHANGELOG.md](CHANGELOG.md)，**每次改功能先写 Unreleased**，不要只改代码。

当前版本：**[v0.3-cluster](https://github.com/Keanu2/MiniPC/releases/tag/v0.3-cluster)**（2026-09-20）。

## 现在怎么工作

- **两个应用，不是一个应用里选角色。** `src/model-end` 算力机（`IS_SERVER = true`），`src/chat-end` 聊天机（`IS_SERVER = false`）。
- **发现：** 算力机 BLE 广播 manufacturer `0x6E77`、type=`1`。聊天机只连正在广播的算力机。不用 Wi-Fi 发现当算力身份，也不用 StarFlash / BLE 5。
- **数据通道：** `linkEnhance`。协议名 `nearby-chat-v1`，帧约 480 字节 Base64，见 `protocol/ChatProtocol.ets`。
- **谁跑推理：** 聊天机本机有权重就本地跑；没有则把 `request` 发给已连接的算力机。算力机用 `pickNode` 在「本机 + 其它算力」里选一台。派发时带 `sched=true`，对端必须本地跑、不得再转发。
- **选点规则：** 跳过无模型节点；优先空闲，同负载选内存更大，再平手选本机。有模型时即使全忙也要选出一台（本机可多路 session）。代码：`src/model-end/entry/src/main/ets/cluster/ComputeRouter.ets`。
- **编号：** 算力设备1 = 协调机自己；其它算力按 MAC 为 2、3…。聊天设备按 MAC 编号。回复尾巴和仪表盘任务标题用「由算力设备N推理」，由协调机改写 `done.source`。
- **附图：** 两端都能选图，只在 UI 展示。当前 Qwen2.5-7B-Instruct 是文本模型，图不送推理、不走近场。
- **聊天页文案：** 连上后只显示「协同已就绪」，不显示对端模型名。

## 目录

| 文件夹 | 角色 | 编译开关 |
|---|---|---|
| `src/model-end` | 算力机（跑 Qwen / GEWU、选点、仪表盘） | `nearby/NearbyConfig.ets` 里 `IS_SERVER = true` |
| `src/chat-end` | 聊天机（界面 + 近场客户端） | `IS_SERVER = false` |

签名 HAP 用本机 `tools/signing`，不要提交证书和密码。模型权重不进 Git / HAP，放到应用 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`。

两端 `entry/src/main/ets` 只多一层分类（HarmonyOS 前缀 `entry/src/main/ets/` 是固定的）：

| 目录 | 改什么时进来 |
|---|---|
| `protocol/` | 近场消息字段、分片、`deviceInfo` / `sched` / `source` |
| `nearby/` | `linkEnhance`、BLE 广播、角色开关。旧 `NearbyChannel` 还在，数据面不用它 |
| `llm/` | 本机 GEWU、`LlmTransport` |
| `cluster/` | 内存/模型采样；**算力选点只在模型端** `ComputeRouter.ets` |
| `media/` | 选图压缩 |
| `ui/` | WebView 桥；模型端还有仪表盘类型 |
| `pages/` | Index 页面编排 |
| `entryability/` | 应用生命周期 |

## 改功能时看哪

| 你想改 | 文件 |
|---|---|
| 选哪台算力跑 | `src/model-end/.../cluster/ComputeRouter.ets` 的 `pickNode` |
| 消息字段 / 兼容性 | 两端 `protocol/ChatProtocol.ets`（目前是各拷一份） |
| BLE 广播识别 | 两端 `nearby/NearbyConfig.ets` |
| 设备编号文案 | `src/model-end/.../cluster/DeviceLabels.ets` |
| 聊天页连上显示什么 | `src/chat-end/.../pages/Index.ets` 的 `showConnection` |
| 附图是否送模型 | `media/ImageAttach.ets` + 两端 `pages/Index.ets` 的 send 路径 |

更细的构建说明在各端 README：[`src/model-end/README.md`](src/model-end/README.md)、[`src/chat-end/README.md`](src/chat-end/README.md)。
