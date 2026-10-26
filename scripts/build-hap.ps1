param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('agent-client','compute-node','legacy-chat-client','legacy-compute-node','agent-chat','agent-compute','legacy-chat','legacy-compute')]
  [string]$Target,
  [string]$HvigorJs = $env:HVIGOR_JS,
  [string]$AgenuiHar = $env:AGENUI_HAR,
  [switch]$InstallDependencies,
  [switch]$Clean
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$projects = @{
  'agent-client' = 'apps/agent-client'
  'compute-node' = 'apps/compute-node'
  'legacy-chat-client' = 'legacy/chat-client'
  'legacy-compute-node' = 'legacy/compute-node'
  'agent-chat' = 'apps/agent-client'
  'agent-compute' = 'apps/compute-node'
  'legacy-chat' = 'legacy/chat-client'
  'legacy-compute' = 'legacy/compute-node'
}
if (-not $env:DEVECO_SDK_HOME) { throw 'Set DEVECO_SDK_HOME to the installed SDK directory.' }
if (-not $HvigorJs) {
  $cliRoot = Split-Path $env:DEVECO_SDK_HOME -Parent
  $HvigorJs = Join-Path $cliRoot 'hvigor/hvigor/bin/hvigor.js'
}
if (-not (Test-Path -LiteralPath $HvigorJs -PathType Leaf)) { throw 'Set HVIGOR_JS or -HvigorJs to hvigor.js.' }
$project = Join-Path $repoRoot $projects[$Target]
if ($Target -in @('agent-client','agent-chat')) {
  $library = Join-Path $project 'libs/agenui.har'
  if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
    if (-not $AgenuiHar -or -not (Test-Path -LiteralPath $AgenuiHar -PathType Leaf)) {
      throw 'Agent chat needs AGenUI: use apps/agent-client/scripts/fetch-agenui.sh or set AGENUI_HAR / -AgenuiHar to an existing HAR.'
    }
    New-Item -ItemType Directory -Path (Split-Path $library -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $AgenuiHar -Destination $library
  }
}
# The command-line SDK ships the plugin beside hvigor, outside Node's lookup path.
# Local junctions expose the bundled packages without copying SDK files into Git.
$toolingModules = Join-Path $repoRoot '.validation/tooling/node_modules'
$ohosModules = Join-Path $toolingModules '@ohos'
$cliRoot = Split-Path $env:DEVECO_SDK_HOME -Parent
$bundledPlugin = Join-Path $cliRoot 'hvigor/hvigor-ohos-plugin'
$hvigorRuntime = Split-Path (Split-Path $HvigorJs -Parent) -Parent
if (Test-Path -LiteralPath (Join-Path $bundledPlugin 'package.json')) {
  New-Item -ItemType Directory -Path $ohosModules -Force | Out-Null
  $packages = @{'hvigor-ohos-plugin'=$bundledPlugin; 'hvigor'=$hvigorRuntime}
  foreach ($name in $packages.Keys) {
    $alias = Join-Path $ohosModules $name
    if (-not (Test-Path -LiteralPath $alias)) {
      New-Item -ItemType Junction -Path $alias -Target $packages[$name] | Out-Null
    }
  }
}
$previousNodePath = $env:NODE_PATH
$env:NODE_PATH = $toolingModules + $(if ($previousNodePath) { [IO.Path]::PathSeparator + $previousNodePath } else { '' })
Push-Location -LiteralPath $project
try {
  if ($InstallDependencies) {
    & ohpm install --all
    if ($LASTEXITCODE -ne 0) { throw 'ohpm dependency installation failed.' }
  }
  if ($Clean) {
    & node $HvigorJs --mode module -p module=entry@default -p product=default clean --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "SDK clean failed for $Target." }
  }
  & node $HvigorJs --mode module -p module=entry@default -p product=default assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) { throw "SDK build failed for $Target." }
} finally { Pop-Location; $env:NODE_PATH = $previousNodePath }
