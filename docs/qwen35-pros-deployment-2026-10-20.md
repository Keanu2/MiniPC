# Qwen3.5-9B 迁入 Pro S（2026-10-20）

## 最新复测：替换系统库后已跑通

用户替换 Pro S 的系统 SO 后，在现有 1.0.45 HAP 内重新选择 Qwen3.5，通过原有文本 GEWU 接口完成推理；无需修改应用或重新编译 HAP。

- 系统 `libgewusvc_model.so` 从 265,808 bytes 变为 417,312 bytes，新文件 SHA-256：`2789d39c4fedcd75ad37f5298b8b8b9e626cc5d2f597c82227e716d1d65d51f1`。
- 新库包含 `GewuQwen3_5Model` / `GewuQwen3_5Session`。真实 GEWU 服务日志识别运行时接口版本 major=1、minor=2。
- Qwen3.5：`create=0`、`submit=0`、`destroy=0`，输入 `1+1=`，返回 `1+1=2`，finish_reason=stop。响应事件 t=3603 ms，结束 t=3648 ms；模型上报加载 1376.624 ms、prefill 833.502 ms、decode 1168.908 ms。任务卡显示耗时 3.6s、已完成，推理详情输出确认为 `1+1=2`。
- Qwen2.5-7B 对照：同一 HAP 和新系统库，`create=0`、`submit=0`、`destroy=0`，同一输入返回 `1+1=2`，响应事件 t=3626 ms，结束 t=3659 ms。
- 两次均使用 backend=knpu、max_ctx=32768、stream=false，调用 `OH_QoS_GewuCreateSession` / `SubmitRequest`；未使用 VL SDK 或辅助进程。

这验证了两种文本模型的基本加载、生成、回调和结束链路；尚未测试长上下文、Agent、多请求并发或远端聊天设备。

**诊断方式需要区分：**新客户端在打开权重前检查规范化路径前缀。root 独立程序使用 `/data/app/el2/...` 物理路径时被拒绝，两种模型均得到 `Failed to open weight file for chat session` / 401；实际 HAP 使用 `/data/storage/el2/base/files/models/...` 成功。因此物理路径诊断结果不能作为新库模型不可用的结论。另外，新系统模型模块内部会话入参布局发生变化，旧 `model-factory-probe` 不适用于新模块；其替换后出现的 `dup weightFd` 错误不属于正式应用调用失败。继续验证应优先使用正式公开接口和应用沙箱路径。

复测后 Pro S 留在 `Qwen3.5-9B-Q4_N_0_G128`；Pro 的模型选择未修改。本轮没有修改系统 SO、模型配置或应用源码。

证据保存在 `.hvigor/qwen35-transfer-2026-10-20/`：`app-replaced-gewu.jsonl`（Qwen3.5）、`app-qwen2-replaced-gewu.jsonl`（7B）、`app-replaced-system-gewu.log`、`replaced-detail-ui.json`。下文保留替换前的失败定位，供比较。

## 已完成

模型从手机 `53V0224C19002918`（PLR-AL00）的应用模型目录复制到本机中转，再复制到 MateBook Pro S `7QB0126509000160`：

```text
/data/app/el2/100/base/com.jiuwen.registrychatui/files/models/Qwen3.5-9B-Q4_N_0_G128/
  params          8,288,632,832 bytes
  tokenizer.json     12,807,982 bytes
  api_config.json         796 bytes
```

手机原文件未移动或修改。Pro S 原 7B 和 VL 目录保持原样，Pro 未部署新模型。

目标文件均属于应用 UID/GID 20020176，目录 700、文件 600。先传到 `files/model-imports/` 暂存，在校验完成后原子移入 `files/models/`，没有把半传输模型暴露给目录扫描。

配置使用用户补充的完整 JSON，保存在 [配置模板](../configs/models/qwen3_5/api_config.json)：name/type 为 `qwen3_5`，format 为 `gewu`，包含 `layers_per_group=4`、`linear_layers_per_group=3` 和 `tie_word_embeddings=false`。没有沿用手机旧配置中的 `qwen3.5`/CPU 字段。当前文件集只提供文本路径所需的 params/tokenizer；没有声明可通过现有 VL SDK 处理图片。

## 完整性校验

