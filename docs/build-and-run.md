# 构建与运行

最终应用是安装在 HarmonyOS 设备上的 HAP。下文明确区分开发机（编译、签名、安装工具）与目标鸿蒙设备（应用运行、模型推理）。开发机可以使用 DevEco Studio 图形界面；Windows PowerShell 只是本仓库提供的可选命令行入口，无需在目标设备执行。

## 工程选择

| 构建目标 | 工程目录 | 应用职责 |
| --- | --- | --- |
| `agent-client` | `apps/agent-client` | Agent 聊天、工具执行与汇总 |
| `compute-node` | `apps/compute-node` | 本地推理、设备组网和路由 |
| `legacy-chat-client` | `legacy/chat-client` | 基础聊天端 |
| `legacy-compute-node` | `legacy/compute-node` | 基础算力端 |

仓库根目录不是单个 HarmonyOS 工程。`examples/nearby-validation-client` 可单独用 DevEco Studio 打开；`packages/inference-protocol` 只有 JavaScript 参考实现及测试，不生成 HAP。

## 工具与依赖

需要 Node.js、JDK、HarmonyOS SDK、hvigor 和 ohpm。工程兼容 SDK 声明为 `6.0.2(22)`，目标声明为 `6.1.0(23)`。安装的构建 SDK 与应用兼容/目标声明是不同概念。

2026-10-26 使用 GitHub 提交 `a0d5210` 的干净源码副本完成以下验证：Node.js 24.18.0、JDK 17.0.20.1、HarmonyOS 命令行 SDK 6.1.1.125、hvigor 6.24.4、ohpm 6.1.2.285。副本没有本机签名、原有 oh_modules 或私有 VL SO；聊天端额外下载固定版本 AGenUI HAR。随后在同一隔离副本补齐本机 27 项私有库并以 `-Clean` 重建，真实 VL 引擎及依赖也已打包通过；这些私有文件不随本次更新发布。其他工具组合需确认其与 SDK 的兼容性。

### AGenUI

聊天端使用 `AGenUI-1.2.0.beta1` Release 的 `AGenUI-1.2.0-harmony.har`，SHA-256 为 `1d879a003abba4bc715a2d09026204274dd1ad984f8c305c1de67d20001ab4bc`。

从仓库根目录执行以下任一入口：

```powershell
.\apps\agent-client\scripts\fetch-agenui.ps1
```

或在具备 Bash、curl 和 shasum 的环境中执行 `bash apps/agent-client/scripts/fetch-agenui.sh`。两个脚本均固定版本并校验哈希，不表示下载最新版本。PowerShell 入口避免 Windows 用户另配 Bash/shasum；已有正确文件时直接校验返回，已有不同文件时拒绝覆盖。

HAR 放在 `apps/agent-client/libs/agenui.har`，不入库。已有 HAR 可用 `AGENUI_HAR` / `-AgenuiHar` 提供。聊天端 Native 所需 AKI 源码已包含在仓库中。

### 可选的 VL 私有库

没有 `libqwen2vl_sdk.so` 时，算力端 CMake 会编译 `napi_engine_stub.cpp`；HAP 可正常构建，文字 GEWU 路径保留，图片请求会报告引擎不可用。

要构建真实 VL 引擎，先取得适配目标设备、来源可信的完整私有预编译库包，依 [清单](../apps/compute-node/entry/src/main/cpp/libs.manifest.json) 放置：

```powershell
.\scripts\place-vl-libs.ps1 -Source '<完整 arm64-v8a 私有库目录>'
.\scripts\place-vl-libs.ps1
.\scripts\build-hap.ps1 -Target compute-node -InstallDependencies -Clean
```

目标为 `apps/compute-node/entry/src/main/cpp/libs/arm64-v8a/`。放置脚本只检查清单文件存在且非空，不验证 ABI、库版本、设备适配或模型正确性；不要将“文件齐全”当成真机验收。只有部分库时可能进入真实引擎分支后链接失败，应补齐完整依赖再构建。此前构建过空实现时，补入 SO 文件本身可能不会使 Native 增量缓存重建；增加、替换或移除私有库后使用 `-Clean` 清理并重建，避免“构建成功”但仍打包旧空实现。

## 可选：Windows 开发机命令行构建

