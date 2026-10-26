# 应用内 VL 直连

Pro S 已验证现有 VL SDK 可以在普通 HAP 进程中直接推理。算力端的 `qwenvl_engine` 现在固定走应用内 SDK，不再调用文件队列辅助进程；不依赖 `vl-worker/enabled` 标记决定执行路径。旧辅助程序保留作历史诊断工具。

## 开启、检查、恢复

在这台 Windows 开发机已有 root HDC 连接时运行：

```powershell
.\scripts\vl-app-access.ps1 -Device 7QB0126509000160 -Action Start -RestartApp
.\scripts\vl-app-access.ps1 -Device 7QB0126509000160 -Action Status
.\scripts\vl-app-access.ps1 -Device 7QB0126509000160 -Action Stop -RestartApp
```

Start 会保存原 SELinux 模式和四个字符设备节点的身份、所有者、组、模式，然后设置 Permissive，并将原为 660 且所有者/组一致的节点所有者改为当前算力应用 UID。原组、模式保持不变；已经为 666 的节点无需改所有者。四个节点为：

- `/dev/npu0`
- `/dev/npu_manager`
- `/dev/dma_heap/system_heap`
- `/dev/dma_heap/npu_device_hugepage_heap`

这是设备全局的 SELinux 模式调整，持续至 Stop 或系统重启；不是 HAP 自身申请权限。脚本不写开机策略、不启动推理服务。设备重启后需重新 Start；通常应用重启不需要重新授权。`-RestartApp` 会停止并重新打开算力应用，用于清除已有的失败初始化状态，也使 Stop 时释放应用保有的模型与驱动句柄。

原状态保存在设备 root 专用目录 `/data/local/tmp/minipc-vl-app-access/state`，故不会因本地工作目录删除而丢失。重复 Start 校验已保存的设备启动 ID、应用 UID 和节点状态，不覆盖原始恢复值。Stop 只恢复身份与当前状态仍匹配的节点，第三方改变造成冲突时明确报错；跨系统启动不重放旧 inode 的权限。旧辅助进程启用标记会暂时停用并随 Stop 恢复，方便尚未更新的旧 HAP 也能在授权后走直连；更新后的 HAP 忽略该标记。

## 部署边界

新 C++ 入口需重新编译安装算力端 HAP 才会生效。设备上原 1.0.45 HAP 同样可以借助停用旧辅助标记走直接 SDK，因此权限脚本可以先使用。本次开发只编译检查了新的原生引擎，没有替换设备签名 HAP。

当前 Pro S 上旧 `vl-worker` 服务已停止，直连授权已开启。应用内授权失败会检查上述四个节点，包括原来遗漏的 npu_manager；不再把管理节点访问失败仅显示成 SDK 会话错误。

手机不需要更改推理协议或模型目录布局。已经具有直接 SDK 所需权限的手机保持原有应用内执行方式；不要对不需要授权的设备运行权限脚本。Pro 仍按此前要求保留纯文本部署。

首次因果对照及两次真实应用内推理见 [实测记录](vl-selinux-validation-2026-10-20.md)。脚本的 Start、重复 Start、Stop 均另在 Pro S 实测，Stop 恢复 Enforcing 及四个节点原所有者/660 后，再按本次使用要求开启。
