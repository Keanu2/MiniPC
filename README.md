# MiniPC

MiniPC 是面向 HarmonyOS 的近场算力协同项目。聊天端负责用户交互、Agent 工具调用和结果汇总；算力端运行本地模型。设备通过 BLE 发现和 `linkEnhance` 通信，需要设备系统提供对应能力。

## 功能

- Agent 工具执行、独立子任务并行、模型推理和结果汇总。
- 算力设备发现、编号、中心选举、请求路由与中心接管。
- 请求取消、超时和结果完整性校验；界面展示任务、耗时和设备状态。
- 算力端手动选模及按输入能力分流；图片推理需要另行提供私有 VL SDK、配套库、权重和设备权限。

## 工程目录

| 目录 | 用途 |
| --- | --- |
| `apps/agent-client` | Agent 聊天端 HarmonyOS 工程，含 `agent-core` 模块 |
| `apps/compute-node` | 算力端 HarmonyOS 工程 |
| `packages/inference-protocol` | 推理通信协议的 JavaScript 参考实现及测试 |
| `examples/nearby-validation-client` | 近场协议验证客户端 |
| `legacy/chat-client`、`legacy/compute-node` | 基础双端工程 |
| `scripts`、`tests`、`configs` | 构建入口、共享测试辅助及配置模板 |

分别打开应用工程构建；仓库根目录不是单个 HarmonyOS 工程。版本号以各工程 `AppScope/app.json5` 为准。

## 构建

应用安装并运行在 HarmonyOS 设备上；源码编译、签名在开发机完成，生成 HAP 后安装到目标设备。可直接在开发机使用 DevEco Studio：先准备下述依赖，再分别打开 `apps/agent-client` 和 `apps/compute-node`，同步依赖、配置签名并构建 `entry`。

需要 Node.js、JDK、HarmonyOS SDK、hvigor 和 ohpm。工程兼容 SDK 声明为 `6.0.2(22)`，目标声明为 `6.1.0(23)`。2026-10-26 已在干净源码副本使用 **Node.js 24.18.0、JDK 17、命令行 SDK 6.1.1.125、hvigor 6.24.4、ohpm 6.1.2.285** 验证两端 unsigned HAP 构建。其他工具版本需自行确认兼容性。

下面是**可选的 Windows 开发机 PowerShell 构建方式**，不是在鸿蒙设备上运行的命令，也不是 Windows CMD 语法。使用 DevEco Studio 图形界面时不必逐条执行；选择命令行方式时，从仓库根目录执行并替换本机工具路径：

```powershell
$cliRoot = '<HarmonyOS command-line-tools 解压目录>'
$env:JAVA_HOME = '<JDK 17 目录>'
$env:Path = "$env:JAVA_HOME\bin;$cliRoot\bin;$env:Path"
$env:DEVECO_SDK_HOME = Join-Path $cliRoot 'sdk'
$env:HVIGOR_JS = Join-Path $cliRoot 'hvigor\hvigor\bin\hvigor.js'

# 聊天端依赖：固定版本 AGenUI HAR，下载后校验 SHA-256
.\apps\agent-client\scripts\fetch-agenui.ps1

.\scripts\build-hap.ps1 -Target agent-client -InstallDependencies
.\scripts\build-hap.ps1 -Target compute-node -InstallDependencies
```

`DEVECO_SDK_HOME` 应指向包含 `default` 的 SDK 根目录，例如 `D:/command-line-tools/sdk`，不要指向 `sdk/default/openharmony`。Node.js 需在 PATH 中。已有 AGenUI HAR 时可用 `AGENUI_HAR` 或 `-AgenuiHar` 指定，不必再次下载。

**默认干净构建不含真实 VL 引擎。** 没有私有库时，算力端构建 VL 空实现，仍可使用系统 GEWU 文本推理；完整 VL 构建需先按 [构建说明](docs/build-and-run.md) 放置并检查私有库，更改私有库后使用 `-Clean` 重建。

产物位于各工程 `entry/build/default/outputs/default/entry-default-unsigned.hap`。安装到设备前需要配置自己的签名；聊天端和算力端使用相同 bundleName，应安装到不同设备。也可使用 DevEco Studio，具体依赖准备、签名和构建步骤见 [构建与运行](docs/build-and-run.md)。

## 模型与运行

模型权重、私有 SDK、配套设备系统库和签名材料不包含在仓库或默认安装包中。

| 模型路径 | 应用接口 | 额外条件 |
| --- | --- | --- |
| Qwen2.5-7B 文本 | 系统 GEWU / KNPU | 匹配设备的 GEWU 服务和权重 |
| Qwen3.5-9B 文本 | 系统 GEWU / KNPU，类型 `qwen3_5` | 支持该类型和权重的配套运行库；仅复制权重不够 |
| Qwen2.5-VL-3B 图片 | 应用内私有 VL SDK | 完整 VL 构建、配套权重、运行库及 NPU 访问权限 |

文本模型目录使用以下布局，模型名按实际部署替换：

```text
filesDir/models/<文本模型目录>/
├── api_config.json
├── params
└── tokenizer.json
```

VL 目录需要 `vl_params` 和 `tokenizer.json`。在算力端设置中选择已部署模型；当前私有 VL SDK 只接受带图请求，文字任务使用 GEWU 文本模型。完整目录、配置和能力选择见 [模型选择](docs/model-selection.md) 与 [构建与运行](docs/build-and-run.md)。

1. 分别在聊天设备、算力设备安装已签名的对应 HAP，并部署算力模型。
2. 完成设备信任/组网，开启蓝牙并授予应用所需权限。
3. 在算力端启用近场服务，在聊天端连接算力中心。
4. 确认模型和设备就绪后提交任务。外部查询需要聊天端联网。

支持所需系统能力和运行时的测试设备才能执行相应推理；生成 HAP 不代表任意零售设备均可运行这些模型。特定调试设备的 VL 权限方式见 [应用内直连说明](docs/vl-direct-mode.md)。

## 测试

```powershell
npm ci --ignore-scripts
npm test
```

GitHub Actions 在 Windows 和 Linux 运行可移植回归，**不执行 HarmonyOS HAP 构建或真机模型验收**。完整 SDK 声明检查使用 `npm run test:sdk`，需要本机 SDK；单组测试使用 `node scripts/test-all.cjs agent --portable`，也可选择 `legacy` 或 `protocol`。详见 [测试说明](docs/testing.md)。

## 文档与版本

[文档索引](docs/README.md) · [功能变更](CHANGELOG.md) · [Agent 版本记录](CHANGELOG.agent.md)
