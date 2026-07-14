# tests/scheduler-status.Tests.ps1 - read-only Task Scheduler status collector
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }
$script = "$PSScriptRoot\..\skill\bin\scheduler-status.ps1"
Assert (Test-Path $script) "scheduler-status.ps1 must exist"

# Degradation: a missing task must still yield structured JSON + exit 0 (module isolation).
$raw = powershell -NoProfile -File $script -TaskName 'Definitely-No-Such-Task-XYZ'
Assert ($LASTEXITCODE -eq 0) "missing task must exit 0"
$j = ($raw -join "`n") | ConvertFrom-Json
Assert ($j.registered -eq $false) "missing task -> registered false"
Assert ($j.enabled -eq $false) "missing task -> enabled false"

# Dot-source: Get-SchedulerStatus returns a bool 'registered' for the real task name (present or not).
. $script -DotSourceOnly
$r = Get-SchedulerStatus -TaskName 'Jarvis Morning Debrief'
Assert ($r.registered -is [bool]) "registered must be a bool"

# ASCII purity (repo battle scar)
$bytes = [IO.File]::ReadAllBytes($script)
$bad = 0; for ($i=0; $i -lt $bytes.Length; $i++){ if ($bytes[$i] -gt 127){ $bad++ } }
Assert ($bad -eq 0) "scheduler-status.ps1 must be pure ASCII (found $bad)"

Write-Host "scheduler-status: ALL PASS"
