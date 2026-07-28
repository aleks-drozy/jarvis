# tests/debrief-catchup-idempotency.Tests.ps1 - F8b: scripts/register-task.ps1 now registers a
# SECOND daily trigger (09:15) as a bounded catch-up for a hibernated (S4) night, since
# StartWhenAvailable alone has at least one confirmed real-world failure to catch up at all. Adding
# a second trigger without idempotency would mean a day where 08:30 DID succeed still gets a full
# second run at 09:15 - regenerating the note and RE-SENDING it, a duplicate Telegram/email message.
# This asserts jarvis-debrief.ps1's new Test-AlreadySentToday guard (which reuses the F3 heartbeat
# file as its source of truth) actually makes that second run a safe no-op.
#
# Extraction pattern matches tests/debrief-heartbeat.Tests.ps1: jarvis-debrief.ps1 runs a full
# debrief the moment it is dot-sourced, so the function under test is lifted out by source
# extraction and defined in an isolated scope, rather than dot-sourcing the whole script.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Test-AlreadySentToday \{.*?^\}')
Assert ($fnMatch.Success) "could not extract Test-AlreadySentToday from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

$dir = Join-Path $env:TEMP ('jarvis-catchup-idem-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$hbFile = Join-Path $dir 'debrief-heartbeat.json'

try {
  # 1) No heartbeat at all yet (e.g. very first run of the day, or the file has never existed) -
  # the 08:30 trigger's own first attempt must never be treated as a duplicate.
  Assert (-not (Test-Path $hbFile)) "sanity: heartbeat file must not pre-exist"
  Assert (-not (Test-AlreadySentToday -Date '2026-07-28' -HeartbeatFile $hbFile)) `
    "with no heartbeat file at all, today's run must NOT be treated as already sent"

  # 2) THE CORE SCENARIO: 08:30 fired and succeeded (heartbeat now carries today's date). The 09:15
  # catch-up trigger firing next - simulating a hibernated night where the wake timer misfired and
  # both triggers ended up landing close together, or simply the ordinary bounded-catch-up shape -
  # must be recognized as a duplicate and skipped.
  @{ date = '2026-07-28'; channel = 'telegram'; sentAt = '2026-07-28T08:33:00' } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $hbFile
  Assert (Test-AlreadySentToday -Date '2026-07-28' -HeartbeatFile $hbFile) `
    "once today's debrief already sent (per heartbeat), the 09:15 catch-up run must be treated as a safe no-op"

  # 3) A stale heartbeat from a PRIOR day must not suppress today's run - only today's date counts.
  @{ date = '2026-07-27'; channel = 'telegram'; sentAt = '2026-07-27T08:31:00' } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $hbFile
  Assert (-not (Test-AlreadySentToday -Date '2026-07-28' -HeartbeatFile $hbFile)) `
    "yesterday's heartbeat must not suppress today's 08:30 (or 09:15 catch-up) run"

  # 4) -OnDemand must NEVER be suppressed, even if today's heartbeat already shows a successful
  # send - Alex explicitly asking again (/debrief, tray "Debrief now") is not the scheduler firing
  # twice, and must always produce a fresh run.
  @{ date = '2026-07-28'; channel = 'telegram'; sentAt = '2026-07-28T08:33:00' } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $hbFile
  Assert (-not (Test-AlreadySentToday -Date '2026-07-28' -HeartbeatFile $hbFile -OnDemand)) `
    "an explicit -OnDemand run must never be suppressed by an existing same-day heartbeat"

  # 5) A corrupt/unparseable heartbeat file must fail safe toward RUNNING (never silently swallow a
  # real morning's debrief because of a malformed file) rather than throwing out of the guard.
  Set-Content -Encoding UTF8 -Path $hbFile -Value 'not valid json {{{'
  Assert (-not (Test-AlreadySentToday -Date '2026-07-28' -HeartbeatFile $hbFile)) `
    "a corrupt heartbeat file must fail safe toward running the debrief, not toward suppressing it"

  Write-Host "debrief-catchup-idempotency: ALL PASS"
} finally {
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
