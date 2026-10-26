<#
  HDC-started private inference worker for the compute HAP.
  Does not install a HAP or alter device nodes/SELinux. Requires an existing
  root HDC session; the worker drops to the compute application's UID.
  Usage: .\scripts\vl-worker.ps1 -Device 7QB0126509000160 -Action Start
  Use -Action Status / Stop, or Start -Restart after rebuilding the HAP.
  Keep this script ASCII-only for Windows PowerShell 5.1.
#>
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._:-]+$')][string]$Device,
  [ValidateSet('Start', 'Status', 'Stop')][string]$Action = 'Status',
  [string]$SdkRoot = 'D:\command-line-tools\sdk\default\openharmony',
  [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Model = 'Qwen-2.5-vl-3B-instruct-Q4_N_0_G128',
  [switch]$Restart
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$hdcPath = Join-Path $SdkRoot 'toolchains\hdc.exe'
$nativeRoot = Join-Path $SdkRoot 'native'
$cppDir = Join-Path $repoRoot 'apps\compute-node\entry\src\main\cpp'
$libDir = Join-Path $cppDir 'libs\arm64-v8a'
$buildDir = Join-Path $repoRoot '.hvigor\vl-worker'
$cachePath = '/data/app/el2/100/base/com.jiuwen.registrychatui/cache'
$deviceLib = '/data/app/el1/bundle/public/com.jiuwen.registrychatui/libs/arm64'
$modelPath = "/data/app/el2/100/base/com.jiuwen.registrychatui/files/models/$Model"
$libraryEnv = "LD_LIBRARY_PATH=${deviceLib}:/vendor/lib64/passthrough/indirect:/system/lib64:/system/lib64/platformsdk"
# Serial identifiers can contain ':' on TCP connections; never use them as paths.
$stateKey = $Device -replace '[^A-Za-z0-9._-]', '_'
$statePath = Join-Path $buildDir "$stateKey.json"

function Invoke-Device([string]$Command) {
  $lines = @(& $hdcPath -t $Device shell "$Command`necho VL_SCRIPT_EXIT:`$?" 2>&1)
  $output = $lines -join "`n"
  if ($LASTEXITCODE -ne 0 -or $output -notmatch 'VL_SCRIPT_EXIT:0\s*$') {
    throw "Device command failed: $output"
  }
  return ($output -replace '\s*VL_SCRIPT_EXIT:0\s*$', '').Trim()
}

function Invoke-Worker([string]$Mode, [object]$State) {
  if ($State.remote -notmatch '^/data/local/tmp/minipc-vl-worker-[a-f0-9]{32}$' -or
      [string]$State.uid -notmatch '^2[0-9]{7}$') { throw 'Invalid local worker state.' }
  $command = "$libraryEnv $($State.remote)/vl-worker $Mode $($State.uid) $cachePath"
  if ($Mode -eq 'status') { $command += ' || test $? -eq 6' }
  return Invoke-Device $command
}

if (-not (Test-Path -LiteralPath $hdcPath -PathType Leaf)) { throw "Missing HDC: $hdcPath" }
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if ($state.remote -notmatch '^/data/local/tmp/minipc-vl-worker-[a-f0-9]{32}$' -or
      [string]$state.uid -notmatch '^2[0-9]{7}$' -or [string]$state.pid -notmatch '^[1-9][0-9]*$') {
    throw 'Invalid local worker state.'
  }
}
if ($Action -eq 'Status') {
  if ($null -eq $state) { Write-Output 'No worker deployed from this checkout.'; return }
  # Native status returns 6 for a stopped worker; keep that an ordinary status.
  Write-Output (Invoke-Worker 'status' $state)
  return
}
if ($Action -eq 'Stop' -or ($Action -eq 'Start' -and $Restart)) {
  if ($null -ne $state) {
    Write-Output (Invoke-Worker 'stop' $state)
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
      $alive = Invoke-Device "if test -e /proc/$($state.pid)/exe; then readlink /proc/$($state.pid)/exe; fi"
      if ($alive -ne "$($state.remote)/vl-worker") { break }
      if ([DateTime]::UtcNow -ge $deadline) { throw 'Worker is still stopping; retry after the active request finishes.' }
      Start-Sleep -Milliseconds 250
    } while ($true)
  }
  if ($Action -eq 'Stop') { return }
} elseif ($Action -eq 'Start' -and $null -ne $state) {
  $alive = Invoke-Device "if test -e /proc/$($state.pid)/exe; then readlink /proc/$($state.pid)/exe; fi"
  if ($alive -eq "$($state.remote)/vl-worker") { Write-Output 'Worker already running. Use -Restart to replace it.'; return }
}

