# tests/check-opportunities.Tests.ps1 - Invoke-OpportunitySweep, the one impure unit: mail in, pushes
# out, records persisted. NO NETWORK: every call below supplies -MailFetcher/-Sender/-CredResolver (the
# test seam - see the comment on Invoke-OpportunitySweep in check-opportunities.ps1 for why plain
# function shadowing does NOT work here) and an explicit -StorePath/-HeartbeatPath/-SweepStatePath under
# $env:TEMP. The real ~/.jarvis/opportunities.json, ~/.jarvis/opportunity-heartbeat.json,
# ~/.jarvis/opportunity-sweep-state.json, real IMAP and real Telegram are never touched by this file.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\check-opportunities.ps1" -DotSourceOnly
. "$PSScriptRoot\..\skill\bin\opportunity-store.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$tmp = Join-Path $env:TEMP ('jarvis-check-opp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function New-Alert {
  param([string]$From, [string]$Subject, [string]$Date, [string]$Classification)
  return [pscustomobject]@{ From = $From; Subject = $Subject; Date = $Date; Classification = $Classification }
}

$fakeCred = [pscustomobject]@{ ChatId = 555; Token = 'test-token-not-real' }
$credResolver = { $fakeCred }
$script:sentTexts = New-Object System.Collections.Generic.List[string]
$cleanSender = { param([string]$Text, $Cred) $script:sentTexts.Add($Text) }
$noAlerts = { param($SinceHours, $MaxMessages) [pscustomobject]@{ JobAlerts = @() } }

