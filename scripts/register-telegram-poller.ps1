# scripts/register-telegram-poller.ps1 - registers a scheduled task that polls Telegram every 3 minutes
# for /debrief and /status (the two-way remote). Runs telegram-bot.ps1 -Once: one long-poll (~30s) then
# EXITS - no persistent process, no RAM held between checks. Single-instance (IgnoreNew) so a /debrief
# generation (which can take a minute) can't stack. Logged-on only, like the 08:30 debrief task.
$ErrorActionPreference = 'Stop'
$bot = 'C:\Users\Alex\Projects\jarvis\skill\bin\telegram-bot.ps1'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -File `"$bot`" -Once"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Jarvis Telegram Poller' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Polls Telegram every 3 min for /debrief and /status (two-way remote)' -Force
Write-Host "Registered 'Jarvis Telegram Poller' (every 3 min while logged on)."
