# MiniPC

一台手机跑 Qwen，旁边几台当聊天端，靠蓝牙近场连上就能问。两个独立 HAP，不是一个 App 里切角色。

现在的版本是 [v0.3-cluster](https://github.com/Keanu2/MiniPC/releases/tag/v0.3-cluster)。改过什么看 [CHANGELOG.md](CHANGELOG.md)。

## 怎么跑起来的

算力机（`src/model-end`，`IS_SERVER = true`）开着 BLE 广播：manufacturer `0x6E77`，type 为 `1`。聊天机（`src/chat-end`，`IS_SERVER = false`）只连正在广播的算力，连上之后状态栏写「协同已就绪」，不把对面的模型名甩出来。

消息走 `linkEnhance`，协议叫 `nearby-chat-v1`，帧大概 480 字节 Base64，编解码在 `protocol/ChatProtocol.ets`。

聊天机自己有权重就本地推；没有就把 `request` 丢给已连接的那台算力。算力机再在「自己 + 其它算力」里挑一台，代码是 `cluster/ComputeRouter.ets` 的 `pickNode`：没模型的跳过，先看谁空闲，一样忙就看谁内存多，再平手用本机。本机可以同时开多路 GEWU session，所以大家都忙的时候仍然可以落到自己头上。派出去的请求会带 `sched=true`，收到的那台必须本地跑，不能再转手。

算力设备按 MAC 排1、2、3…。聊天设备也按 MAC 编号。回复末尾的「由算力设备N推理」是协调机改写 `done.source` 写上去的，避免执行机自己那套「算力设备1」原样传回来。

两端都能附图，但现在这颗 Qwen2.5-7B-Instruct 是文本模型，图只显示在气泡/任务卡里，既不进推理也不走近场。

签名用本机 `tools/signing`，证书别提交。模型文件也不进 Git，放到应用 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`。

## 目录

| | 干什么 | 开关 |
|---|---|---|
| `src/model-end` | 跑模型、选点、仪表盘 | `nearby/NearbyConfig.ets` 里 `IS_SERVER = true` |
| `src/chat-end` | 聊天界面 | `IS_SERVER = false` |

HarmonyOS 规定源码在 `entry/src/main/ets/` 下面。我们只多了一层分类：

- `protocol/` 消息字段和分片
- `nearby/` `linkEnhance`、BLE、角色开关。`NearbyChannel` 还留着，已经不走它传数据
- `llm/` 本机 GEWU
- `cluster/` 内存和模型采样；选点只在模型端的 `ComputeRouter.ets`
- `media/` 选图
- `ui/` WebView 桥
- `pages/` 页面
- `entryability/` 生命周期

设备编号文案在模型端 `cluster/DeviceLabels.ets`。两端的 `ChatProtocol.ets` 目前是各一份拷贝，改字段要两边一起动。

编 HAP 的命令写在 [算力端 README](src/model-end/README.md) 和 [聊天端 README](src/chat-end/README.md)。
