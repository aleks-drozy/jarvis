# tests/livestate.Tests.ps1 - runs the node assertions for app/lib/livestate.js
$ErrorActionPreference = 'Stop'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Error 'FAIL: node not found (app tests need Node)'; exit 1 }
node "$PSScriptRoot\livestate.node.js"
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "livestate: ALL PASS"
