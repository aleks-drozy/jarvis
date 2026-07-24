# scripts/register-app-autostart.ps1 - registers the desktop app as a logon-triggered task,
# closing the "launched by hand" gap. Opt-in by running this script, exactly like the other
# register-* scripts: no config toggle, nothing on by default.
#
# At logon, not at a time: the app is a tray companion for a logged-in human, unlike the three
# unattended tasks. The app's own single-instance lock (app/main.js) makes a double launch a no-op.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
$cfg = Get-JarvisConfig
if (-not $cfg.app_dir) { throw "config.app_dir is empty - re-run install.ps1 first" }
if (-not (Test-Path (Join-Path $cfg.app_dir 'node_modules\electron'))) {
  throw "no electron in $($cfg.app_dir)\node_modules - run 'npm install' in the app directory first"
}
$vbs = Join-Path $cfg.skill_dir 'bin\app-hidden.vbs'
if (-not (Test-Path $vbs)) { throw "no installed launcher at $vbs - run install.ps1 first" }
$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B `"$vbs`" `"$($cfg.app_dir)`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Jarvis Desktop App' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Launches the Jarvis tray companion at logon (single-instance; safe to also run by hand)' -Force
Write-Host "Registered 'Jarvis Desktop App' (at logon), launching $($cfg.app_dir) via the installed skill copy."
