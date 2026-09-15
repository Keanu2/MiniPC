# Changelog

按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 记录用户能感知的变化。版本号与 git tag 对齐。

## [Unreleased]

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

[Unreleased]: https://github.com/Keanu2/MiniPC/compare/v0.2-nearfield...HEAD
[v0.2-nearfield]: https://github.com/Keanu2/MiniPC/releases/tag/v0.2-nearfield
