# Agent 聊天端

HarmonyOS NEXT 聊天应用，负责 Agent 执行、工具调用、子任务编排和结果展示。默认页面通过 RemoteComputeModel 使用近场算力设备；本机工具在聊天设备运行。

顶部 Agent 开关默认关闭，并保存选择。关闭后是普通聊天：只发送当前消息、附件文字及本轮图片，不发送历史问答，也不初始化工具、拆分任务或执行答案审查。开启后使用 Agent 流程。两种模式均保留界面上的聊天记录；生成期间需先停止再切换模式。

连接建立后申请多设备连接后台任务。应用退到后台时保留近场连接与推理，只停止发现扫描；回到前台时恢复近场准备，应用销毁或主动断开时释放连接。

提交任务后，聊天区在本轮消息下方显示文本或图像任务卡片。执行时左侧图标和标题垂直居中，右侧显示状态和实时计时；结束后收成简洁状态条，保留已完成、部分完成、执行失败或已停止状态及总用时。计时从本轮提交开始，每秒更新；清除对话时一并移除卡片。卡片只在本次页面会话展示，不写入模型上下文或持久化聊天历史。

## 构建与运行

在 DevEco Studio 中打开本目录，安装 AGenUI 依赖并构建 entry。仓库根目录的命令行入口：

```powershell
.\scripts\build-hap.ps1 -Target agent-client -InstallDependencies
```

环境、签名和连接步骤见 [构建与运行](../../docs/build-and-run.md)。本工程 bundleName 为 com.jiuwen.registrychatui，应与算力端分别安装到不同设备。版本号以 [AppScope](AppScope/app.json5) 为准。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| entry/src/main/ets/pages/Index.ets | 页面、会话历史、任务状态和最终展示 |
| entry/src/main/ets/model | 近场模型适配、多请求与取消范围 |
| entry/src/main/ets/nearby | 设备发现和近场通信 |
| entry/src/main/ets/protocol | 推理消息及分片校验 |
| agent-core/src/main/ets/agent | ReAct、工具契约和任务接口 |
| agent-core/src/main/ets/agent/parallel | 独立子任务拆分、执行和汇总 |

流程见 [Agent 执行](../../docs/agent-workflow.md)、[多算力协作](../../docs/multi-compute.md) 和 [外部集成](../../docs/integrations.md)。本地 Native 适配接口见 [本地模型](../../docs/local-model.md)。

## 测试

从仓库根目录运行 `node scripts/test-all.cjs agent`；也可单独执行 `node apps/agent-client/agent-core/tests/run-all.cjs`。TypeScript 环境及覆盖范围见 [测试](../../docs/testing.md)。