try {
  # ===== THE BUG THIS TASK FIXES (Important 1, carried): a mid-batch push failure must not cause a
  # ===== duplicate push next hour. Two NEW opportunities in one batch; the SECOND push throws (a
  # ===== simulated Telegram timeout/network blip). The invariant: whatever was already pushed for real
  # ===== must already be on disk, even though the run as a whole never completes cleanly.
  $store1 = Join-Path $tmp 'opportunities-red.json'
  $hb1a = Join-Path $tmp 'heartbeat-1a.json'; $hb1b = Join-Path $tmp 'heartbeat-1b.json'
  $ss1a = Join-Path $tmp 'sweep-state-1a.json'; $ss1b = Join-Path $tmp 'sweep-state-1b.json'
  $alertA = New-Alert -From 'invite@codesignal.com' -Subject 'Assessment invitation A' -Date '2026-07-21' -Classification 'interview'
  $alertB = New-Alert -From 'hr@company.com'         -Subject 'Offer of employment B'   -Date '2026-07-21' -Classification 'offer'
  $mailFetcher = { param($SinceHours, $MaxMessages) [pscustomobject]@{ JobAlerts = @($alertA, $alertB) } }

  $script:sentTexts.Clear()
  $throwingSender = {
    param([string]$Text, $Cred)
    $script:sentTexts.Add($Text)
    if ($script:sentTexts.Count -eq 2) { throw 'simulated Telegram timeout on the second push' }
  }

  $now = Get-Date '2026-07-21T09:00:00'
  $sentCount = $null
  $threw = $false
  try {
    $sentCount = Invoke-OpportunitySweep -Now $now -StorePath $store1 -HeartbeatPath $hb1a -SweepStatePath $ss1a `
      -MailFetcher $mailFetcher -Sender $throwingSender -CredResolver $credResolver
  } catch { $threw = $true }

  Assert (-not $threw) "Invoke-OpportunitySweep must NEVER throw out to the caller, even when a push inside it throws (never-throw contract)"
  Assert ($script:sentTexts.Count -eq 2) "both pushes were attempted (first succeeded, second threw), got $($script:sentTexts.Count)"
  Assert ($script:sentTexts[0] -match 'Assessment invitation A') "the FIRST push (which succeeded) carried item A's subject"

  # THE RED ASSERTION: the record for the item that was actually, really pushed (A) must be on disk
  # NOW, before any second run - not only after a clean full-batch completion. Before the fix, the whole
  # sweep wrote nothing until the very end, so a throw on push #2 meant push #1's success was NEVER
  # persisted this cycle - this is the exact scenario that reproduced that.
  $onDiskAfterFirstRun = @(Read-OpportunityStore -Path $store1)
  Assert ($onDiskAfterFirstRun.Count -eq 1) "exactly one record must be on disk after a batch where push #1 succeeded and push #2 threw, got $($onDiskAfterFirstRun.Count)"
  Assert ($onDiskAfterFirstRun[0].Subject -eq 'Assessment invitation A') "the record on disk must be item A (the one actually pushed), got '$($onDiskAfterFirstRun[0].Subject)'"

  # Second run: same mail still in the window (as it would be in production), a Sender that no longer
  # throws. Item A must NOT be re-pushed - only item B (whose push never actually succeeded the first
  # time) should go out now.
  $script:sentTexts.Clear()
  $sentCount2 = Invoke-OpportunitySweep -Now $now.AddHours(1) -StorePath $store1 -HeartbeatPath $hb1b -SweepStatePath $ss1b `
    -MailFetcher $mailFetcher -Sender $cleanSender -CredResolver $credResolver

  Assert ($sentCount2 -eq 1) "second run: exactly one push (item B, the one that never actually succeeded before), got $sentCount2"
  Assert ($script:sentTexts.Count -eq 1) "second run: Sender was called exactly once, got $($script:sentTexts.Count)"
  Assert ($script:sentTexts[0] -match 'Offer of employment B') "second run: the push sent is item B, got '$($script:sentTexts[0])'"
  Assert (-not ($script:sentTexts -match 'Assessment invitation A')) "second run: item A must NOT be pushed again - that IS the duplicate-push bug this task fixes"

  $onDiskAfterSecondRun = @(Read-OpportunityStore -Path $store1)
  Assert ($onDiskAfterSecondRun.Count -eq 2) "after the second run both records must be on disk, got $($onDiskAfterSecondRun.Count)"

  # IMPORTANT 3: heartbeat written for a clean successful run - ok, no error, correct open count.
  $hbAfterSecond = Get-Content -LiteralPath $hb1b -Raw | ConvertFrom-Json
  Assert ($hbAfterSecond.ok -eq $true) "IMPORTANT 3: heartbeat reports ok after a clean successful sweep"
  Assert (-not $hbAfterSecond.error) "IMPORTANT 3: heartbeat carries no error on a clean run"
  Assert ($hbAfterSecond.openCount -eq 2) "IMPORTANT 3: heartbeat openCount reflects the two open records, got $($hbAfterSecond.openCount)"
  Assert (Test-Path $ss1b) "CRITICAL 1: a clean successful sweep must persist the last-sweep-succeeded timestamp"

  # ===== Never-throw contract, other direction: the mail fetch ITSELF fails (IMAP down / credential
  # ===== missing). A dead mail server must not take out the scheduled task - Invoke-OpportunitySweep
  # ===== must still return (a count), not propagate.
  $store2 = Join-Path $tmp 'opportunities-mailfail.json'
  $hb2 = Join-Path $tmp 'heartbeat-2.json'; $ss2 = Join-Path $tmp 'sweep-state-2.json'
  $failingMailFetcher = { throw 'simulated IMAP outage' }
  $neverCalledSender = { param([string]$Text, $Cred) throw 'Sender must never be reached when the mail fetch itself failed' }
  $threw2 = $false
  $result2 = $null
  try {
    $result2 = Invoke-OpportunitySweep -Now $now -StorePath $store2 -HeartbeatPath $hb2 -SweepStatePath $ss2 `
      -MailFetcher $failingMailFetcher -Sender $neverCalledSender -CredResolver $credResolver
  } catch { $threw2 = $true }
  Assert (-not $threw2) "a mail-fetch failure must not propagate out of Invoke-OpportunitySweep (never-throw contract)"
  Assert ($result2 -eq 0) "a mail-fetch failure sends nothing and still returns a count (0), got $result2"

  # IMPORTANT 3: heartbeat still written on a FAILED run, with ok=false and an error message - this is
  # the whole point (Task Scheduler must not read a silently-dying sweep as healthy forever).
  $hbAfterFail = Get-Content -LiteralPath $hb2 -Raw | ConvertFrom-Json
  Assert ($hbAfterFail.ok -eq $false) "IMPORTANT 3: heartbeat reports NOT ok after a mail-fetch failure"
  Assert ($hbAfterFail.error -match 'simulated IMAP outage') "IMPORTANT 3: heartbeat error carries the real failure reason, got '$($hbAfterFail.error)'"
  Assert (-not (Test-Path $ss2)) "CRITICAL 1: a FAILED sweep must NOT advance the last-sweep-succeeded timestamp - otherwise the next run's window would shrink back to 24h instead of growing until a sweep actually succeeds"

  # ===== The seam itself never touches anything real: prove production entry points were never called
  # ===== by checking no file exists at either store path until Invoke-OpportunitySweep (the seamed
  # ===== version) explicitly wrote one via Write-OpportunityStore -Path <the -StorePath we passed>.
  Assert (Test-Path $store1) "the sweep must have written to the -StorePath we supplied, not the real store"
  Assert ($store1 -like (Join-Path $env:TEMP '*')) "store path used by this test lives under `$env:TEMP, never a real path"

  # =====================================================================================================
  # CRITICAL 1 (RED then GREEN): a laptop closed Friday 18:00, reopened Monday 09:00 must search back
  # far enough to cover Saturday's mail, not a fixed 24h. Proven via the ACTUAL value that would reach
  # Get-JobMail - captured through the -MailFetcher seam - rather than trusting the return count, since a
  # too-narrow window fails by silently fetching nothing, not by throwing.
  # =====================================================================================================
  $ss4 = Join-Path $tmp 'sweep-state-gap.json'
  $lastSweep = Get-Date '2026-07-17T18:00:00'   # Friday 18:00
  $nowAfterWeekend = Get-Date '2026-07-20T09:00:00'   # Monday 09:00
  '{ "lastSweepAt": "2026-07-17T18:00:00" }' | Set-Content -Encoding UTF8 $ss4

  $script:capturedSinceHours = $null
  $script:capturedMaxMessages = $null
  $capturingFetcher = {
    param($SinceHours, $MaxMessages)
    $script:capturedSinceHours = $SinceHours
    $script:capturedMaxMessages = $MaxMessages
    [pscustomobject]@{ JobAlerts = @() }
  }
  $store4 = Join-Path $tmp 'opportunities-gap.json'
  $hb4 = Join-Path $tmp 'heartbeat-gap.json'
  $null = Invoke-OpportunitySweep -Now $nowAfterWeekend -StorePath $store4 -SweepStatePath $ss4 -HeartbeatPath $hb4 `
    -MailFetcher $capturingFetcher -Sender $cleanSender -CredResolver $credResolver

  $expectedGapHours = [math]::Ceiling(($nowAfterWeekend - $lastSweep).TotalHours)   # ~63h
  Assert ($expectedGapHours -gt 48) "test sanity: the simulated weekend gap must exceed the old fixed 24h window, got $expectedGapHours"
  Assert ($script:capturedSinceHours -eq $expectedGapHours) "CRITICAL 1 (weekend hole): the window reaching Get-JobMail must be sized to the ACTUAL gap since the last successful sweep (~$expectedGapHours h), got $($script:capturedSinceHours) - a fixed 24h here is exactly how a Saturday invite is never fetched, never classified, never pushed after a weekend the laptop was closed. Not late - never."
  Assert ($script:capturedSinceHours -ne 24) "CRITICAL 1 (weekend hole): must NOT still be the old fixed 24h window"
  Assert ($script:capturedMaxMessages -ge 40) "CRITICAL 1 (MaxMessages half): MaxMessages must scale with the widened window, not stay pinned at the original 40 - otherwise a wide window on a busy inbox silently drops the oldest messages, reopening the same hole one layer down"
  Assert ($script:capturedMaxMessages -gt 40) "CRITICAL 1 (MaxMessages half): for a >24h window, MaxMessages must actually be RAISED above the 24h-window default of 40, got $($script:capturedMaxMessages)"

  # floor/ceiling sanity at the sweep level (fine-grained floor/ceiling math is unit-tested directly on
  # Get-OpportunitySweepWindowHours in opportunity-store.Tests.ps1)
  $ss4b = Join-Path $tmp 'sweep-state-gap-first-ever.json'   # never swept before -> ceiling, not a throw
  $script:capturedSinceHours = $null
  $store4b = Join-Path $tmp 'opportunities-gap-first-ever.json'
  $hb4b = Join-Path $tmp 'heartbeat-gap-first-ever.json'
  $null = Invoke-OpportunitySweep -Now $nowAfterWeekend -StorePath $store4b -SweepStatePath $ss4b -HeartbeatPath $hb4b `
    -MailFetcher $capturingFetcher -Sender $cleanSender -CredResolver $credResolver
  Assert ($script:capturedSinceHours -eq 336) "CRITICAL 1: a sweep that has never succeeded before (no state file yet) must use the generous ceiling window, got $($script:capturedSinceHours)"

  # =====================================================================================================
  # IMPORTANT 1: an explicit -SinceHours must actually reach Get-JobMail, not be silently reset back to
  # 24 by check-job-mail.ps1's own param() block executing in this function's scope when dot-sourced.
  # Reviewer's probe: Probe-SweepPrologue -SinceHours 48 -> SinceHoursAsPassed : 24 (the bug). This also
  # matters for Critical 1 directly: if an explicit override silently voided back to 24, the whole
  # gap-sizing fix above would mean nothing the moment anything ever passed -SinceHours on purpose.
  # =====================================================================================================
  $script:capturedSinceHours2 = $null
  $explicitFetcher = { param($SinceHours, $MaxMessages) $script:capturedSinceHours2 = $SinceHours; [pscustomobject]@{ JobAlerts = @() } }
  $store5 = Join-Path $tmp 'opportunities-explicit.json'
  $hb5 = Join-Path $tmp 'heartbeat-explicit.json'; $ss5 = Join-Path $tmp 'sweep-state-explicit.json'
  $null = Invoke-OpportunitySweep -Now (Get-Date '2026-07-21T09:00:00') -SinceHours 48 -StorePath $store5 -SweepStatePath $ss5 -HeartbeatPath $hb5 `
    -MailFetcher $explicitFetcher -Sender $cleanSender -CredResolver $credResolver
  Assert ($script:capturedSinceHours2 -eq 48) "IMPORTANT 1: an explicit -SinceHours must reach Get-JobMail unchanged, got $($script:capturedSinceHours2) instead of 48 - the dot-sourced check-job-mail.ps1/telegram-bot.ps1 param() blocks must not clobber it"

  # =====================================================================================================
  # TEST GAP 1: the reminder half of the success criterion, exercised at the SWEEP level. The tests
  # above never advance across a day boundary, so the reminder loop (Get-OpportunitiesNeedingReminder,
  # gated on $Now.Hour -ge 8) never actually runs. Prove: before 08:00 the gate stays CLOSED even though
  # a reminder is due; at/after 08:00 exactly ONE reminder fires, LastPushed advances and PERSISTS; a
  # later sweep the SAME day sends none.
  # =====================================================================================================
  $store6 = Join-Path $tmp 'opportunities-reminder.json'
  $hb6a = Join-Path $tmp 'heartbeat-r1.json'; $hb6b = Join-Path $tmp 'heartbeat-r2.json'; $hb6c = Join-Path $tmp 'heartbeat-r3.json'
  $ss6a = Join-Path $tmp 'sweep-state-r1.json'; $ss6b = Join-Path $tmp 'sweep-state-r2.json'; $ss6c = Join-Path $tmp 'sweep-state-r3.json'
  $seedRecords = @([pscustomobject]@{ Id='d00d1e'; From='invite@codesignal.com'; Subject='Your assessment'; Date='2026-07-20'; Status='open'; FirstSeen='2026-07-20T09:00:00'; LastPushed='2026-07-20T09:00:00' })
  Write-OpportunityStore -Records $seedRecords -Path $store6

  # gate CLOSED: next day but before 08:00 - a reminder IS due (LastPushed is yesterday) but must not fire
  $script:sentTexts.Clear()
  $sentEarly = Invoke-OpportunitySweep -Now (Get-Date '2026-07-21T07:59:00') -StorePath $store6 -SweepStatePath $ss6a -HeartbeatPath $hb6a `
    -MailFetcher $noAlerts -Sender $cleanSender -CredResolver $credResolver
  Assert ($sentEarly -eq 0) "TEST GAP 1: before 08:00 the reminder gate must stay CLOSED even though a reminder is due, got $sentEarly sent"
  Assert ($script:sentTexts.Count -eq 0) "TEST GAP 1: no reminder text sent before the hour gate"
  $afterEarly = @(Read-OpportunityStore -Path $store6)
  Assert ($afterEarly[0].LastPushed -eq '2026-07-20T09:00:00') "TEST GAP 1: LastPushed must NOT advance when the gate is closed"

  # gate OPEN: next day, 09:00 - exactly ONE reminder fires, and it PERSISTS
  $script:sentTexts.Clear()
  $sentOnTime = Invoke-OpportunitySweep -Now (Get-Date '2026-07-21T09:00:00') -StorePath $store6 -SweepStatePath $ss6b -HeartbeatPath $hb6b `
    -MailFetcher $noAlerts -Sender $cleanSender -CredResolver $credResolver
  Assert ($sentOnTime -eq 1) "TEST GAP 1: after 08:00 exactly one reminder must fire for the open record, got $sentOnTime"
  Assert ($script:sentTexts.Count -eq 1 -and $script:sentTexts[0] -match 'Still open, Sir') "TEST GAP 1: the reminder text uses the reminder wording, got '$($script:sentTexts -join '|')'"
  $afterOnTime = @(Read-OpportunityStore -Path $store6)
  Assert (([datetime]::Parse($afterOnTime[0].LastPushed)).Date -eq (Get-Date '2026-07-21').Date) "TEST GAP 1: LastPushed must advance to today and PERSIST to disk, got '$($afterOnTime[0].LastPushed)'"

  # same day, later: one reminder per day - must NOT re-remind
  $script:sentTexts.Clear()
  $sentLater = Invoke-OpportunitySweep -Now (Get-Date '2026-07-21T14:00:00') -StorePath $store6 -SweepStatePath $ss6c -HeartbeatPath $hb6c `
    -MailFetcher $noAlerts -Sender $cleanSender -CredResolver $credResolver
  Assert ($sentLater -eq 0) "TEST GAP 1: a later sweep the SAME day must send no further reminder, got $sentLater"
  Assert ($script:sentTexts.Count -eq 0) "TEST GAP 1: no reminder text sent on the same-day repeat sweep"

  # =====================================================================================================
  # TEST GAP 3: the join between the two subsystems. A record cleared via Set-OpportunityStatus (what
  # telegram-bot.ps1's clear-opportunity branch calls) must stop a SUBSEQUENT Invoke-OpportunitySweep
  # from reminding on it - proving the write from one subsystem is actually seen and honoured by the
  # other, not merely that each works correctly in isolation.
  # =====================================================================================================
  $store7 = Join-Path $tmp 'opportunities-join.json'
  $hb7 = Join-Path $tmp 'heartbeat-join.json'; $ss7 = Join-Path $tmp 'sweep-state-join.json'
  $openRec = @([pscustomobject]@{ Id='c1ea12'; From='invite@codesignal.com'; Subject='Your assessment'; Date='2026-07-20'; Status='open'; FirstSeen='2026-07-20T09:00:00'; LastPushed='2026-07-20T09:00:00' })
  Write-OpportunityStore -Records $openRec -Path $store7
  $cleared = Set-OpportunityStatus -Records (@(Read-OpportunityStore -Path $store7)) -Id 'c1ea12' -Status 'done'
  Assert ($cleared.Found) "test setup: clearing the seeded record must succeed"
  Write-OpportunityStore -Records $cleared.Records -Path $store7

  $script:sentTexts.Clear()
  $sentAfterClear = Invoke-OpportunitySweep -Now (Get-Date '2026-07-21T09:00:00') -StorePath $store7 -SweepStatePath $ss7 -HeartbeatPath $hb7 `
    -MailFetcher $noAlerts -Sender $cleanSender -CredResolver $credResolver
  Assert ($sentAfterClear -eq 0) "TEST GAP 3: a record cleared via Set-OpportunityStatus must stop the next sweep from reminding on it, got $sentAfterClear reminder(s) sent"
  Assert ($script:sentTexts.Count -eq 0) "TEST GAP 3: no reminder text sent for a record cleared by the OTHER subsystem"

  # =====================================================================================================
  # CRITICAL 2 (RED then GREEN): a corrupt store must be QUARANTINED, never silently erased by the very
  # next sweep. Before the fix, Read-OpportunityStore returned @() for corrupt content and
  # Invoke-OpportunitySweep's unconditional final write then overwrote the corrupt bytes with a valid,
  # empty "[]" - a lost record silently became a lost opportunity, with only a Write-Warning (discarded
  # by the hidden wscript launcher) as any signal at all.
  # =====================================================================================================
  $store3 = Join-Path $tmp 'opportunities-corrupt.json'
  $hb3 = Join-Path $tmp 'heartbeat-corrupt.json'; $ss3 = Join-Path $tmp 'sweep-state-corrupt.json'
  $marker = 'CANARY-MARKER-e7b3-this-text-must-survive-a-sweep-over-a-corrupt-store'
  Set-Content -Encoding UTF8 $store3 "{ not valid json at all - $marker"

  $script:sentTexts.Clear()
  $sentCount3 = Invoke-OpportunitySweep -Now (Get-Date '2026-07-21T09:00:00') -StorePath $store3 -HeartbeatPath $hb3 -SweepStatePath $ss3 `
    -MailFetcher $noAlerts -Sender $cleanSender -CredResolver $credResolver

  # THE RED ASSERTION: the original corrupt content must survive on disk somewhere (quarantined), and
  # nothing valid must have been written back to the ORIGINAL path where the corrupt file was.
  $quarantineFiles = @(Get-ChildItem -Path $tmp -Filter 'opportunities-corrupt.json.corrupt-*')
  Assert ($quarantineFiles.Count -eq 1) "CRITICAL 2 (store erasure): a corrupt store must be quarantined to a '<path>.corrupt-<timestamp>' file - before the fix nothing preserved it at all, got $($quarantineFiles.Count) quarantine file(s)"
  Assert ((Get-Content -LiteralPath $quarantineFiles[0].FullName -Raw) -match [regex]::Escape($marker)) "CRITICAL 2 (store erasure): the quarantined file must contain the ORIGINAL corrupt bytes, unmodified"
  Assert (-not (Test-Path $store3)) "CRITICAL 2 (store erasure): the sweep must NOT leave a fresh, valid, empty store sitting at the path the corrupt one occupied - before the fix, the unconditional final write did exactly this, silently erasing every record for good"

  $hbAfterCorrupt = Get-Content -LiteralPath $hb3 -Raw | ConvertFrom-Json
  Assert ($hbAfterCorrupt.ok -eq $false) "IMPORTANT 3: heartbeat reports NOT ok after a run whose store was corrupt"
  Assert ($hbAfterCorrupt.error -match 'corrupt') "IMPORTANT 3: heartbeat error explains why, got '$($hbAfterCorrupt.error)'"
  Assert (-not (Test-Path $ss3)) "CRITICAL 1 tie-in: a corrupt-store run is not a clean success and must not advance the sweep-window state"

} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "check-opportunities: ALL PASS"
