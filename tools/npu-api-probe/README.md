# NPU 公开接口诊断

`main.c` 是独立的 HarmonyOS 原生诊断程序，用于区分“不能直接打开驱动”与“系统没有 NPU 推理接口”。不加载业务模型，不改变节点权限、系统参数或 SELinux 模式。

进程在调用运行时前切换到指定应用 UID，补充组仅保留本工程使用的 1097/3099，并清空 Linux capabilities。**由 HDC 启动时，安全域和 AccessToken 仍不等同于 HAP。** 输出成功不能作为应用内推理成功的证明。

## 编译与运行

在项目根目录执行（独立程序，不编译 HAP）：

```powershell
$nativeRoot = 'D:\command-line-tools\sdk\default\openharmony\native'
New-Item -ItemType Directory -Path .hvigor/vl-probe -Force | Out-Null
& "$nativeRoot\llvm\bin\clang.exe" --target=aarch64-linux-ohos "--sysroot=$nativeRoot/sysroot" -std=gnu11 -D_GNU_SOURCE -Wno-deprecated-declarations tools/npu-api-probe/main.c -ldl -o .hvigor/vl-probe/npu-public-api-probe
$hdcPath = 'D:\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
& $hdcPath -t 7QB0126509000160 file send "$PWD\.hvigor\vl-probe\npu-public-api-probe" /data/local/tmp/minipc-npu-public-api-probe
& $hdcPath -t 7QB0126509000160 shell 'chmod 755 /data/local/tmp/minipc-npu-public-api-probe; /data/local/tmp/minipc-npu-public-api-probe 20020176 --add'
```

UID 应以实际应用缓存目录属主为准。无 `--add` 时仅检查接口与枚举设备；带 `--add` 时显式选择各 NNRT 后端，构建单算子图并检查 `[1,2]+[3,4]=[4,6]`。至少一个后端计算正确才以 0 退出；25 秒进程闹钟限制诊断运行时间。使用兼容的 NNRT v9 接口以覆盖现有固件，不代表新业务应优先使用这些已弃用接口。

## 本次实测与限制

Pro S 上两个驱动节点均返回 EACCES；NNRT 成功枚举 `HIAI_F` 和 `NPU_ohos.boot.hardware.KirinXE90_v2_0`。前者编译此测试图返回 2（INVALID_PARAMETER，具体原因未定位）；后者编译、执行均返回 0，结果为 `4、6`。

当前设备 `libhiai_foundation.so` 中未找到本机 `CANNKit/llm_engine.h` 声明的五个被检查的 `HMS_LLMEngine*` 函数。本结论仅针对当前库、已检查的符号，不表示整个平台不支持 CANN 或 LLM。

首次诊断完成枚举后，在进程整体退出阶段发生 SIGSEGV。当前诊断对创建的模型/编译器/执行器显式释放，随后使用 `_exit` 跳过第三方库的进程静态清理；这一处理不等于完成运行时生命周期验证。正常 HAP 内的权限、库加载和生命周期仍需单独验证。

调查结论见 [应用 NPU 接入调查](../../docs/npu-app-access-investigation-2026-10-16.md)。
