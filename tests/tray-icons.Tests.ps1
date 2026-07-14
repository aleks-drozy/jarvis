# tests/tray-icons.Tests.ps1 - generate the tray status icons and verify they exist at base dimensions
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }
function Get-PngSize([string]$p) { $b = [IO.File]::ReadAllBytes($p); $w = ($b[16]*16777216)+($b[17]*65536)+($b[18]*256)+$b[19]; $h = ($b[20]*16777216)+($b[21]*65536)+($b[22]*256)+$b[23]; return @($w,$h) }

$assets = "$PSScriptRoot\..\app\assets"
Assert (Test-Path "$assets\tray.png") "base tray.png must exist"
$baseSize = Get-PngSize "$assets\tray.png"

node "$PSScriptRoot\..\app\scripts\gen-tray-icons.js"
Assert ($LASTEXITCODE -eq 0) "gen-tray-icons.js must run cleanly"

foreach ($n in @('tray-normal','tray-amber','tray-grey','tray-busy')) {
  $p = "$assets\$n.png"
  Assert (Test-Path $p) "$n.png must be generated"
  $sz = Get-PngSize $p
  Assert ($sz[0] -eq $baseSize[0] -and $sz[1] -eq $baseSize[1]) "$n.png must match base dimensions ($($baseSize[0])x$($baseSize[1]))"
}
Write-Host "tray-icons: ALL PASS"
