# scripts/register-staging.ps1 - registers/unregisters the Night Shift overnight staging task.
#
# Opt-in via config (unlike the other four register-* tasks, which are opt-in by simply being run):
# Night Shift also GATES on config.staging_enabled (~/.jarvis/config.json), because it is the one task
# in this family that autonomously writes local files overnight rather than only reading/pushing. This
# script is therefore safe to re-run any time (e.g. from a scheduled maintenance pass): it registers
# the task when staging_enabled is true and removes it again when the config later flips back off,
# so a disabled Night Shift never keeps firing from a stale scheduled-task registration.
#
# Runs the INSTALLED skill copy (config skill_dir), not the repo checkout - the repo may sit on a
# work-in-progress branch. Run install.ps1 first.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
$cfg = Get-JarvisConfig
$taskName = 'Jarvis Night Shift'

if (-not $cfg.staging_enabled) {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "'$taskName' is disabled (config.staging_enabled: false) - removed the existing scheduled task."
  } else {
    Write-Host "'$taskName' is disabled (config.staging_enabled: false) - nothing to register. Set staging_enabled: true in config.json and re-run this script to enable it."
  }
  exit 0
}

$wrapper = Join-Path $cfg.skill_dir 'bin\stage-prep.ps1'
if (-not (Test-Path $wrapper)) { throw "no installed skill at $wrapper - run install.ps1 first" }

$hour = [int]$cfg.staging_hour
if ($hour -lt 0 -or $hour -gt 23) { throw "config.staging_hour must be 0-23, got $($cfg.staging_hour)" }
$at = (Get-Date).Date.AddHours($hour).AddMinutes(30)   # e.g. staging_hour 3 -> 03:30 local

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -File `"$wrapper`""
$trigger = New-ScheduledTaskTrigger -Daily -At $at
# -AllowStartIfOnBatteries / -DontStopIfGoingOnBatteries: match the other unattended tasks (register-
# task.ps1, register-opportunity-sweep.ps1) rather than silently skip on an unplugged laptop.
# No -WakeToRun: unlike the 08:30 debrief, a missed overnight run because the machine was asleep is not
# alarm-worthy (spec: "a missed prep sheet is not alarm-worthy - restraint applies here too") - it
# simply stays quiet and the next qualifying trigger stages normally another night.
# -ExecutionTimeLimit 20 min: one trigger's headless generation (Invoke-ClaudeGeneration's own default
# -TimeoutSec 900 = 15 min) plus the collector reads around it; generous but bounded, matching the
# reasoning in register-task.ps1's own F4 comment.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Night Shift: stages tomorrow/next-48h interview/assessment/deadline prep sheets overnight (career triggers only, local-only, read-only calendar)' -Force
Write-Host "Registered '$taskName' at $($at.ToString('HH:mm')) (machine-local, staging_hour=$hour), running the installed skill copy."
