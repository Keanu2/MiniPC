# 同步 MiniPC（2026-10-16）

此前同步的 `Keanu2/Agent-MiniPC` 已停止维护，只新增了迁移说明。经确认，本次实际合入 `Keanu2/MiniPC` 的 `main`，提交 `ab3965bc0df12a67a064f0d981a9d2462713ba14`；相对合并前本地分支有 53 个未包含的提交。本地修复原始快照保留在 `9eabbbd`。

采用新仓库正式应用路径：聊天端 `apps/agent-client`，算力端 `apps/compute-node`，共享协议 `packages/inference-protocol`。保留上游目录重组、视觉模型、图片传输、任务阶段、能力与复杂度路由、近场服务恢复及测试入口。此前本地改动按正式应用路径进行三方合并，没有把修复写入 `legacy` 副本。

冲突处理保留 Agent 开关、无上下文普通聊天、任务分组、GEWU 文本多请求并发、生成与 Native 清理解耦、计数同步及后台近场连接。能力与档位继续参与选点，空闲文本节点不足时才允许同机并发；VL 仍单会话，并等待本机文本 Native 清理结束后才加载。普通聊天同时支持本轮图片，推理阶段按请求透传。

`origin` 指向 `https://github.com/Keanu2/MiniPC.git`，当前 `master` 跟踪 `origin/main`；原远端以 `agent-minipc` 保留。没有推送远端。未跟踪的个人文档、旧目录本地配置和模型文件未加入提交。

验证：`node scripts/test-all.cjs agent --portable` 的 27 组离线回归通过；随后补充的 Native 清理与 VL 互斥检查包含在 Host 的 16/16 回归中并通过。旧版应用及共享协议组在首次全量检查中通过。`git diff --check` 与暂存差异检查通过。未编译 HAP、安装应用或执行真机测试，编译验证由用户进行。
