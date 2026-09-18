# 本地 GEWU 算力 App

启动后直接进入算力页，显示已连接设备和推理任务。Qwen2.5-7B通过GEWU生成本机或近场请求；点击任务可展开生成内容。本机提问时发送按钮变为停止按钮，完成或停止后可继续发送。

## 模型与调用

模型目录：`getApplicationContext().filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，包含匹配的api_config.json、params和tokenizer.json。backend=knpu，max_ctx=2048。

HTML仅向ArkTS暴露发送/停止动作；模型路径和请求参数由App构造，消息通过JSON传输并以textContent渲染。每个请求创建独立Native session并在结束时销毁。多台聊天端可同时发问并各自流式收答；本机输入仍一次一路。保留完整的最近几轮问答作为下一次请求历史（最多3轮且受字符预算裁剪）；界面历史只在本次运行内保存。

消息输入最多1000字符、单次请求max_tokens=256，不设固定Decode时间截断。切后台或页面退出时取消正在进行的推理。

## 构建与测试

```bash
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default assembleHap --no-daemon
c++ -std=c++17 -pthread entry/src/main/cpp/tests/gewu_probe_lifecycle.cpp -o /tmp/gewu-chat-test
/tmp/gewu-chat-test
```

模型不进入HAP或Git；构建产物位于entry/build/default/outputs/default，安装需要有效签名。


## 同账号近场模式

模型端（NearbyConfig.ets中IS_SERVER=true）和聊天端两机登录同一个华为账号，开启Wi-Fi和蓝牙；连接由系统分布式组网和abilityConnectionManager提供。

模型端点“启用近场”并允许附近设备权限；再在聊天端点“连接”并授权。只有多个可信候选时显示设备选择。DeviceManager返回可信设备列表，本应用不执行异账号发现绑定，也不把可信列表宣称为已按账号过滤。两端保持前台亮屏。
