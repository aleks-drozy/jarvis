# tests/opportunity-store.Tests.ps1 - the record layer for the opportunity alarm. Pure, no network.
# Every test uses an explicit -Path under $env:TEMP; the real ~/.jarvis/opportunities.json is never touched.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\opportunity-store.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$tmp = Join-Path $env:TEMP ('jarvis-opp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$store = Join-Path $tmp 'opportunities.json'
try {
  # --- ids are stable across runs and unique across messages ---
  $a1 = Get-OpportunityId -From 'invite@codesignal.com' -Subject 'Your assessment' -Date '2026-07-21'
  $a2 = Get-OpportunityId -From 'invite@codesignal.com' -Subject 'Your assessment' -Date '2026-07-21'
  $b  = Get-OpportunityId -From 'invite@codesignal.com' -Subject 'Your OTHER assessment' -Date '2026-07-21'
  Assert ($a1 -eq $a2) "the same message must always derive the same id (idempotency)"
  Assert ($a1 -ne $b) "different subjects must derive different ids"
  Assert ($a1 -match '^[0-9a-f]{6}$') "id is 6 lowercase hex chars, short enough to type on a phone, got '$a1'"

  # --- CARRIED FIX from the Task 2 review: the old seed joined "$From|$Subject|$Date" with an
  # --- unescaped pipe. Subject is attacker-controlled, so a pipe inside it could shift the field
  # --- boundary and make two STRUCTURALLY DIFFERENT triples hash to the SAME seed - a genuinely new
  # --- opportunity silently treated as already-seen and never pushed. Length-prefixing each field
  # --- closes it: ('a', 'b|c', 'd') and ('a|b', 'c', 'd') both used to join to "a|b|c|d".
  $collide1 = Get-OpportunityId -From 'a'   -Subject 'b|c' -Date 'd'
  $collide2 = Get-OpportunityId -From 'a|b' -Subject 'c'   -Date 'd'
  Assert ($collide1 -ne $collide2) "a pipe inside Subject must not let two different (From,Subject,Date) triples collide on the same id"

  # --- missing file reads as empty, never throws ---
  Assert ((@(Read-OpportunityStore -Path $store)).Count -eq 0) "absent store reads as empty"

  # --- adding, and the duplicate guard that stops a second push ---
  $now = Get-Date '2026-07-21T09:00:00'
  $r = Add-Opportunity -Records @() -From 'invite@codesignal.com' -Subject 'Your assessment' -Date '2026-07-21' -Now $now
  Assert ($r.IsNew) "a first sighting is new"
  Assert ((@($r.Records)).Count -eq 1) "one record stored"
  Assert ($r.Records[0].Status -eq 'open') "a new opportunity starts open"

  $r2 = Add-Opportunity -Records $r.Records -From 'invite@codesignal.com' -Subject 'Your assessment' -Date '2026-07-21' -Now $now
  Assert (-not $r2.IsNew) "the SAME message seen twice must NOT be new - this is what stops a duplicate push"
  Assert ((@($r2.Records)).Count -eq 1) "and must not create a second record"

  # --- round trip through disk ---
  Write-OpportunityStore -Records $r.Records -Path $store
  $back = @(Read-OpportunityStore -Path $store)
  Assert ($back.Count -eq 1) "round trip preserves the record"
  Assert ($back[0].Id -eq $r.Records[0].Id) "round trip preserves the id"

  # --- clearing ---
  $c = Set-OpportunityStatus -Records $back -Id $back[0].Id -Status 'done'
  Assert ($c.Found) "clearing a known id reports found"
  Assert ($c.Records[0].Status -eq 'done') "status is updated"
  $c2 = Set-OpportunityStatus -Records $back -Id 'zzzzzz' -Status 'done'
  Assert (-not $c2.Found) "clearing an unknown id reports not-found, and does not throw"

  # --- THE REASON CLEARED RECORDS ARE KEPT RATHER THAN DELETED. The same message will keep arriving
  # --- in the 24h mail window after Alex has actioned it. If a 'done' record did not block re-adding,
  # --- every sweep would push it again and the alarm would punish him for clearing it.
  $again = Add-Opportunity -Records $c.Records -From 'invite@codesignal.com' -Subject 'Your assessment' -Date '2026-07-21' -Now $now
  Assert (-not $again.IsNew) "a CLEARED message must never be re-detected as new - this is why done records are kept"
  Assert ((@($again.Records)).Count -eq 1) "and must not create a duplicate record"
  Assert ((@(Get-OpportunitiesNeedingReminder -Records $again.Records -Now (Get-Date '2026-07-22T09:00:00'))).Count -eq 0) "nor be reminded the next morning"

  # --- the reminder rule: open, and not already pushed today ---
  $rec = @([pscustomobject]@{ Id='aaa111'; From='x'; Subject='y'; Date='2026-07-21'; Status='open';   FirstSeen='2026-07-20T09:00:00'; LastPushed='2026-07-20T09:00:00' },
           [pscustomobject]@{ Id='bbb222'; From='x'; Subject='y'; Date='2026-07-21'; Status='done';   FirstSeen='2026-07-20T09:00:00'; LastPushed='2026-07-20T09:00:00' },
           [pscustomobject]@{ Id='ccc333'; From='x'; Subject='y'; Date='2026-07-21'; Status='open';   FirstSeen='2026-07-21T08:00:00'; LastPushed='2026-07-21T08:00:00' })
  $due = @(Get-OpportunitiesNeedingReminder -Records $rec -Now (Get-Date '2026-07-21T09:00:00'))
  Assert ($due.Count -eq 1) "exactly one record is due a reminder, got $($due.Count)"
  Assert ($due[0].Id -eq 'aaa111') "the OPEN one last pushed yesterday is due"
  Assert (($due | Where-Object { $_.Id -eq 'bbb222' }).Count -eq 0) "a cleared record is never reminded again"
  Assert (($due | Where-Object { $_.Id -eq 'ccc333' }).Count -eq 0) "one reminder per day, not per sweep - already pushed today"

  # --- a corrupt store must not crash the sweep: a lost record must not become a lost opportunity ---
  Set-Content -Encoding UTF8 $store '{ this is not json'
  Assert ((@(Read-OpportunityStore -Path $store)).Count -eq 0) "corrupt store reads as empty instead of throwing"
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Select-OpportunityAlerts: ONLY doors that are open. A rejection is not an opportunity: Alex can
# --- do nothing about it, it belongs in the 08:30 debrief, and an alarm that fires for things you
# --- cannot act on is an alarm you switch off.
. "$PSScriptRoot\..\skill\bin\check-opportunities.ps1" -DotSourceOnly
$alerts = @(
  [pscustomobject]@{ From='invite@codesignal.com'; Subject='Assessment invitation'; Date='2026-07-21'; Classification='interview' },
  [pscustomobject]@{ From='no-reply@workable.com'; Subject='Unfortunately...';       Date='2026-07-21'; Classification='rejection' },
  [pscustomobject]@{ From='hr@company.com';        Subject='Offer of employment';    Date='2026-07-21'; Classification='offer' },
  [pscustomobject]@{ From='jobs@linkedin.com';     Subject='5 new jobs for you';     Date='2026-07-21'; Classification='generic' }
)
$sel = @(Select-OpportunityAlerts -Alerts $alerts)
Assert ($sel.Count -eq 2) "only interview + offer are opportunities, got $($sel.Count)"
Assert (($sel | Where-Object { $_.Classification -eq 'rejection' }).Count -eq 0) "a rejection must NEVER open an alarm record"
Assert (($sel | Where-Object { $_.Classification -eq 'generic' }).Count -eq 0) "a job digest must NEVER open an alarm record"
Assert ((@(Select-OpportunityAlerts -Alerts @())).Count -eq 0) "empty in, empty out"
Assert ((@(Select-OpportunityAlerts -Alerts $null)).Count -eq 0) "null in, empty out - never throw"

Write-Host "opportunity-store: ALL PASS"
