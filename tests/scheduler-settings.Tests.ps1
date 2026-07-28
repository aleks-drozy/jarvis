# tests/scheduler-settings.Tests.ps1 - F4: scripts/register-task.ps1's ExecutionTimeLimit and
# app/lib/livestate.js's RUN_LIMIT_MS are two independently hardcoded copies of the same fact (how
# long a run is allowed to take before it is forcibly killed / considered stalled). Nothing else
# ties them together, so this asserts they agree - it must FAIL the moment someone changes one
# without the other.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$registerPath  = Join-Path $repo 'scripts\register-task.ps1'
$livestatePath = Join-Path $repo 'app\lib\livestate.js'

Assert (Test-Path $registerPath)  "scripts/register-task.ps1 must exist"
Assert (Test-Path $livestatePath) "app/lib/livestate.js must exist"

$registerText  = Get-Content $registerPath -Raw
$livestateText = Get-Content $livestatePath -Raw

$m1 = [regex]::Match($registerText, 'ExecutionTimeLimit\s*\(New-TimeSpan\s+-Minutes\s+(\d+)\)')
Assert $m1.Success "could not find 'ExecutionTimeLimit (New-TimeSpan -Minutes N)' in register-task.ps1"
$registerMinutes = [int]$m1.Groups[1].Value

$m2 = [regex]::Match($livestateText, 'RUN_LIMIT_MS\s*=\s*(\d+)\s*\*\s*60\s*\*\s*1000')
Assert $m2.Success "could not find 'RUN_LIMIT_MS = N * 60 * 1000' in livestate.js"
$livestateMinutes = [int]$m2.Groups[1].Value

Assert ($registerMinutes * 60000 -eq $livestateMinutes * 60000) `
  "ExecutionTimeLimit ($registerMinutes min, register-task.ps1) must equal RUN_LIMIT_MS ($livestateMinutes min, livestate.js) - they are two hardcoded copies of the same fact and must be changed together"

# Sanity: pin the currently-intended value so a future F4-style bump is a deliberate, visible edit
# to this test rather than a silent pass at some other number.
Assert ($registerMinutes -eq 30) "expected register-task.ps1 ExecutionTimeLimit to be 30 minutes (got $registerMinutes) - update this test deliberately if that changes"

# Pre-merge review of 6e2a148: jarvis-debrief.ps1's own single-flight lock has a THIRD independently
# hardcoded copy of this same fact (how long a run may legitimately still be in flight) - its
# staleness window, used to decide whether an existing debrief.lock is stale (owner dead or window
# expired) or still guards a genuinely running process. This was found still hardcoded at the OLD
# 15-minute figure even after this same commit raised the other two to 30 min - meaning a
# legitimately still-running (and healthy) generation between minute 15 and 30 would have its lock
# treated as stale and stolen by an on-demand /debrief, starting a second concurrent generation and
# delivery. Must move together with the other two.
$debriefPath = Join-Path $repo 'skill\bin\jarvis-debrief.ps1'
Assert (Test-Path $debriefPath) "skill/bin/jarvis-debrief.ps1 must exist"
$debriefText = Get-Content $debriefPath -Raw

$m3 = [regex]::Match($debriefText, '\$isFresh = \(\[datetime\]\$held\.start -gt \(Get-Date\)\.AddMinutes\(-(\d+)\)\)')
Assert $m3.Success "could not find the single-flight lock's staleness window (AddMinutes(-N)) in jarvis-debrief.ps1"
$lockStaleMinutes = [int]$m3.Groups[1].Value

Assert ($lockStaleMinutes -eq $registerMinutes) `
  "the single-flight lock's staleness window ($lockStaleMinutes min, jarvis-debrief.ps1) must equal ExecutionTimeLimit ($registerMinutes min, register-task.ps1) - a lock that goes stale BEFORE a legitimately still-running generation would let a second run steal it out from under an in-flight, healthy process"

Write-Host "scheduler-settings: ALL PASS"
