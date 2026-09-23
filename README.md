# MiniPC

算力协同，由算力端和聊天端组成，靠蓝牙近场连接。具有两个独立 HAP。

现在的版本是 [v0.4-hub](https://github.com/Keanu2/MiniPC/releases/tag/v0.4-hub)。改过什么看 [CHANGELOG.md](CHANGELOG.md)。

## 怎么跑起来的

算力机（`src/model-end`，`IS_SERVER = true`）先用 manufacturer `0x6E77`、type `1` 的 BLE 广播互相发现，按组网时可用内存选出算力设备1。启动后留 10 秒选举窗口，编号确定后才发布编号广播；广播只在编号真正变化且没有在途任务时更新。聊天机只连接可信的算力设备1，连上之后标题显示「聊天设备N」，状态栏写「协同已就绪」。算力设备1统一接收、调度并回传，其他算力设备只与它保持算力链路。

算力设备1停用后，存活算力按旧排名确认接管：至少15秒、三次成功完成的扫描均未发现旧中心后，由当前可见存活成员中排名最靠前的一台接管为1号并发布新广播；聊天端在接管窗口内继续有限次重连，不会直接连仍编号为2的节点。已连上中心的执行节点不再自己猜编号，等中心按安装 UID 分配；第三台、第四台不会再都自称算力设备2。

轻量内存、温度、CPU 和推理路数在空闲时每 2 秒更新。成员变化由中心立刻同步：推理进行中只发精简名单（身份、角色、编号、ready），空闲时发完整清单，没有变化则 30 秒保底。失败会按连接重试。细节、容量边界和尚未做完的真机轮次见 [2026-09-23 多算力审查](docs/multi-compute-membership-review-2026-09-23.md)。更早的中心接管和广播修复见 [2026-09-22 修复记录](docs/nearby-identity-and-hub-failover-fix-2026-09-22.md)，其中「推理期间不发后台控制消息」已被上面的精简名单替代。

消息走 `linkEnhance`，协议叫 `nearby-chat-v1`，帧大概 480 字节 Base64，编解码在 `protocol/ChatProtocol.ets`。

聊天机连上中心后所有新请求都发给算力设备1；仅在未连接中心且本机部署权重时保留离线本地推理。1号接到请求后按负载和可用内存选执行机。代码在 `cluster/ComputeRouter.ets` 的 `pickNode`。派出去的请求带 `sched=true`，对面必须自己跑并经1号回传结果。

算力编号按组网时的可用内存排一次（余量最大的是算力设备1，平手按安装 UID），内存后来涨跌不再改号；中心失效后按存活成员重新编号。界面上只显示「算力设备N / 聊天设备N」，不出现手机蓝牙名。聊天机由当前中心按安装 UID 分配不重复编号，同一近场服务会话保留已分配号码供重连使用；更换中心后可能重新分配，不是物理设备永久编号。回复末尾的「由算力设备N推理」是协调机改写 `done.source` 写上去的。

两端都能附图，但现在这颗 Qwen2.5-7B-Instruct 是文本模型，图只显示在气泡/任务卡里，既不进推理也不走近场。

签名用本机 `tools/signing`，证书别提交。模型文件也不进 Git，放到应用 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`。

## 目录

| | 干什么 | 开关 |
|---|---|---|
| `src/model-end` | 跑模型、选点、仪表盘 | `nearby/NearbyConfig.ets` 里 `IS_SERVER = true` |
| `src/chat-end` | 聊天界面 | `IS_SERVER = false` |

HarmonyOS 规定源码在 `entry/src/main/ets/` 下面。我们只多了一层分类：

- `protocol/` 消息字段和分片
- `nearby/` `linkEnhance`、BLE、角色开关
- `llm/` 本机 GEWU
- `cluster/` 内存和模型采样；选点只在模型端的 `ComputeRouter.ets`
- `media/` 选图
- `ui/` WebView 桥
- `pages/` 页面
- `entryability/` 生命周期

设备编号文案在模型端 `cluster/DeviceLabels.ets`。两端的 `ChatProtocol.ets` 目前是各一份拷贝，改字段要两边一起动。

编 HAP 的命令写在 [算力端 README](src/model-end/README.md) 和 [聊天端 README](src/chat-end/README.md)。
