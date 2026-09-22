# 算力端

`NearbyConfig.ets` 里 `IS_SERVER = true`。打开是仪表盘，能看到谁连上来了、哪条任务在跑。底部也能自己打字提问。

组网和选点规则在仓库根目录的 [README.md](../../README.md)，版本变化在 [CHANGELOG.md](../../CHANGELOG.md)。

这台机会 BLE 广播 manufacturer `0x6E77`、type `1`；组网确定编号后更新广播。聊天机只连接算力设备1，由它统一收发和调度。算力设备2等执行节点只与设备1保持算力链路，不接普通聊天请求。设备1收到不带 `sched` 的 `request` 时，`pickNode` 按空闲路数和可用内存在集群里选执行机。派出去的请求带 `sched=true`，对面必须自己跑。本机可以同时开多路 GEWU，CreateSession 失败才回「模型繁忙」。底部输入框还是一次一路。

1号停用后，2号在至少15秒且连续三次扫描都未见原中心时接管；短暂断链或仍能扫到原中心时不接管。内存/任务状态每5秒轻量更新，成员变化立即同步清单，完整清单另有30秒保底刷新。

大约每 3 秒同步一次内存、模型和正在跑的路数。多台算力按可用内存编号，余量最大的是算力设备1（算力中心）。聊天设备按蓝牙名全网编号。标题会显示自己是第几号。任务标题是「聊天设备N  由算力设备N推理」。也可以附图，同样只显示在任务卡上。点「停用近场」会关掉广播。

模型放在 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，要有 `api_config.json`、`params`、`tokenizer.json`。backend=knpu，max_ctx=2048。输入大约 1000 字，单次 `max_tokens=256`。多台聊天机可以一起问；历史最多 3 轮，只在这次运行里保留。

源码在 `entry/src/main/ets`。选点看 `cluster/ComputeRouter.ets`，页面在 `pages`。

模型不打进 HAP。编译：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

选点测试是 `cluster/ComputeRouter.test.cjs`。
