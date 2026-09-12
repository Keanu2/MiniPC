# MiniPC 近场聊天

HarmonyOS 无应用商店形态的近场对话：一台手机跑模型，其它手机当聊天端。两端包名相同（`com.jiuwen.registrychatui`），靠超级终端近场组网后协同。

## 目录

| 文件夹 | 角色 | 编译开关 |
|---|---|---|
| `src/model-end` | 模型机（跑 Qwen / GEWU） | `NearbyConfig.ets` 里 `IS_SERVER = true` |
| `src/chat-end` | 聊天机（界面 + 近场客户端） | `IS_SERVER = false` |

当前近场消息走 `abilityConnectionManager`（UIAbility 协同，一对一）。签名 HAP 用本机 `tools/signing`，不要提交证书和密码。
