# Changelog

按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 记录用户能感知的变化。版本号与 git tag 对齐。

## [Unreleased]

## [v0.3-cluster] - 2026-09-20

设备信息协议、算力选点、附图和源码分层。

### Added

- 连上后在 `linkEnhance` 上查询并同步设备信息（名称、内存、已部署模型、推理路数），聊天端状态栏和算力仪表盘都会显示。
- 算力侧按「有模型、更空闲、内存更大」选执行节点；派发请求带 `sched`（对端必须本地跑），回复带来源。本机可多路 session，满载仍可落到本机。
- 聊天端和模型端都可以从图库选一张图：输入栏左侧「+」，气泡/任务卡展示缩略图。当前模型是文本模型，图片只用于展示，不送入推理，也不走近场。
- 聊天机 / 算力机换成可区分的图标和更干净的界面：状态用圆点标签，任务写成「聊天设备N  由算力设备N推理」，设备卡不再堆蓝牙地址。

### Changed

- 模型端不再写死两路并行上限。聊天机连多少、同时发多少路，就开多少路 GEWU session；只有 CreateSession/start 失败时才返回「模型繁忙，请稍后再发」。本机输入仍一次一路。仪表盘显示当前推理路数，不再带 `/ 2`。
- 算力设备按接入顺序编号：本机为算力设备1，其它算力为算力设备2、3…。仪表盘任务标题为「聊天设备N  由算力设备N推理」；聊天回复末尾带「由算力设备N推理」。
- ArkTS 源码按 `protocol` / `nearby` / `llm` / `cluster` / `media` / `ui` 分层；Index 只负责页面编排。

## [v0.2-nearfield] - 2026-09-15

近场数据通道、自动连接、模型端仪表盘。聊天端仍是聊天界面。

### Added

- 近场消息改走蓝牙 `linkEnhance`；模型机用算力 UUID 广播，聊天机按该 UUID 识别算力设备。
- 打开应用后自动发现并连接，同时保留手动「启用近场 / 连接 / 断开」。
- 模型端改为算力仪表盘：已连接设备、进行中/已完成任务、耗时、字符数；点击任务可展开生成内容。
- 已连接聊天机显示为「聊天设备1」「聊天设备2」，并给出完整蓝牙地址；同一地址重连保持原序号。
- 最多两路 GEWU 推理并行；两台聊天机可同时发问并各自流式收答。本机输入仍一次一路。

### Changed

- 近场不再把 `abilityConnectionManager` UIAbility 协同当作数据通道（原先一对一）。
- 模型端界面不再混用聊天气泡；聊天端界面不变。

[Unreleased]: https://github.com/Keanu2/MiniPC/compare/v0.3-cluster...HEAD
[v0.3-cluster]: https://github.com/Keanu2/MiniPC/releases/tag/v0.3-cluster
[v0.2-nearfield]: https://github.com/Keanu2/MiniPC/releases/tag/v0.2-nearfield
