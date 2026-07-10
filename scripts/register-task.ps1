# scripts/register-task.ps1 — registers/updates the daily 08:30 Jarvis debrief.
# "only when logged on" + StartWhenAvailable => catches up a missed run at next logon AND toasts work.
$ErrorActionPreference = 'Stop'
$wrapper = 'C:\Users\Alex\Projects\jarvis\skill\bin\jarvis-debrief.ps1'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -File `"$wrapper`""
$trigger = New-ScheduledTaskTrigger -Daily -At 8:30am
# -AllowStartIfOnBatteries: without it Windows defaults to DisallowStartIfOnBatteries and the
# catch-up run is silently skipped on an unplugged laptop (learned the hard way, 2026-07-10)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName 'Jarvis Morning Debrief' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Generates and emails Alex the morning debrief' -Force
Write-Host "Registered 'Jarvis Morning Debrief' at 08:30 (machine-local)."