手机原文件、本机中转和 Pro S 目标文件的 SHA-256 一致：

```text
params
ebba60e999ad9b2f7c0666219181872af31c9a2c163393643c60783c9a328e54

tokenizer.json
5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42
```

## 替换前：推理验证未通过（历史记录）

### 同一程序对照

独立程序调用 PC 系统 `OH_QoS_GewuCreateSession` / `SubmitRequest`，backend=knpu、max_ctx=512：

- Qwen3.5：create_error=401，150 ms，未进入请求提交。
- 原 Qwen2.5-7B：create_error=0、submit_error=0、destroy_error=0，4321 ms 返回算术结果 `2`。

NDK `qos.h` 中 401 为 `OH_QOS_GEWU_INVAL`。它说明本机现有 GEWU 拒绝了新模型会话参数，不能仅据此断言所有 GEWU 或硬件均不支持该模型。

### 实际 HAP

暂时选中新目录并重新打开现有 1.0.45 HAP，发送 `1+1=`：应用正确定位新目录，三文件均可读；创建会话返回 401，界面约 0.2 秒结束并显示失败。实际属性为 backend=knpu、max_ctx=32768。测试后已恢复原 VL 模型选择，没有让失败的新模型取代当前可用模型。

### 进一步定位：模型类型识别失败

用户确认 Qwen3.5 应与 7B 使用相同的文本 GEWU 路径。现有 `ModelRegistry → LocalChat → gewu_probe → OH_QoS_GewuCreateSession` 已使用这一通用路径：从配置读取请求类型 `qwen3_5`，没有转到 VL 引擎。

为定位 401，在独立进程内加载 Pro S 自带的 `/system/lib64/libgewusvc_model.so`，读取原始 `api_config.json`，调用该模块内部会话入口，并将**本诊断进程**的 `OH_LOG_Print` 输出到标准输出。得到：

```text
[gewu_entity_manager.cpp:CreateModel:112]: Failed to create model with invalid model type
[gewu_entity_manager.cpp:CreateOrGetModelLocked:180]: Failed to create model with name: qwen3_5.
factory_error=401 session=4294967295
```

静态调用链也显示 `CreateModel` 先读取配置的 `type`，再转换为内部类型、查找模型工厂；上述错误出现在加载模型配置和权重之前。因此已确认：**本机系统模型层不识别当前配置里的 `qwen3_5` 类型**。这比“库里没搜到字符串”的线索更明确；它不代表未来版本的 GEWU 或硬件无法支持 Qwen3.5，也不保证补上类型后下层引擎就一定兼容。

该内部入口只用于独立诊断，不能替代正式应用接口或作为生产集成方式。诊断源码及原始日志在 `.hvigor/qwen35-transfer-2026-10-20/`，包括 `model-factory-probe.cpp`、`probe-log.cpp`、`qwen35-factory-log.txt`。本次没有修改系统库、源手机配置、模型权重或应用模型选择。

因此，**迁移和发现已完成，Qwen3.5 推理尚未跑通**。要保持和 7B 一样的系统文本接口，需要运行时提供方给出匹配 Pro S 系统、支持 `qwen3_5` 的 GEWU 版本及部署方法。需要同时确认系统模型层的类型注册、下层引擎对该模型结构与量化权重的支持；只提供一个新 `kernel.so` 不能解决当前发生在模型工厂之前的拒绝。如果提供的是独立 SDK，则还需确认其支持该模型及 Pro S，再在通用文本引擎接口下接入。当前没有替换系统 GEWU 库或把 qwen3_5 请求伪装成 qwen2。

## 首次迁移后的设备状态（替换前）

Pro S 已按本次要求开启 [VL 应用内直连](vl-direct-mode.md)：Permissive，四个节点仅授予当前应用，旧 VL 辅助进程已停止。原模型选择保持 `Qwen-2.5-vl-3B-instruct-Q4_N_0_G128`。新的原生入口编译通过，算力端 23 个测试文件通过；未安装重新签名的 HAP。

模型诊断日志和中转文件保存在 `.hvigor/qwen35-transfer-2026-10-20/`，包含 `gewu-probe.log`、`qwen2-control.log`、`app-gewu-result.jsonl` 和实际界面 JSON。