if ((Invoke-Device 'id -u') -ne '0') { throw 'This diagnostic launcher needs an existing root HDC session.' }
$appUid = Invoke-Device "stat -c %u $cachePath"
if ($appUid -notmatch '^2[0-9]{7}$') { throw 'Compute application cache/UID unavailable. Open the installed compute HAP first.' }
Invoke-Device "test -s $modelPath/vl_params && test -s $modelPath/tokenizer.json" | Out-Null
# Protect against accidentally mixing the installed SDK and local private libraries.
$hashes = Invoke-Device "sha256sum $deviceLib/*.so"
foreach ($name in @('libqwen2vl_sdk.so', 'libcxx.so', 'libgewurt_kernel.so', 'libgewurt_base.so', 'libai_runtime.so')) {
  $localHash = (Get-FileHash -LiteralPath (Join-Path $libDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hashes -notmatch "(?m)^$localHash\s+$([regex]::Escape($deviceLib + '/' + $name))\s*$") {
    throw "Installed/local library mismatch: $name. Build/install with matching private libraries first."
  }
}
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$binary = Join-Path $buildDir 'vl-worker'
$compiler = Join-Path $nativeRoot 'llvm\bin\clang++.exe'
$arguments = @('--target=aarch64-linux-ohos', "--sysroot=$nativeRoot/sysroot", '-std=c++17', '-O2',
  '-static-libstdc++', '-ffunction-sections', '-fdata-sections', "-I$cppDir",
  "$cppDir/vl_worker.cpp", "$cppDir/vl_worker_client.cpp", '-Wl,--gc-sections', '-Wl,--no-as-needed',
  "$libDir/libqwen2vl_sdk.so", "$libDir/libcjson.z.so", "$libDir/libcxx.so",
  "$libDir/libgewurt_kernel.so", "$libDir/libgewurt_base.so", "-L$libDir", "-Wl,-rpath-link,$libDir",
  '-lai_runtime', '-lhilog', '-lhilog_ndk.z', '-o', $binary)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Native worker compilation failed.' }
$remote = '/data/local/tmp/minipc-vl-worker-' + [Guid]::NewGuid().ToString('N')
Invoke-Device "mkdir -m 700 $remote" | Out-Null
& $hdcPath -t $Device file send $binary "$remote/vl-worker"
if ($LASTEXITCODE -ne 0) { throw 'Worker upload failed.' }
Invoke-Device "chmod 755 $remote/vl-worker && test -x $remote/vl-worker" | Out-Null
Invoke-Device "$libraryEnv nohup $remote/vl-worker serve $appUid $cachePath $modelPath > $remote/bootstrap.log 2>&1 < /dev/null &" | Out-Null
$state = [pscustomobject]@{ remote = $remote; uid = $appUid; pid = 0; device = $Device; model = $Model }
for ($attempt = 0; $attempt -lt 40; $attempt++) {
  $status = Invoke-Device "$libraryEnv $remote/vl-worker status $appUid $cachePath || test `$? -eq 6"
  if ($status -match 'READY pid=(\d+)') {
    $state.pid = [int]$Matches[1]
    $running = Invoke-Device "readlink /proc/$($state.pid)/exe"
    if ($running -ne "$remote/vl-worker") { throw 'Another worker is running; stop it before starting this build.' }
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Output $status
    Write-Output 'Ready. Install the updated compute HAP bridge to use this worker. Restart after HAP installation/device reboot.'
    return
  }
  Start-Sleep -Milliseconds 250
}
throw "Worker did not start. Inspect $remote/bootstrap.log on the device."
