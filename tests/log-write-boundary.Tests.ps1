# tests/log-write-boundary.Tests.ps1 - static guard for the F1 fix: the Claude subagent invoked by
# jarvis-debrief.ps1 must never be told (or allowed) to write run-status log lines itself. A prior
# regression had the agent forging its own "run ok (..., headless)" lines into the SAME file the
# wrapper script used for its real status, because debrief.md told it to read the tail but not that
# it must never write to it. This asserts the explicit "never write" prohibition text survives in
# both skill/references/debrief.md and skill/SKILL.md, so it cannot be quietly removed later.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$debriefMd = Join-Path $repo 'skill\references\debrief.md'
$skillMd   = Join-Path $repo 'skill\SKILL.md'

Assert (Test-Path $debriefMd) "skill/references/debrief.md must exist"
Assert (Test-Path $skillMd)   "skill/SKILL.md must exist"

$debriefText = Get-Content $debriefMd -Raw
$skillText   = Get-Content $skillMd -Raw

$prohibition = 'Writing a run-ok or run-FAILED line yourself is fabricating a health status'

Assert ($debriefText -match [regex]::Escape($prohibition)) `
  "debrief.md must contain the explicit 'never write a run-status line' prohibition"
Assert ($skillText -match [regex]::Escape($prohibition)) `
  "SKILL.md Safety section must contain the explicit 'never write a run-status line' prohibition"

# Both files must point the agent at the new read-only channel name, and both must still name the
# legacy file so a stranger reading the docs understands why .jarvis.log shows up in old commits.
Assert ($debriefText -match '\.jarvis-runs\.log') "debrief.md must reference .jarvis-runs.log (the read-only channel)"
Assert ($skillText -match '\.jarvis-runs\.log')   "SKILL.md must reference .jarvis-runs.log (the read-only channel)"
Assert ($debriefText -match '\.jarvis\.log')      "debrief.md must still name the legacy .jarvis.log as unused"
Assert ($skillText -match '\.jarvis\.log')        "SKILL.md must still name the legacy .jarvis.log as unused"

# The wrapper script itself must have moved off the old shared file for its own writes.
$debriefPs1 = Get-Content (Join-Path $repo 'skill\bin\jarvis-debrief.ps1') -Raw
Assert ($debriefPs1 -match '\.jarvis-runs\.log') "jarvis-debrief.ps1 must write to .jarvis-runs.log"
Assert (-not ($debriefPs1 -match 'Join-Path \$vault "debriefs\\\.jarvis\.log"')) `
  "jarvis-debrief.ps1 must no longer target the old shared .jarvis.log file for its own log writes"

Write-Host "log-write-boundary: ALL PASS"
