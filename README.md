# MiniPC 近场聊天

HarmonyOS 一台 PC 跑模型，其它手机当聊天端，靠近场组网后协同。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 目录

| 文件夹 | 角色 | 编译开关 |
|---|---|---|
| `src/model-end` | 模型机（跑 Qwen / GEWU） | `NearbyConfig.ets` 里 `IS_SERVER = true` |
| `src/chat-end` | 聊天机（界面 + 近场客户端） | `IS_SERVER = false` |

当前近场消息走蓝牙 `linkEnhance`。打开应用会自动发现并连接，仍可手动连接或断开。签名 HAP 用本机 `tools/signing`，不要提交证书和密码。