以下是 PowerShell 语法，不是 CMD 或鸿蒙设备 shell 命令。在 Windows 开发机的仓库根目录执行，路径占位符替换为实际位置；使用 [DevEco Studio](#deveco-studio) 时可跳过这一命令行入口：

```powershell
$cliRoot = '<HarmonyOS command-line-tools 解压目录>'
$env:JAVA_HOME = '<JDK 17 目录>'
$env:Path = "$env:JAVA_HOME\bin;$cliRoot\bin;$env:Path"
$env:DEVECO_SDK_HOME = Join-Path $cliRoot 'sdk'
$env:HVIGOR_JS = Join-Path $cliRoot 'hvigor\hvigor\bin\hvigor.js'

node --version
java -version
ohpm --version

.\apps\agent-client\scripts\fetch-agenui.ps1
.\scripts\build-hap.ps1 -Target agent-client -InstallDependencies
.\scripts\build-hap.ps1 -Target compute-node -InstallDependencies
```

对于已验证的命令行工具布局，SDK 路径应为包含 `default` 的根目录，例如 `D:/command-line-tools/sdk`，而非 `sdk/default/openharmony`。`HVIGOR_JS` 指向 CLI 的入口文件；脚本会在本地忽略目录创建命令行工具自带插件的 junction。自定义工具布局需相应调整入口，DevEco Studio 用户可使用下文 GUI 路径。

`-InstallDependencies` 执行各工程的 `ohpm install --all`。根目录的 npm 依赖用于回归测试，不能替代 ohpm。依赖已安装后可省略该开关。旧构建目标 agent-chat、agent-compute、legacy-chat、legacy-compute 仍作为兼容别名。

### 产物与签名

上述干净配置生成：

- `apps/agent-client/entry/build/default/outputs/default/entry-default-unsigned.hap`
- `apps/compute-node/entry/build/default/outputs/default/entry-default-unsigned.hap`

没有签名配置时，日志出现 `No signingConfig found` 属于预期；unsigned HAP 不能直接作为已签名设备安装包使用。配置自己的设备签名后重新构建。不要提交私钥、证书、SDK、HAR、私有 SO、模型权重或构建包。

## DevEco Studio

1. 准备上文 AGenUI；需要 VL 时同时准备完整私有库。
2. 分别打开 `apps/agent-client` 或 `apps/compute-node`，选择匹配的本机 SDK/JDK 并同步 ohpm 依赖。
3. 配置自己的签名，构建 `entry` 模块并安装到已授权设备。

Agent 聊天端、算力端和验证客户端使用同一个 `com.jiuwen.registrychatui`，不同角色应安装到不同设备；在同一设备安装会更新同名应用。基础双端的应用标识以各自 AppScope 为准。

## 部署模型与运行

文本模型目录：

```text
filesDir/models/<文本模型目录>/
├── api_config.json
├── params
└── tokenizer.json
```

三个文件都需存在、非空且对应用可读。Qwen2.5-7B 使用此布局；Qwen3.5-9B 同走系统 GEWU 文本接口，配置的 name/type 为 `qwen3_5`，模板见 [api_config.json](../configs/models/qwen3_5/api_config.json)。Qwen3.5 必须有支持该类型、权重格式及设备平台的配套 GEWU 运行库，仅复制权重不保证可用。

VL 目录需要 `vl_params` 和 `tokenizer.json`，另需编入真实 VL 引擎的 HAP、适配的运行库及 NPU 访问权限。当前路径固定使用应用内 SDK，旧文件队列辅助进程只保留作历史诊断工具；特定调试设备的权限条件见 [VL 应用内直连](vl-direct-mode.md)。

模型不打进 HAP。filesDir 由系统提供，勿照抄其他设备绝对沙盒路径；HDC 物理路径与应用内沙箱路径也不能任意互换。文件所有者、目录/文件权限需对应当前安装应用，不能沿用另一台设备的 UID。部署与文件校验完成后，在算力端“设置 → 当前模型 → 应用选择”选择模型，详见 [模型选择](model-selection.md)。

1. 分别安装聊天端、算力端签名 HAP，再部署算力模型。
2. 完成设备信任/组网，开启蓝牙并授予应用权限。
3. 在算力设备启用近场服务，聊天端连接中心，等待能力协商后提交任务。
4. 在实际设备验证文字或图片结果、正常结束与连续请求。多台算力见 [多算力协作](multi-compute.md)。

Qwen2.5-7B 和当前 Qwen3.5 部署是文字路径；私有 VL SDK 要求图片输入。外部工具网络和授权在聊天端处理。编译成功、回归通过和真机推理是三项不同验证；本次干净源码构建没有安装 HAP，也没有用它替换任何设备的应用。

## 常见错误

| 现象 | 检查 |
| --- | --- |
| HAR 找不到 | 运行 PowerShell/Bash 获取脚本，或指定已有 HAR |
| hvigor/插件或 SDK 找不到 | 核对 CLI 布局、SDK 根目录和 HVIGOR_JS |
| `spawn java ENOENT` | JAVA_HOME 之外，还需把其 bin 加入 PATH |
| ohpm 找不到 / 依赖未装 | CLI bin 加入 PATH；使用 -InstallDependencies |
| HAP 构建成功但 VL 引擎不可用 | 是否只构建了空实现；按私有库清单准备完整依赖后重建 |
| unsigned HAP 无法安装 | 配置设备签名后重新构建 |
| 模型未就绪 / 加载失败 | 权重、配置名、应用权限、设备与配套 GEWU/KNPU 版本 |
| 无可连接中心 | 信任关系、蓝牙、权限、算力服务和设备编号 |
| 超过传输预算 | 缩小任务/图片，限制按 UTF-8 字节计，见通信协议 |

GitHub Actions 当前只运行 Windows/Linux 可移植回归，不验证 HarmonyOS SDK 构建或真机推理。
