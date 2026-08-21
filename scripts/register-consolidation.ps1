# scripts/register-consolidation.ps1 - registers/unregisters the weekly memory-consolidation task.
#
# Opt-in via config (mirrors register-staging.ps1's own pattern): consolidation autonomously REWRITES
# a vault file (PATTERNS.md) rather than only reading/pushing, so it gates on config.consolidation_enabled
# the same way Night Shift gates on staging_enabled. Safe to re-run any time: registers the task when
# consolidation_enabled is true and removes it again when the config later flips back off.
#
# Runs the INSTALLED skill copy (config skill_dir), not the repo checkout - the repo may sit on a
# work-in-progress branch. Run install.ps1 first.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
$cfg = Get-JarvisConfig
$taskName = 'Jarvis Memory Consolidation'

if (-not $cfg.consolidation_enabled) {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "'$taskName' is disabled (config.consolidation_enabled: false) - removed the existing scheduled task."
  } else {
    Write-Host "'$taskName' is disabled (config.consolidation_enabled: false) - nothing to register. Set consolidation_enabled: true in config.json and re-run this script to enable it."
  }
  exit 0
}

$wrapper = Join-Path $cfg.skill_dir 'bin\consolidate-memory.ps1'
if (-not (Test-Path $wrapper)) { throw "no installed skill at $wrapper - run install.ps1 first" }

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -File `"$wrapper`""
# Sunday ~21:00 (spec) - after the Sunday debrief has already run and captured the week's own notes,
# so the trailing-week debrief window this pass reads includes today's own Sunday retrospective note.
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 9:00pm
# No -WakeToRun: a missed weekly consolidation is not alarm-worthy - it simply runs the following
# Sunday instead (same restraint reasoning register-staging.ps1 documents for Night Shift).
# -ExecutionTimeLimit 20 min: one Invoke-ClaudeGeneration call (default -TimeoutSec 900 = 15 min) plus
# the deterministic pre-pass and evidence-corpus collection around it.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Weekly semantic-memory consolidation: rewrites PATTERNS.md from the trailing week of debriefs + a suggestion-outcomes ledger (episodic debriefs/ stays read-only)' -Force
Write-Host "Registered '$taskName' at 21:00 Sundays (machine-local), running the installed skill copy."
