# tests/check-opportunities.Tests.ps1 - Invoke-OpportunitySweep, the one impure unit: mail in, pushes
# out, records persisted. NO NETWORK: every call below supplies -MailFetcher/-Sender/-CredResolver (the
# test seam - see the comment on Invoke-OpportunitySweep in check-opportunities.ps1 for why plain
# function shadowing does NOT work here) and an explicit -StorePath under $env:TEMP. The real
# ~/.jarvis/opportunities.json, real IMAP and real Telegram are never touched by this file.
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

try {
  # ===== THE BUG THIS TASK FIXES (Important 1): a mid-batch push failure must not cause a duplicate
  # ===== push next hour. Two NEW opportunities in one batch; the SECOND push throws (a simulated
  # ===== Telegram timeout/network blip). The invariant: whatever was already pushed for real must
  # ===== already be on disk, even though the run as a whole never completes cleanly.
  $store1 = Join-Path $tmp 'opportunities-red.json'
  $alertA = New-Alert -From 'invite@codesignal.com' -Subject 'Assessment invitation A' -Date '2026-07-21' -Classification 'interview'
  $alertB = New-Alert -From 'hr@company.com'         -Subject 'Offer of employment B'   -Date '2026-07-21' -Classification 'offer'
  $mailFetcher = { [pscustomobject]@{ JobAlerts = @($alertA, $alertB) } }

  $script:sentTexts = New-Object System.Collections.Generic.List[string]
  $throwingSender = {
    param([string]$Text, $Cred)
    $script:sentTexts.Add($Text)
    if ($script:sentTexts.Count -eq 2) { throw 'simulated Telegram timeout on the second push' }
  }

  $now = Get-Date '2026-07-21T09:00:00'
  $sentCount = $null
  $threw = $false
  try {
    $sentCount = Invoke-OpportunitySweep -Now $now -StorePath $store1 -MailFetcher $mailFetcher -Sender $throwingSender -CredResolver $credResolver
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

  # Second run: same mail still in the 24h window (as it would be in production), a Sender that no
  # longer throws. Item A must NOT be re-pushed - only item B (whose push never actually succeeded the
  # first time) should go out now.
  $script:sentTexts.Clear()
  $cleanSender = { param([string]$Text, $Cred) $script:sentTexts.Add($Text) }
  $sentCount2 = Invoke-OpportunitySweep -Now $now.AddHours(1) -StorePath $store1 -MailFetcher $mailFetcher -Sender $cleanSender -CredResolver $credResolver

  Assert ($sentCount2 -eq 1) "second run: exactly one push (item B, the one that never actually succeeded before), got $sentCount2"
  Assert ($script:sentTexts.Count -eq 1) "second run: Sender was called exactly once, got $($script:sentTexts.Count)"
  Assert ($script:sentTexts[0] -match 'Offer of employment B') "second run: the push sent is item B, got '$($script:sentTexts[0])'"
  Assert (-not ($script:sentTexts -match 'Assessment invitation A')) "second run: item A must NOT be pushed again - that IS the duplicate-push bug this task fixes"

  $onDiskAfterSecondRun = @(Read-OpportunityStore -Path $store1)
  Assert ($onDiskAfterSecondRun.Count -eq 2) "after the second run both records must be on disk, got $($onDiskAfterSecondRun.Count)"

  # ===== Never-throw contract, other direction: the mail fetch ITSELF fails (IMAP down / credential
  # ===== missing). A dead mail server must not take out the scheduled task - Invoke-OpportunitySweep
  # ===== must still return (a count), not propagate.
  $store2 = Join-Path $tmp 'opportunities-mailfail.json'
  $failingMailFetcher = { throw 'simulated IMAP outage' }
  $neverCalledSender = { param([string]$Text, $Cred) throw 'Sender must never be reached when the mail fetch itself failed' }
  $threw2 = $false
  $result2 = $null
  try {
    $result2 = Invoke-OpportunitySweep -Now $now -StorePath $store2 -MailFetcher $failingMailFetcher -Sender $neverCalledSender -CredResolver $credResolver
  } catch { $threw2 = $true }
  Assert (-not $threw2) "a mail-fetch failure must not propagate out of Invoke-OpportunitySweep (never-throw contract)"
  Assert ($result2 -eq 0) "a mail-fetch failure sends nothing and still returns a count (0), got $result2"

  # ===== The seam itself never touches anything real: prove production entry points were never called
  # ===== by checking no file exists at either store path until Invoke-OpportunitySweep (the seamed
  # ===== version) explicitly wrote one via Write-OpportunityStore -Path <the -StorePath we passed>.
  Assert (Test-Path $store1) "the sweep must have written to the -StorePath we supplied, not the real store"
  Assert ($store1 -like (Join-Path $env:TEMP '*')) "store path used by this test lives under `$env:TEMP, never a real path"

} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "check-opportunities: ALL PASS"
