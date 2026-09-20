# 算力端 HAP

`IS_SERVER = true`。启动后是算力仪表盘：已连接设备、进行中/已完成任务。本机也可以在底部提问。

整体架构、选点规则、协议约定见仓库根目录 [README.md](../../README.md) 和 [CHANGELOG.md](../../CHANGELOG.md)。**改功能先写 Unreleased。**

## 这一端做什么

- BLE 广播 manufacturer `0x6E77`、type=`1`，并接受聊天机 / 其它算力机的 `linkEnhance` 连接。
- 收到无 `sched` 的 `request` 时，用 `cluster/ComputeRouter.ets` 的 `pickNode` 在本机和其它算力里选一台。派出的请求带 `sched=true`，对端必须本地跑。
- 本机可多路 GEWU session；只有 CreateSession/start 失败才回「模型繁忙」。本机输入框仍一次一路。
- 每 3 秒同步设备信息（内存、模型、推理路数）。
- 任务标题「聊天设备N  由算力设备N推理」。本机永远是算力设备1。
- 可以选图，只在任务卡展示，不送 LLM、不走近场。

## 模型与调用

模型目录：`getApplicationContext().filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，需要 `api_config.json`、`params`、`tokenizer.json`。backend=knpu，max_ctx=2048。

输入最多 1000 字符（附图前缀后略放宽），单次 `max_tokens=256`。多台聊天机可同时发问；历史最多 3 轮且受字符预算裁剪，只在本次运行内保存。切后台或离开页面会取消本机推理。

## 源码

`entry/src/main/ets`：`protocol` 消息，`nearby` 通道与角色开关，`llm` 本机推理，`cluster` 设备信息与 **`ComputeRouter` 选点**，`media` 选图，`ui` WebView 桥与仪表盘类型，`pages` 算力页编排。

## 构建

模型不进 HAP / Git。产物在 `entry/build/default/outputs/default`，安装需要签名。Windows 命令行示例：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

单元测试是旁边的 `*.test.cjs`，用本机 TypeScript 转译跑。选点测试：`cluster/ComputeRouter.test.cjs`。
