<#
  Configure in-process VL access via an existing root HDC connection.
  Start saves the current SELinux mode/driver ownership, sets Permissive and
  grants only the installed app UID. Stop restores the saved state.
  This starts no inference service and installs no boot-time policy.
#>
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._:-]+$')][string]$Device,
  [ValidateSet('Start', 'Status', 'Stop')][string]$Action = 'Status',
  [string]$SdkRoot = 'D:\command-line-tools\sdk\default\openharmony',
  [switch]$RestartApp
)
$ErrorActionPreference = 'Stop'
$hdcPath = Join-Path $SdkRoot 'toolchains\hdc.exe'
$scriptPath = Join-Path $PSScriptRoot 'vl-app-access.sh'
$remote = '/data/local/tmp/minipc-vl-app-access'
$remoteScript = "$remote/access-$([Guid]::NewGuid().ToString('N')).sh"
function Invoke-Device([string]$Command) {
  $lines = @(& $hdcPath -t $Device shell "$Command`necho VL_ACCESS_EXIT:`$?" 2>&1)
  $output = $lines -join "`n"
  if ($LASTEXITCODE -ne 0 -or $output -notmatch 'VL_ACCESS_EXIT:0\s*$') { throw "Device command failed: $output" }
  return ($output -replace '\s*VL_ACCESS_EXIT:0\s*$', '').Trim()
}
if (-not (Test-Path -LiteralPath $hdcPath -PathType Leaf)) { throw "Missing HDC: $hdcPath" }
if ((Invoke-Device 'id -u') -ne '0') { throw 'An existing root HDC session is required.' }
Invoke-Device "test ! -L $remote && if test -e $remote; then test -d $remote && test `"`$(stat -c %u $remote)`" = 0; else mkdir -m 700 $remote; fi" | Out-Null
& $hdcPath -t $Device file send $scriptPath $remoteScript
if ($LASTEXITCODE -ne 0) { throw 'Access script upload failed.' }
Invoke-Device "chmod 700 $remoteScript && sh -n $remoteScript" | Out-Null
if ($RestartApp) {
  if ($Action -eq 'Status') { throw '-RestartApp is only valid with Start or Stop.' }
  Invoke-Device 'aa force-stop com.jiuwen.registrychatui' | Out-Null
}
try { Write-Output (Invoke-Device "sh $remoteScript $($Action.ToLowerInvariant())") }
finally {
  if ($RestartApp) { Write-Output (Invoke-Device 'aa start -a EntryAbility -b com.jiuwen.registrychatui') }
}
