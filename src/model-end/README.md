# 本地 GEWU 聊天 App

启动后直接进入聊天页，输入问题后右侧显示用户气泡，Qwen2.5-7B通过GEWU流式更新左侧气泡。已移除右上设备信息和静态预览说明。生成期间发送按钮变为停止按钮，完成或停止后可继续发送。

## 模型与调用

模型目录：`getApplicationContext().filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0`，包含匹配的api_config.json、params和tokenizer.json。backend=knpu，max_ctx=2048。

HTML仅向ArkTS暴露发送/停止动作；模型路径和请求参数由App构造，消息通过JSON传输并以textContent渲染。每个请求创建独立Native session并在结束时销毁。保留完整的最近几轮问答作为下一次请求历史（最多3轮且受字符预算裁剪）；界面历史只在本次运行内保存。

消息输入最多1000字符、单次请求max_tokens=256，不设固定Decode时间截断。切后台或页面退出时取消正在进行的推理。此版本已用0391完成真实UI验证，其他设备需单独部署对应模型并验收。

## 构建与测试

```bash
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default assembleHap --no-daemon
c++ -std=c++17 -pthread entry/src/main/cpp/tests/gewu_probe_lifecycle.cpp -o /tmp/gewu-chat-test
/tmp/gewu-chat-test
```

模型不进入HAP或Git；构建产物位于entry/build/default/outputs/default，安装需要有效签名。Native模拟测试覆盖重复请求、忙状态、取消、同步及迟到回调、错误后重试。真机已验证发送→流式气泡、带历史的第二轮、停止→再次发送。

App私有目录的gewu-chat.jsonl保留最近一次请求诊断日志。旧gewuProbe启动参数诊断入口已移除，普通启动即可通过聊天页操作。


## 同账号近场模式

0391是模型端（NearbyConfig.ets中IS_SERVER=true），2938是聊天端（false）。两机登录同一个华为账号，开启Wi-Fi和蓝牙；连接由系统分布式组网和abilityConnectionManager提供，应用不使用固定IP、TCP端口、热点配置或TCP回退。

首次在0391点“启用近场”并允许附近设备权限；再在2938点“连接”并授权。只有多个可信候选时显示设备选择。DeviceManager返回可信设备列表，本应用不执行异账号发现绑定，也不把可信列表宣称为已按账号过滤。两端保持前台亮屏。

2938创建协同会话，0391的EntryAbility.onCollaborate校验并接收；等聊天页面加载后完成hello/hello_ack。request/cancel与delta/done/error通过sendMessage传送：JSON按UTF-8字节切成480字节块并Base64封装，单条低于1KB，接收后校验重组再执行原聊天业务。保留请求ID、连接epoch、单模型忙状态和独立历史。

会话由Ability持有，页面订阅。退后台、手动断开或会话失效结束连接；客户端保留已收到内容，模型端取消该远端请求。再次连接需用户点击，不重放问题，不循环拉起对端。连接握手20秒、未完成分片15秒期限仅适用于通信，模型生成无固定Decode截断。

测试：

```bash
node entry/src/main/ets/nearby/ChatProtocol.test.cjs
node entry/src/main/ets/nearby/NearbyChannel.test.cjs
```

2026-09-09：双角色ArkTS构建、协议/会话mock、Native生命周期回归及HAP签名验证通过；softbus-server-signed.hap、softbus-client-signed.hap已覆盖安装对应手机。真实软总线聊天及排除USB/热点影响的无线验收待完成，不能以mock或系统组网替代。

旧TCP实现及其当前使用说明已删除；历史TCP验收保留在算力互联项目历史文档与Git中。
