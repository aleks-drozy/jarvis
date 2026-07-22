# scripts/register-opportunity-sweep.ps1 - registers the hourly opportunity sweep.
#
# Hourly, not every 3 minutes: an assessment deadline moves in days, so an hour is ample, and the
# Telegram poller's job is responsiveness to Alex rather than polling the world 480 times a day.
#
# Runs the INSTALLED skill copy (config skill_dir), not the repo checkout - the repo may sit on a
# work-in-progress branch. Run install.ps1 first.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
$cfg = Get-JarvisConfig
$vbs = Join-Path $cfg.skill_dir 'bin\opportunity-sweep-hidden.vbs'
if (-not (Test-Path $vbs)) { throw "no installed launcher at $vbs - run install.ps1 first" }
$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B `"$vbs`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
  -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Jarvis Opportunity Sweep' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Hourly check for assessment/interview invites; pushes to Telegram and reminds daily until cleared' -Force
Write-Host "Registered 'Jarvis Opportunity Sweep' (hourly while logged on), running the installed skill copy."
