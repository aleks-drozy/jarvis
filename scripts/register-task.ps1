# scripts/register-task.ps1 - registers/updates the daily 08:30 Jarvis debrief.
# "only when logged on" + StartWhenAvailable => catches up a missed run at next logon AND toasts work.
# The task runs the INSTALLED skill copy (config skill_dir), not the repo checkout: the repo may sit on
# any work-in-progress branch, and the 08:30 run must never execute half-finished code. Run install.ps1
# before this to deploy the current code.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
$cfg = Get-JarvisConfig
$wrapper = Join-Path $cfg.skill_dir 'bin\jarvis-debrief.ps1'
if (-not (Test-Path $wrapper)) { throw "no installed skill at $wrapper - run install.ps1 first" }
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -File `"$wrapper`""
$trigger = New-ScheduledTaskTrigger -Daily -At 8:30am
# -AllowStartIfOnBatteries: without it Windows defaults to DisallowStartIfOnBatteries and the
# catch-up run is silently skipped on an unplugged laptop (learned the hard way, 2026-07-10)
# -WakeToRun: wake the laptop from sleep at 08:30 so the briefing lands ON TIME instead of at next
# logon (added 2026-07-12; the task ran hours late every day because it is logged-on-only and the
# machine was asleep at 08:30). REQUIRES power-plan wake timers enabled on AC *and* DC:
#   powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
#   powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 ; powercfg /setactive SCHEME_CURRENT
# Works from sleep, NOT a full shutdown; StartWhenAvailable stays as the catch-up fallback.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName 'Jarvis Morning Debrief' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Generates and delivers the morning debrief (Telegram/email per CONFIG debrief_delivery)' -Force
Write-Host "Registered 'Jarvis Morning Debrief' at 08:30 (machine-local), running the installed skill copy."
