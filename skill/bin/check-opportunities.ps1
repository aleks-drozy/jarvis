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

function Get-OpportunityMaxMessages {
  # CRITICAL-1 FIX, second half (review): check-job-mail.ps1 keeps only the newest -MaxMessages ids
  # (SEARCH returns ids in ascending order, and it slices the newest N off the end). A wider
  # SinceHours window on a busy inbox with a MaxMessages that stayed fixed at 40 would silently drop
  # the OLDEST messages in that wider window - reintroducing the exact hole the window fix closes,
  # just one layer down. Scale MaxMessages to match: same 40-per-24h budget the original default
  # implied, floored at 40 so a normal (or narrower) window never regresses.
  param([int]$SinceHours, [int]$PerDayBudget = 40, [int]$MinMessages = 40)
  $scaled = [int][math]::Ceiling(($SinceHours / 24.0) * $PerDayBudget)
  if ($scaled -lt $MinMessages) { return $MinMessages }
  return $scaled
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
  #
  # TEST SEAM (review finding, Important 2): this function used to dot-source check-job-mail.ps1 and
  # telegram-bot.ps1 unconditionally and call the real Get-JobMail / Get-TelegramCred / Send-Telegram -
  # no test could drive it without real IMAP, real Telegram and the real credential store, which is
  # exactly why the Important-1 bug below could ship untested. The obvious fix - have a test define its
  # own Get-JobMail/Send-Telegram/Get-TelegramCred BEFORE calling this function, relying on PowerShell
  # function shadowing - does NOT work here: verified empirically (a 3-file dot-source-inside-a-function
  # repro) that the dot-source of check-job-mail.ps1/telegram-bot.ps1 happens in THIS function's own
  # local scope, and a local-scope definition always wins over whatever a caller shadowed one level out,
  # regardless of definition order. So the seam is these three explicit -MailFetcher/-Sender/
  # -CredResolver scriptblock parameters instead: when supplied, they run in place of the real calls;
  # when omitted, production behaviour (real IMAP, real Telegram, real credential store) is unchanged.
  # -MailFetcher (when supplied) is now ALSO called with -SinceHours/-MaxMessages so a test can assert
  # what actually would have reached Get-JobMail; a plain scriptblock with no param() block (every
  # existing test) simply ignores the extra named arguments (verified empirically) so this is additive.
  param(
    [datetime]$Now = (Get-Date), [string]$StorePath = '', [int]$SinceHours = 24, [int]$MaxMessages = 0,
    [string]$SweepStatePath = '', [string]$HeartbeatPath = '',
    [scriptblock]$MailFetcher = $null,
    [scriptblock]$Sender = $null,
    [scriptblock]$CredResolver = $null
  )

  # IMPORTANT-1 FIX (review): capture the caller's -SinceHours BEFORE either dot-source below runs.
  # check-job-mail.ps1 and telegram-bot.ps1 are dot-sourced INSIDE this function's body; each declares
  # its OWN [int]$SinceHours = 24 in its own param() block, and a dot-sourced param() block executes in
  # the CALLER's scope - so dot-sourcing either one with only -DotSourceOnly (no -SinceHours) silently
  # resets THIS function's $SinceHours variable back to 24, discarding whatever was actually passed in.
  # Verified by the reviewer: Probe-SweepPrologue -SinceHours 48 -> SinceHoursAsPassed : 24. Only
  # $SinceHours collides (both files declare it); $Now/$Sender/$MailFetcher/$CredResolver/$StorePath do
  # not, which is why the existing test seam kept working even with this bug live. Copying the value to
  # a name neither dot-sourced file declares, before either dot-source executes, is what survives it.
  # $PSBoundParameters distinguishes "caller passed -SinceHours explicitly" from "used the 24 default" -
  # an explicit value (tests; a future manual run) always wins outright; only the unspecified default
  # case falls through to the CRITICAL-1 gap-sized auto window below.
  $sinceHoursWasExplicit = $PSBoundParameters.ContainsKey('SinceHours')
  $callerSinceHours   = $SinceHours
  $callerMaxMessages  = $MaxMessages

  . (Join-Path $BIN 'opportunity-store.ps1') -DotSourceOnly
  if (-not $StorePath)      { $StorePath      = Get-OpportunityStorePath }
  if (-not $SweepStatePath) { $SweepStatePath = Get-OpportunitySweepStatePath }
  if (-not $HeartbeatPath)  { $HeartbeatPath  = Get-OpportunityHeartbeatPath }
  $sent = 0
  $sweepOk = $false
  $sweepError = $null
  $wasCorrupt = $false

  try {
    . (Join-Path $BIN 'check-job-mail.ps1') -DotSourceOnly
    . (Join-Path $BIN 'telegram-bot.ps1') -DotSourceOnly
    $cred = if ($CredResolver) { & $CredResolver } else { Get-TelegramCred }

    # CRITICAL-1 FIX (review): when the caller did NOT explicitly pass -SinceHours, size the window to
    # the ACTUAL gap since the last successful sweep (Get-OpportunitySweepWindowHours, opportunity-
    # store.ps1) instead of a fixed 24h. Owner works UPS night shifts: laptop closed Friday 18:00,
    # reopened Monday 09:00 - a fixed-24h catch-up sweep looks back only to Sunday and a Saturday
    # invite is never fetched, classified or pushed. Not late: never. MaxMessages is scaled to match
    # (Get-OpportunityMaxMessages) - check-job-mail.ps1 keeps only the newest N ids, so a wider window
    # with a MaxMessages that stayed fixed would silently drop the oldest messages in a busy inbox,
    # reopening the same hole one layer down.
    $effectiveSinceHours = if ($sinceHoursWasExplicit) { $callerSinceHours } else {
      Get-OpportunitySweepWindowHours -LastSweepAt (Read-OpportunitySweepState -Path $SweepStatePath) -Now $Now
    }
    $effectiveMaxMessages = if ($callerMaxMessages -gt 0) { $callerMaxMessages } else {
      Get-OpportunityMaxMessages -SinceHours $effectiveSinceHours
    }

    $res = if ($MailFetcher) { & $MailFetcher -SinceHours $effectiveSinceHours -MaxMessages $effectiveMaxMessages } else {
      Get-JobMail -SinceHours $effectiveSinceHours -SenderFilter $JarvisJobSenderFilter -MaxMessages $effectiveMaxMessages -Mode 'jobs'
    }
    $records = @(Read-OpportunityStore -Path $StorePath -WasCorrupt ([ref]$wasCorrupt))

    foreach ($a in (Select-OpportunityAlerts -Alerts $res.JobAlerts)) {
      $dateStr = if ($a.Date) { "$($a.Date)" } else { $Now.ToString('yyyy-MM-dd') }
      $add = Add-Opportunity -Records $records -From $a.From -Subject $a.Subject -Date $dateStr -Now $Now
      $records = $add.Records
      if ($add.IsNew) {
        $rec = @($records | Where-Object { $_.Id -eq (Get-OpportunityId -From $a.From -Subject $a.Subject -Date $dateStr) })[0]
        $text = Format-OpportunityPush -Record $rec
        if ($Sender) { & $Sender -Text $text -Cred $cred | Out-Null } else { Send-Telegram -Text $text -Cred $cred | Out-Null }
        $sent++
        # CARRIED FIX (review, Important 1): persist RIGHT AWAY, not once at the end. The whole body used
        # to sit inside one try/catch with a single Write-OpportunityStore at the very end. If
        # Send-Telegram threw for item N of M (a Telegram timeout, a network blip), items 1..N-1 had
        # ALREADY been pushed for real, but the exception jumped straight to the catch before the write -
        # so next hour's sweep re-read the unchanged store, saw 1..N-1 as new again, and pushed them all
        # a SECOND time. That is exactly the duplicate-push failure Get-OpportunityId exists to prevent
        # (opportunity-store.ps1:21-23). Writing here means that by the time a later push in this same
        # batch throws, every push that already succeeded is already safe on disk. The item whose push
        # just threw is a different story: Add-Opportunity already added ITS record to the in-memory
        # $records too (that assignment runs before Send-Telegram is even attempted, above) - but this
        # write line, which would put it on disk, sits AFTER the throwing Send-Telegram call and so never
        # runs for it. Disk therefore still lacks that one record, which is exactly what lets it be
        # retried (not silently marked done) next hour, instead of being lost.
        # CRITICAL-2 FIX: skip when the store was corrupt this run. $records is reconstructed from an
        # EMPTY read in that case (Read-OpportunityStore quarantined the bad file, not merged with it),
        # so writing it would permanently replace the quarantined original with a small, wrong store -
        # exactly the erasure this fix exists to stop. The push above still goes out (silence is the
        # worse failure); only the write is skipped.
        if (-not $wasCorrupt) { Write-OpportunityStore -Records $records -Path $StorePath }
      }
    }

    # One reminder per morning for anything still open. Hour gate so the sweep does not wake him at 03:00.
    if ($Now.Hour -ge 8) {
      foreach ($due in (Get-OpportunitiesNeedingReminder -Records $records -Now $Now)) {
        $text = Format-OpportunityPush -Record $due -Reminder
        if ($Sender) { & $Sender -Text $text -Cred $cred | Out-Null } else { Send-Telegram -Text $text -Cred $cred | Out-Null }
        $due.LastPushed = $Now.ToString('s')
        $sent++
        # Same fix as above, applied to reminders: $due is the SAME object reference held inside
        # $records (foreach over an array of PSCustomObject does not copy), so this write also carries
        # forward every reminder already sent earlier in this same loop. Same CRITICAL-2 skip-on-corrupt.
        if (-not $wasCorrupt) { Write-OpportunityStore -Records $records -Path $StorePath }
      }
    }

    if (-not $wasCorrupt) {
      # Final write is now a no-op in the common case (every state change above already persisted
      # itself) but is kept as a safety net - e.g. a run where nothing needed a push still re-serializes
      # cleanly. Skipped entirely when the store was corrupt this run (CRITICAL-2): see above.
      Write-OpportunityStore -Records $records -Path $StorePath
      # CRITICAL-1 FIX: persist the last-SUCCESSFUL-sweep timestamp only on the path that reaches here -
      # mail fetch and processing completed without throwing, AND the store was not corrupt. A sweep
      # that fails (IMAP down, bad credential) or hit a corrupt store must NOT advance this stamp: the
      # whole point of gap-sizing is that a failing/degraded run's window keeps GROWING run over run
      # until one finally succeeds cleanly, rather than resetting to a fresh 24h next hour and
      # reopening the exact hole Critical 1 closes.
      Write-OpportunitySweepState -LastSweepAt $Now -Path $SweepStatePath
      $sweepOk = $true
    } else {
      $sweepError = 'opportunity store was corrupt this run; quarantined, sweep window not advanced'
    }
  } catch {
    Write-Warning "opportunity sweep failed (will retry next hour): $($_.Exception.Message)"
    $sweepError = $_.Exception.Message
  }

  # IMPORTANT-3 FIX (review): heartbeat every run, success or failure, so a silently-dying sweep (e.g.
  # an expired Gmail app password) does not read as "healthy" forever just because the hidden wscript
  # launcher discards Write-Warning and the script still exits 0.
  $openCount = 0
  try { $openCount = @(@(Read-OpportunityStore -Path $StorePath) | Where-Object { $_.Status -eq 'open' }).Count } catch { }
  Write-OpportunityHeartbeat -Path $HeartbeatPath -Ok $sweepOk -ErrorMsg $sweepError -OpenCount $openCount -Now $Now

  return $sent
}

if ($DotSourceOnly) { return }

$n = Invoke-OpportunitySweep
Write-Host "Opportunity sweep: $n push(es) sent."
