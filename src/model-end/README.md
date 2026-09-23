# 算力端

`NearbyConfig.ets` 里 `IS_SERVER = true`。打开是仪表盘，能看到谁连上来了、哪条任务在跑。底部也能自己打字提问。

组网和选点规则在仓库根目录的 [README.md](../../README.md)，版本变化在 [CHANGELOG.md](../../CHANGELOG.md)。

这台机会 BLE 广播 manufacturer `0x6E77`、type `1`；组网确定编号后更新广播。聊天机只连接算力设备1，由它统一收发和调度。算力设备2等执行节点只与设备1保持算力链路，不接普通聊天请求。设备1收到不带 `sched` 的 `request` 时，`pickNode` 按空闲路数和可用内存在集群里选执行机。派出去的请求带 `sched=true`，对面必须自己跑。本机可以同时开多路 GEWU，CreateSession 失败才回「模型繁忙」。底部输入框还是一次一路。

1号停用后，存活算力里排名最靠前的一台在至少15秒、连续三次成功扫描都未见原中心时接管；短暂断链或仍能扫到原中心时不接管。后加入的算力不自己占「2号」，等中心按安装 UID 编号。

空闲时，内存、温度、CPU 和正在跑的路数每 2 秒轻量同步。成员变化由中心立刻发给其他算力：推理中只发精简名单，空闲时发完整清单，没变化则 30 秒保底。聊天机不收这份集群清单。聊天设备由当前中心按安装 UID 编号。标题会显示自己是第几号。任务标题是「聊天设备N  由算力设备N推理」。也可以附图，同样只显示在任务卡上。点「停用近场」会关掉广播。

平时选点是 `pickNode`。底部输入 `__route_auto__`、`__route_split__`、`__route_pin1__`、`__route_pin2__` 只用于对照实验，默认仍是自动。

模型放在 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，要有 `api_config.json`、`params`、`tokenizer.json`。backend=knpu，max_ctx=2048。输入大约 1000 字，单次 `max_tokens=256`。多台聊天机可以一起问；历史最多留 3 轮（6 条消息）且合计不超过 1800 字，只在这次运行里保留。

源码在 `entry/src/main/ets`。选点看 `cluster/ComputeRouter.ets`，页面在 `pages`。

模型不打进 HAP。编译：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

选点测试是 `cluster/ComputeRouter.test.cjs`。
