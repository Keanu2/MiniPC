# Changelog

按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 记录两件事：

1. **用户能感知的变化**（界面、连接、推理行为）
2. **不能从代码一眼看出来的约定**（谁调度、图走不走模型、两个 HAP 不要合并等）

版本号与 git tag 对齐。**每次改功能先写进 `[Unreleased]`**，打 tag 时再收成 `vX.Y-主题`。README 写「现在怎么工作」；这里写「这一版相对上一版改了什么」。

## [Unreleased]

### Removed

- 去掉两端过时的 `PACKAGE_INFO.md`（2026-09-10 源码快照：旧设备号、SoftBus HAP 哈希、旧 git 分支）。说明只保留根目录 README 和本文件。

## [v0.3-cluster] - 2026-09-20

设备信息协议、算力选点、附图、界面和源码分层。相对 v0.2：聊天机不再看到模型名，回复带「由哪台算力推理」，多台算力可以选点。

### Added

- 近场同步设备信息：名称、内存、已部署模型、当前推理路数。算力机每 3 秒 `deviceInfoSync`；对端 `deviceInfo` 查询即时回。
- 算力侧选点 `pickNode`（`cluster/ComputeRouter.ets`）：只考虑已部署模型的节点；优先空闲，同负载选可用内存更大者，再平手选本机。本机可多路 GEWU session，全忙仍可落到本机；集群里没有任何模型才返回 null。
- 派发带 `sched=true`，对端必须本地跑、不得再转发。协调机改写 `done.source`，避免执行机自己的「算力设备1」被原样转给聊天机。
- 两端输入栏「+」选图，气泡/任务卡展示缩略图。当前 Qwen2.5-7B-Instruct 是文本模型：**图只展示，不送 LLM，也不走近场**。有字发「（附图）…」，没字发「请描述这张图片。」
- 聊天机 / 算力机换了图标和界面：状态用圆点标签；任务标题「聊天设备N  由算力设备N推理」；设备卡不再堆蓝牙地址；内存条标明「内存」。

### Changed

- 算力发现不再用 128-bit UUID，改为 BLE manufacturer `0x6E77`、payload type=`1`（`NearbyConfig.ets`）。
- 模型端去掉写死的两路并行上限。聊天机连多少、同时发多少路，就开多少路 GEWU session；CreateSession/start 失败才报「模型繁忙」。本机输入仍一次一路。
- 算力编号：本机永远是算力设备1，其它算力按 MAC 稳定编号为 2、3…。聊天设备按 MAC 编号。聊天回复末尾「由算力设备N推理」。
- 聊天页连上后只显示「协同已就绪」，不再展示对端「本机 / Qwen2.5-7B」。聊天机若本机有权重则本地推理，不走近场；当前测试用的两台聊天机没有权重。
- ArkTS 按 `protocol` / `nearby` / `llm` / `cluster` / `media` / `ui` / `pages` 分层。路由在模型端 `cluster/ComputeRouter.ets`。

### Removed

- 回复末尾「来自本机 Qwen2.5-7B-Instruct」这类模型名尾巴。

### 约定（后面改功能时不要忘掉）

- **两个 HAP**：`src/model-end` 和 `src/chat-end`。不要做成单包角色选择。
- **聊天机只连正在广播的算力机**；调度在算力侧，不在聊天侧。
- **`sched=true` 必须本机跑**，不得再转给第三台。
- **不要抄 modelshare 的「全忙返回 null」**：有模型时 `pickNode` 仍要选出一台。
- **不要上 StarFlash / BLE 5**，除非明确要求。
- 附图策略跟当前文本模型绑定；若以后上多模态，再决定是否把图送进 LLM / 近场。

## [v0.2-nearfield] - 2026-09-15

近场数据通道从 SoftBus UIAbility 协同换成 BLE `linkEnhance`。模型端改成算力仪表盘；聊天端仍是聊天界面。

### Added

- 近场消息走蓝牙 `linkEnhance`。当时模型机用算力 UUID 广播（v0.3 已改成 manufacturer type）。
- 打开应用后自动发现并连接，仍可手动「启用近场 / 连接 / 断开」。
- 模型端仪表盘：已连接设备、进行中/已完成任务、耗时、字符数；点击任务可展开生成内容。
- 已连接聊天机显示为「聊天设备1」「聊天设备2」，并给出完整蓝牙地址；同一地址重连保持原序号。
- 最多两路 GEWU 推理并行（v0.3 已取消这个上限）。本机输入一次一路。

### Changed

- 近场不再把 `abilityConnectionManager` 当作数据通道（原先一对一）。
- 模型端界面不再混用聊天气泡。

[Unreleased]: https://github.com/Keanu2/MiniPC/compare/v0.3-cluster...HEAD
[v0.3-cluster]: https://github.com/Keanu2/MiniPC/releases/tag/v0.3-cluster
[v0.2-nearfield]: https://github.com/Keanu2/MiniPC/releases/tag/v0.2-nearfield
