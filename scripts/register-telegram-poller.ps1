# scripts/register-telegram-poller.ps1 - registers a scheduled task that polls Telegram every 3 minutes
# for /debrief, /status and note capture (the two-way remote). Runs telegram-bot.ps1 -Once: one long-poll
# (~30s) then EXITS - no persistent process, no RAM held between checks. Single-instance (IgnoreNew) so a
# /debrief generation (which can take a minute) can't stack. Logged-on only, like the 08:30 debrief task.
#
# Launched via wscript + telegram-bot-hidden.vbs, NOT powershell.exe directly: Task Scheduler briefly
# FLASHES a console window every time it starts powershell.exe, even with -WindowStyle Hidden. At a 3-min
# interval that is a window blinking at you all day. WScript.Shell.Run with window style 0 avoids it.
# (Learned in the wild 2026-07-15 - the first version of this script used powershell.exe and flashed.)
#
# The task runs the INSTALLED skill copy (config skill_dir), not the repo checkout - the repo may sit on
# a work-in-progress branch. The vbs self-locates its sibling telegram-bot.ps1. Run install.ps1 first.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
$cfg = Get-JarvisConfig
$vbs = Join-Path $cfg.skill_dir 'bin\telegram-bot-hidden.vbs'
if (-not (Test-Path $vbs)) { throw "no installed launcher at $vbs - run install.ps1 first" }
$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B `"$vbs`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Jarvis Telegram Poller' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Polls Telegram every 3 min for /debrief, /status and note capture (two-way remote)' -Force
Write-Host "Registered 'Jarvis Telegram Poller' (every 3 min while logged on), running the installed skill copy."
