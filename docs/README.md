# 文档

| 文档 | 内容 |
| --- | --- |
| [构建与运行](build-and-run.md) | SDK、依赖、签名、模型部署和设备启动 |
| [Agent 执行流程](agent-workflow.md) | 工具执行、证据、最终答复、上下文和取消 |
| [工具契约](agent-tool-contracts.md) | 工具注册、输入输出、权限、并行和缓存 |
| [多算力协作](multi-compute.md) | 设备组网、独立子任务并行和推理转发 |
| [通信协议](protocol.md) | 消息类型、分片、结果校验、预算和错误 |
| [模型选择](model-selection.md) | 已部署模型、文字/图片能力与切换 |
| [VL 应用内直连](vl-direct-mode.md) | 私有 VL SDK 的实际执行路径与调试设备权限 |
| [本地模型接口](local-model.md) | GEWU Native 接口及两种模型适配链路 |
| [工具与外部集成](integrations.md) | 内置工具、配置模板、Composio 和 ModelScope |
| [测试](testing.md) | 测试入口、覆盖范围及设备检查 |

工程入口见 [仓库 README](../README.md)，功能版本见 [CHANGELOG](../CHANGELOG.md) 和 [Agent 版本记录](../CHANGELOG.agent.md)。参数以对应源码常量和运行时能力协商为准。

AKI 的 API 文档随第三方源码提供，见 [AKI 中文说明](../apps/agent-client/entry/src/main/cpp/aki/README_zh.md)。其接口和示例属于 AKI，不表示本项目的部署状态。应用内的 Skill 指令及工作区示例是运行时资源，不属于工程使用文档。
