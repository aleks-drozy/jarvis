# skill/bin/check-opportunities.ps1
# Hourly sweep for OPEN DOORS: assessment invites, interview requests, offers. Rejections are not
# swept - they wait for the 08:30 debrief, because Alex can do nothing about them and an alarm that
# fires for the unactionable is an alarm that gets switched off.
#
# WHY HOURLY, and not on the 3-minute Telegram poller: an assessment deadline moves in days, so an
# hour is ample, and the poller's job is responsiveness to Alex - not polling the world 480 times a day.
#
# Safety 5: sender + subject + date only. Bodies are NEVER read. The 07-21 diagnosis suggested
# extracting deadlines from message bodies; that is a deliberate change to a safety rule and was
# refused here rather than smuggled in as part of a feature.
# Safety 2: every push goes through Send-Telegram, which locks the chat id in code before the network
# call, and composes its text INSIDE this script - a subject is attacker-controlled and must never
# reach a command line (the 2026-07-15 injection).
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param([switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'
$BIN = $PSScriptRoot

function Select-OpportunityAlerts {
  # An opportunity is a door that is OPEN. Interview and offer only.
  param($Alerts)
  if (-not $Alerts) { return @() }
  return @(@($Alerts) | Where-Object { $_.Classification -eq 'interview' -or $_.Classification -eq 'offer' })
}

function Format-OpportunityPush {
  # Composed here, from variables, never by splicing a subject into a command line.
  param($Record, [switch]$Reminder)
  $lead = if ($Reminder) { 'Still open, Sir' } else { 'A door just opened, Sir' }
  return @"
$lead.

$($Record.Subject)
from $($Record.From)

Reply "done $($Record.Id)" once you have actioned it, or "ignore $($Record.Id)" to drop it.
I will keep raising this every morning until you do.
"@
}

function Invoke-OpportunitySweep {
  # Returns the number of pushes sent. Never throws: a mail server that is down must not take out the
  # scheduled task, and a failure to record must not become a failure to notify.
  param([datetime]$Now = (Get-Date), [string]$StorePath = '', [int]$SinceHours = 24)

  . (Join-Path $BIN 'opportunity-store.ps1') -DotSourceOnly
  if (-not $StorePath) { $StorePath = Get-OpportunityStorePath }
  $sent = 0

  try {
    . (Join-Path $BIN 'check-job-mail.ps1') -DotSourceOnly
    . (Join-Path $BIN 'telegram-bot.ps1') -DotSourceOnly
    $cred = Get-TelegramCred

    $res = Get-JobMail -SinceHours $SinceHours -SenderFilter $JarvisJobSenderFilter -MaxMessages 40 -Mode 'jobs'
    $records = @(Read-OpportunityStore -Path $StorePath)

    foreach ($a in (Select-OpportunityAlerts -Alerts $res.JobAlerts)) {
      $dateStr = if ($a.Date) { "$($a.Date)" } else { $Now.ToString('yyyy-MM-dd') }
      $add = Add-Opportunity -Records $records -From $a.From -Subject $a.Subject -Date $dateStr -Now $Now
      $records = $add.Records
      if ($add.IsNew) {
        $rec = @($records | Where-Object { $_.Id -eq (Get-OpportunityId -From $a.From -Subject $a.Subject -Date $dateStr) })[0]
        Send-Telegram -Text (Format-OpportunityPush -Record $rec) -Cred $cred | Out-Null
        $sent++
      }
    }

    # One reminder per morning for anything still open. Hour gate so the sweep does not wake him at 03:00.
    if ($Now.Hour -ge 8) {
      foreach ($due in (Get-OpportunitiesNeedingReminder -Records $records -Now $Now)) {
        Send-Telegram -Text (Format-OpportunityPush -Record $due -Reminder) -Cred $cred | Out-Null
        $due.LastPushed = $Now.ToString('s')
        $sent++
      }
    }

    Write-OpportunityStore -Records $records -Path $StorePath
  } catch {
    Write-Warning "opportunity sweep failed (will retry next hour): $($_.Exception.Message)"
  }
  return $sent
}

if ($DotSourceOnly) { return }

$n = Invoke-OpportunitySweep
Write-Host "Opportunity sweep: $n push(es) sent."
