param(
  [string]$Output = (Join-Path (Split-Path $PSScriptRoot -Parent) 'libs/agenui.har')
)
$ErrorActionPreference = 'Stop'
$expected = '1d879a003abba4bc715a2d09026204274dd1ad984f8c305c1de67d20001ab4bc'
$url = 'https://github.com/AGenUI/AGenUI/releases/download/AGenUI-1.2.0.beta1/AGenUI-1.2.0-harmony.har'
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) {
  if ((Test-Path -LiteralPath $Output -PathType Leaf) -and
      (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected) {
    Write-Output "AGenUI already verified: $Output"
    return
  }
  throw "Existing output differs from the pinned HAR: $Output. Use a new -Output path or set AGENUI_HAR to your intended HAR."
}
$parent = Split-Path $Output -Parent
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temp = Join-Path $parent ('agenui-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
  Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec 180
  $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) { throw "AGenUI SHA256 mismatch: expected $expected, got $actual" }
  Move-Item -LiteralPath $temp -Destination $Output
  Write-Output "AGenUI downloaded and verified: $Output"
} finally {
  if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp }
}
