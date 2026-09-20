# Changelog

按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 记。版本号和 git tag 对得上。有改动先写在 Unreleased，打 tag 时再收进去。

## [Unreleased]

## [v0.3-cluster] - 2026-09-20

能看见对面有没有模型、内存多少；多台算力时由模型机选谁来跑。聊天页干净了不少。

### Added

- 近场会同步设备名、内存、已部署模型和正在跑的路数。算力机大约每 3 秒发一次 `deviceInfoSync`，被问到 `deviceInfo` 就立刻回。
- 模型端用 `pickNode` 选执行节点（`cluster/ComputeRouter.ets`）。没部署模型的不算；先挑空闲的，负载一样看可用内存，再平手用本机。本机可以多路 session，所以全忙时仍可能落到自己。集群里一台模型都没有才会返回 null。
- 派发出去的请求带 `sched=true`，对端必须自己跑，不能再转。协调机还会改写 `done.source`，免得执行机自己的「算力设备1」被原样传给聊天机。
- 两端输入栏都可以「+」选一张图，显示在气泡或任务卡上。现在这颗模型吃不了图，所以既不送推理也不走近场。有配文时发出去是「（附图）…」，没配文是「请描述这张图片。」
- 两套图标和界面重做了一遍。状态改成圆点标签，任务写成「聊天设备N  由算力设备N推理」，设备卡不再堆 MAC，内存条旁边标了「内存」。

### Changed

- 算力发现不用 128-bit UUID 了，改成 BLE manufacturer `0x6E77`、payload type `1`。
- 模型端不再写死两路上限。聊天机同时来多少路就开多少路 GEWU；CreateSession 或 start 失败才说模型繁忙。本机输入框还是一次一路。
- 本机固定叫算力设备1，其它算力按 MAC 排 2、3…，聊天设备同样按 MAC 编号。回复末尾带「由算力设备N推理」。
- 聊天页连上之后只显示「协同已就绪」，不再出现「本机 Qwen2.5-7B」。聊天机如果自己有权重会本地跑；手头这两台测试机没有。
- 源码按 `protocol` / `nearby` / `llm` / `cluster` 这些目录分开了，选点在模型端 `cluster/ComputeRouter.ets`。

### Removed

- 回复末尾「来自本机 Qwen2.5-7B-Instruct」那种尾巴。
- 两端那份 9 月 10 日的 `PACKAGE_INFO.md`（旧设备号和 SoftBus HAP 哈希）。

### Fixed

- 相册选完图后用文件描述符解码。之前直接拿 picker 的 URI 喂给 ImageKit，真机会报「图片读取失败」；点取消也不再当成失败。

选点、发现、附图这些细节 README 里有，这里不重复。两个 HAP 先保持分开；StarFlash / BLE 5 也还没上。

## [v0.2-nearfield] - 2026-09-15

数据通道从 SoftBus 的 UIAbility 协同换成 BLE `linkEnhance`。模型端改成仪表盘，聊天端还是聊天页。

### Added

- 近场消息走 `linkEnhance`。当时算力机还在用 UUID 广播，v0.3 才改成 manufacturer type。
- 打开 App 会自动发现并连接，手动「启用近场 / 连接 / 断开」也还在。
- 模型端能看到已连接设备、进行中和已完成的任务、耗时和字数，点开任务能看生成内容。
- 聊天机按接入顺序叫「聊天设备1」「聊天设备2」，当时还带完整蓝牙地址，同一地址重连序号不变。
- 推理最多两路并行（v0.3 拿掉了）。本机输入一次一路。

### Changed

- 不再拿 `abilityConnectionManager` 传聊天数据（原先一对一）。
- 模型端不再混用聊天气泡。

[Unreleased]: https://github.com/Keanu2/MiniPC/compare/v0.3-cluster...HEAD
[v0.3-cluster]: https://github.com/Keanu2/MiniPC/releases/tag/v0.3-cluster
[v0.2-nearfield]: https://github.com/Keanu2/MiniPC/releases/tag/v0.2-nearfield
