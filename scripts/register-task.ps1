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
# F8b: a SECOND, independent daily trigger at 09:15 as a bounded catch-up for the hibernation (S4)
# case above, where the RTC wake timer set for 08:30 is destroyed and StartWhenAvailable has been
# observed (at least once, live) to produce no catch-up attempt at all even though the session was
# clearly live shortly after wake. This trigger shares the task's MultipleInstances=IgnoreNew policy
# (set via -Settings below) and jarvis-debrief.ps1's own F8b heartbeat-based idempotency guard makes
# a 09:15 firing on a day 08:30 already succeeded a safe no-op, never a duplicate send.
$trigger  = New-ScheduledTaskTrigger -Daily -At 8:30am
$trigger2 = New-ScheduledTaskTrigger -Daily -At 9:15am
# -AllowStartIfOnBatteries: without it Windows defaults to DisallowStartIfOnBatteries and the
# catch-up run is silently skipped on an unplugged laptop (learned the hard way, 2026-07-10)
# -WakeToRun: wake the laptop from sleep at 08:30 so the briefing lands ON TIME instead of at next
# logon (added 2026-07-12; the task ran hours late every day because it is logged-on-only and the
# machine was asleep at 08:30). REQUIRES power-plan wake timers enabled on AC *and* DC:
#   powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
#   powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 ; powercfg /setactive SCHEME_CURRENT
# Works from sleep, NOT a full shutdown; StartWhenAvailable stays as the catch-up fallback.
# ...and NOT from hibernation (S4) - a Doze-to-Hibernate transition on battery destroys the RTC wake
# timer; the 09:15 trigger below is the mitigation for that case, not shutdown.
#
# F4: ExecutionTimeLimit raised 15 -> 30 minutes. The Claude generation call inside
# jarvis-debrief.ps1 has no timeout of its own (until F5) and has been observed taking 5-11+
# minutes and climbing as the vault grows; on a slow day the 15-min limit was hitting Windows's
# hard TerminateProcess kill PARTWAY THROUGH the script - after vault/note writes but before
# Telegram delivery - which bypasses every try/catch/finally in the script entirely. 30 minutes is
# a safety margin, not a guarantee: it does not fix an unbounded Claude call (see F5's own 25-min
# job timeout, which is designed to fire well inside this limit), and if generation time keeps
# climbing with the vault this number will need revisiting again. This value MUST stay in sync
# with RUN_LIMIT_MS in app/lib/livestate.js (see tests/scheduler-settings.Tests.ps1) - the two are
# hardcoded independently and nothing else enforces agreement between them.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'Jarvis Morning Debrief' -Action $action -Trigger @($trigger, $trigger2) `
  -Settings $settings -Description 'Generates and delivers the morning debrief (Telegram/email per CONFIG debrief_delivery)' -Force
Write-Host "Registered 'Jarvis Morning Debrief' at 08:30 (machine-local) with a 09:15 hibernation catch-up trigger, running the installed skill copy."
