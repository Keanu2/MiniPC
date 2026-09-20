# 聊天端 HAP

`IS_SERVER = false`。启动后是聊天页：右侧用户气泡，流式回复在左侧。连上算力后状态只显示「协同已就绪」。

整体架构、选点规则、协议约定见仓库根目录 [README.md](../../README.md) 和 [CHANGELOG.md](../../CHANGELOG.md)。**改功能先写 Unreleased。**

## 这一端做什么

- 发现并连接正在 BLE 广播的算力机（manufacturer `0x6E77`、type=`1`）。
- 本机有 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0` 则本地推理，不走近场；没有则发 `request` 给算力机。
- 可以选图，只在气泡里展示，不送 LLM、不走近场。
- 回复末尾若带「由算力设备N推理」，来自算力机改写过的 `done.source`。

## 模型与调用

模型目录：`getApplicationContext().filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，需要 `api_config.json`、`params`、`tokenizer.json`。backend=knpu，max_ctx=2048。当前测试用的聊天机一般没有权重。

输入最多 1000 字符（附图前缀后略放宽），单次 `max_tokens=256`。历史最多 3 轮且受字符预算裁剪，只在本次运行内保存。切后台或离开页面会取消本机推理。

## 源码

`entry/src/main/ets`：`protocol` 消息，`nearby` 通道与角色开关，`llm` 本机推理，`cluster` 设备信息回复，`media` 选图，`ui` WebView 桥，`pages` 聊天页。

## 构建

模型不进 HAP / Git。产物在 `entry/build/default/outputs/default`，安装需要签名。Windows 命令行示例：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

单元测试是旁边的 `*.test.cjs`，用本机 TypeScript 转译跑。
