# VL 库来源核对（2026-10-16）

已只读核对 MateBook Pro S（7QB0126509000160）和 MateBook Pro（3QC0124C20000251）的系统/vendor 库目录。两台设备都有清单中 25 个同名库；系统中没有 `libqwen2vl_sdk.so` 和项目重命名的 `libcxx.so`。应用已安装目录中的库不算系统自带。

## 当前需要额外保留的部分

| 文件 | PC 系统情况 | 当前结论 |
| --- | --- | --- |
| libqwen2vl_sdk.so | 无 | 必须提供 VL SDK |
| libgewurt_kernel.so | 有旧版 | 系统旧版缺少当前 VL 需要的算子，使用配套新版 |
| libgewurt_base.so | 有旧版 | 当前成功方案使用 SDK 配套版；尚未单独验证能否换回系统旧版 |
| libcxx.so | 无同名文件，有 libc++.so | 当前库依赖名已改为 libcxx.so，需要保留配套重命名版本；改用系统 C++ 库需核对 ABI 并修改链接/打包 |

其他 23 个文件都有系统对应文件，可作为复用候选。但“文件存在”不等于“普通 HAP 可直接访问/替换”：namespace 可见性、C++ 依赖名、导出符号及固件兼容性尚需逐项验证。当前工程把这些依赖打包进 HAP 是已有方案的实现选择，不表示每个通用库都只能使用手机提供的版本。本次没有移除或替换任何库。

`libqwenvl_engine.so` 由本工程生成，不在 27 个预编译库清单内。

## 完整清单

下表两台 PC 的同名文件存在性相同，路径列列出 Pro S 的第一个核对到的位置。系统 C++ 库在两台都可见 `/system/lib64/libc++.so`；DMA 辅助库和日志编码库位于 chipset SDK 目录。

| 文件 | PC 有同名文件 | Pro S 系统路径 |
| --- | --- | --- |
| libai_drv_device.so | 有 | /vendor/lib64/chipsetsdk/libai_drv_device.so |
| libai_drv_devmm.so | 有 | /vendor/lib64/chipsetsdk/libai_drv_devmm.so |
| libai_drv_dlog.so | 有 | /vendor/lib64/chipsetsdk/libai_drv_dlog.so |
| libai_drv_profiling.so | 有 | /vendor/lib64/chipsetsdk/libai_drv_profiling.so |
| libai_drv_syslog.so | 有 | /vendor/lib64/chipsetsdk/libai_drv_syslog.so |
| libai_infra_log.so | 有 | /vendor/lib64/chipsetsdk/libai_infra_log.so |
| libai_om_event_manager.so | 有 | /vendor/lib64/chipsetsdk/libai_om_event_manager.so |
| libai_om_trace_engine.so | 有 | /vendor/lib64/chipsetsdk/libai_om_trace_engine.so |
| libai_runtime.so | 有 | /vendor/lib64/chipsetsdk/libai_runtime.so |
| libbegetutil.z.so | 有 | /system/lib64/platformsdk/libbegetutil.z.so |
| libcjson.z.so | 有 | /system/lib64/platformsdk/libcjson.z.so |
| libclang_rt.ubsan_minimal.so | 有 | /system/lib64/platformsdk/libclang_rt.ubsan_minimal.so |
| libconfigpolicy_util.z.so | 有 | /system/lib64/platformsdk/libconfigpolicy_util.z.so |
| libcxx.so | 无 | — |
| libdmabufheap.z.so | 有 | /system/lib64/chipset-sdk/libdmabufheap.z.so |
| libgewurt_base.so | 有 | /vendor/lib64/passthrough/indirect/libgewurt_base.so |
| libgewurt_kernel.so | 有 | /vendor/lib64/passthrough/indirect/libgewurt_kernel.so |
| libhilog.so | 有 | /system/lib64/platformsdk/libhilog.so |
| libhilog_encode.so | 有 | /system/lib64/chipset-sdk-sp/libhilog_encode.so |
| libhilog_inner.so | 有 | /system/lib64/libhilog_inner.so |
| libhitrace_meter.so | 有 | /system/lib64/platformsdk/libhitrace_meter.so |
| libhitracechain.so | 有 | /system/lib64/platformsdk/libhitracechain.so |
| libnpu_slog.so | 有 | /vendor/lib64/chipsetsdk/libnpu_slog.so |
| libqwen2vl_sdk.so | 无 | — |
| libsandboxlog.so | 有 | /system/lib64/platformsdk/libsandboxlog.so |
| libsec_shared.z.so | 有 | /system/lib64/platformsdk/libsec_shared.z.so |
| libsystemparam.z.so | 有 | /system/lib64/platformsdk/libsystemparam.z.so |
