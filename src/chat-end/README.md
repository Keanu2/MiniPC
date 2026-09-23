# 聊天端

`NearbyConfig.ets` 里 `IS_SERVER = false`。打开就是聊天页，用户气泡在右，回复在左。连上算力之后状态只写「协同已就绪」。

怎么组网、谁来调度，看仓库根目录的 [README.md](../../README.md)。版本变化在 [CHANGELOG.md](../../CHANGELOG.md)。

聊天机扫 BLE manufacturer `0x6E77`、type `1`，只连已经在超级终端里组过网（同一华为账号或可信设备）、且广播编号为1的算力设备；没有算力设备1时等待组网，不回退连接算力设备2。连上之后标题会变成「聊天设备N」，状态栏写「协同已就绪」。连接中心后所有请求都由设备1调度；仅在未连接中心且本机 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0` 已部署权重时才本地推理。可以附图，图只出现在气泡里。

中心停用后，聊天机等待原2号完成缺席确认并广播为新1号；自动重连会覆盖这段接管时间，超过有限次数后仍可手动点击「连接」。

模型需要 `api_config.json`、`params`、`tokenizer.json`，backend 是 knpu，max_ctx=2048。手头用来测的聊天机一般没装权重。输入大约 1000 字，单次 `max_tokens=256`，历史最多留 3 轮（6 条消息）且合计不超过 1800 字，关掉 App 就没了。切到后台或离开页面会停掉本机推理。

源码在 `entry/src/main/ets`：`pages` 是聊天页，`nearby` 是通道，`llm` 是本机模型，`protocol` 是消息格式。

模型不打进 HAP，产物在 `entry/build/default/outputs/default`，装到手机上要签名：

```bat
set JAVA_HOME=D:\MiniPC\tools\jdk\jdk-17.0.20.1+1
set DEVECO_SDK_HOME=D:\command-line-tools\sdk
D:\command-line-tools\hvigor\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

旁边的 `*.test.cjs` 用本机 TypeScript 转译就能跑。
