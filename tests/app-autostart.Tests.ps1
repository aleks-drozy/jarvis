# tests/app-autostart.Tests.ps1 - structural pins for the optional logon task.
# The launcher must be arg-driven (no personal path baked into a tracked file), silent
# (window style 0), and the register script must refuse to register a launcher that
# cannot actually start (no electron installed).
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$vbs  = Get-Content (Join-Path $repo 'skill\bin\app-hidden.vbs') -Raw
$reg  = Get-Content (Join-Path $repo 'scripts\register-app-autostart.ps1') -Raw

Assert ($vbs -match 'WScript\.Arguments\.Count\s*<\s*1')  "launcher must refuse to run without the app-dir argument"
Assert ($vbs -match ',\s*0\s*,\s*False')                  "launcher must use window style 0 (no console flash)"
Assert ($vbs -notmatch 'Users')                           "launcher must carry no absolute personal path"
Assert ($reg -match '-AtLogOn')                           "task must be logon-triggered, not time-triggered"
Assert ($reg -match "node_modules\\electron")              "register script must verify electron exists before registering"
Assert ($reg -match 'IgnoreNew')                          "task must not stack instances (app also holds its own lock)"
Write-Host "app-autostart: ALL PASS"
