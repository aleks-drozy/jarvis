# scripts/register-telegram-poller.ps1 - registers a scheduled task that polls Telegram every 3 minutes
# for /debrief, /status and note capture (the two-way remote). Runs telegram-bot.ps1 -Once: one long-poll
# (~30s) then EXITS - no persistent process, no RAM held between checks. Single-instance (IgnoreNew) so a
# /debrief generation (which can take a minute) can't stack. Logged-on only, like the 08:30 debrief task.
#
# Launched via wscript + telegram-bot-hidden.vbs, NOT powershell.exe directly: Task Scheduler briefly
# FLASHES a console window every time it starts powershell.exe, even with -WindowStyle Hidden. At a 3-min
# interval that is a window blinking at you all day. WScript.Shell.Run with window style 0 avoids it.
# (Learned in the wild 2026-07-15 - the first version of this script used powershell.exe and flashed.)
$ErrorActionPreference = 'Stop'
$vbs = 'C:\Users\Alex\Projects\jarvis\skill\bin\telegram-bot-hidden.vbs'
if (-not (Test-Path $vbs)) { throw "missing $vbs - it is the hidden launcher the task runs" }
$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B `"$vbs`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Jarvis Telegram Poller' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Polls Telegram every 3 min for /debrief and /status (two-way remote)' -Force
Write-Host "Registered 'Jarvis Telegram Poller' (every 3 min while logged on)."
