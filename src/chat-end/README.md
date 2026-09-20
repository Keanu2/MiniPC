# 本地 GEWU 聊天 App

启动后直接进入聊天页，输入问题后右侧显示用户气泡，Qwen2.5-7B通过GEWU流式更新左侧气泡。已移除右上设备信息和静态预览说明。生成期间发送按钮变为停止按钮，完成或停止后可继续发送。

## 模型与调用

模型目录：`getApplicationContext().filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，包含匹配的api_config.json、params和tokenizer.json。backend=knpu，max_ctx=2048。

HTML仅向ArkTS暴露发送/停止动作；模型路径和请求参数由App构造，消息通过JSON传输并以textContent渲染。每个请求创建独立Native session并在结束时销毁。保留完整的最近几轮问答作为下一次请求历史（最多3轮且受字符预算裁剪）；界面历史只在本次运行内保存。

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

## 源码分层

`entry/src/main/ets`：`protocol` 消息编解码，`nearby` 近场通道与角色开关，`llm` 本机推理，`cluster` 设备信息，`media` 选图，`ui` WebView 桥，`pages` 聊天页编排。

## 同账号近场模式

模型端（NearbyConfig.ets中IS_SERVER=true）和聊天端两机登录同一个华为账号，开启Wi-Fi和蓝牙；连接由系统分布式组网和abilityConnectionManager提供。

模型端点“启用近场”并允许附近设备权限；再在聊天端点“连接”并授权。只有多个可信候选时显示设备选择。DeviceManager返回可信设备列表，本应用不执行异账号发现绑定，也不把可信列表宣称为已按账号过滤。两端保持前台亮屏。
