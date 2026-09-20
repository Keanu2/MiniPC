# 算力端

`NearbyConfig.ets` 里 `IS_SERVER = true`。打开是仪表盘，能看到谁连上来了、哪条任务在跑。底部也能自己打字提问。

组网和选点规则在仓库根目录的 [README.md](../../README.md)，版本变化在 [CHANGELOG.md](../../CHANGELOG.md)。

这台机会 BLE 广播 manufacturer `0x6E77`、type `1`，等聊天机或其它算力用 `linkEnhance` 连上来。收到不带 `sched` 的 `request` 时，`cluster/ComputeRouter.ets` 的 `pickNode` 会在本机和其它算力里挑一台；派出去的请求带 `sched=true`，对面必须自己跑。本机可以同时开多路 GEWU，CreateSession 失败才回「模型繁忙」。底部输入框还是一次一路。

大约每 3 秒同步一次内存、模型和正在跑的路数。本机固定叫算力设备1。任务标题是「聊天设备N  由算力设备N推理」。也可以附图，同样只显示在任务卡上。

模型放在 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，要有 `api_config.json`、`params`、`tokenizer.json`。backend=knpu，max_ctx=2048。输入大约 1000 字，单次 `max_tokens=256`。多台聊天机可以一起问；历史最多 3 轮，只在这次运行里保留。

源码在 `entry/src/main/ets`。选点看 `cluster/ComputeRouter.ets`，页面在 `pages`。

模型不打进 HAP。编译：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

选点测试是 `cluster/ComputeRouter.test.cjs`。
