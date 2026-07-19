# tests/send-debrief.Tests.ps1 - mail-building only, no real send
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\send-debrief.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$tmp = Join-Path $env:TEMP 'jarvis-note-2026-07-08.md'
"---`nproject: jarvis`ntype: debrief`n---`n`nGood morning, Sir. - 2026-07-08`n`nTODAY'S FOCUS`n  1. ship" | Set-Content -Encoding UTF8 $tmp
$mail = Build-DebriefMail -NotePath $tmp -ToAddress 'me@example.com'
Assert ($mail.To -eq 'me@example.com') "To must equal owner"
Assert ($mail.Subject -match '2026-07-08') "subject carries the date"
Assert ($mail.Body -match 'TODAY') "body carries the note"
Assert ($mail.Body.StartsWith('Good morning')) "frontmatter must be stripped (body starts at greeting)"
Assert (-not ($mail.Body -match 'project: jarvis')) "frontmatter fields must not appear in the email"

# Safety rule 2 (self-only): Send-Debrief MUST refuse any non-owner recipient, and must do so
# before reading credentials or touching the network. A bogus note path guarantees that, if the
# guard were absent, we'd fail at file-read rather than ever attempting a real Send-MailMessage.
$bogusNote = Join-Path $env:TEMP 'jarvis-nonexistent-note-do-not-create.md'
if (Test-Path $bogusNote) { Remove-Item $bogusNote -Force }
$threw = $false; $guardMsg = ''
try { Send-Debrief -NotePath $bogusNote -ToAddress 'attacker@example.com' }
catch { $threw = $true; $guardMsg = $_.Exception.Message }
Assert $threw "Send-Debrief must refuse a non-owner recipient (Safety rule 2)"
Assert ($guardMsg -match 'self-only|Safety rule 2') "refusal must cite the self-only safety rule (got: $guardMsg)"

# Late-stamp honesty (Get-LatenessNote): a catch-up run must name itself and its cause,
# never masquerade as an on-time morning (design 8: "note tagged generated late HH:MM").
$onTime = Get-LatenessNote -RunStart (Get-Date '2026-07-13 08:30:03') -BootTime (Get-Date '2026-07-13 07:00:00')
Assert ($null -eq $onTime) "on-time run (08:30:03) must produce no stamp"
$inGrace = Get-LatenessNote -RunStart (Get-Date '2026-07-13 08:39:00') -BootTime (Get-Date '2026-07-13 07:00:00')
Assert ($null -eq $inGrace) "run inside the 10-min grace window must produce no stamp"
$asleep = Get-LatenessNote -RunStart (Get-Date '2026-07-14 10:04:31') -BootTime (Get-Date '2026-07-14 07:00:00')
Assert ($asleep -match '10:04') "late stamp must carry the actual generation time"
Assert ($asleep -match 'asleep|wake timer') "boot-before-08:30 lateness must blame sleep/logon, not shutdown"
$off = Get-LatenessNote -RunStart (Get-Date '2026-07-14 10:04:31') -BootTime (Get-Date '2026-07-14 09:58:29')
Assert ($off -match 'powered off|shut') "boot-after-08:30 lateness must name the shutdown"
Assert ($off -match '10:04') "late stamp must carry the actual generation time"

# An ON-DEMAND run (Telegram /debrief, tray "Debrief now") is not the 08:30 run and must never be judged
# against it. Alex asked for it at 10:40, so "late catch-up - the machine was powered off at 08:30" is a
# false claim in his own notes. Found 2026-07-16.
$onDemand = Get-LatenessNote -RunStart (Get-Date '2026-07-16 10:40:00') -BootTime (Get-Date '2026-07-16 09:58:00') -OnDemand
Assert ($null -eq $onDemand) "an on-demand run must never be stamped late - he asked for it just now"
# ...but the DEFAULT still judges. A forgotten flag then yields a spurious stamp (harmless) rather than
# silently dropping the honesty stamp, which is the whole reason it exists.
$stillJudged = Get-LatenessNote -RunStart (Get-Date '2026-07-16 10:40:00') -BootTime (Get-Date '2026-07-16 09:58:00')
Assert ($null -ne $stillJudged) "default (no -OnDemand) must STILL judge lateness - fail loud, never silent"

# Late subject: the email itself must be visibly flagged, so a late morning is loud in the inbox
$mailLate = Build-DebriefMail -NotePath $tmp -ToAddress 'me@example.com' -RunStart (Get-Date '2026-07-08 10:04:31') -BootTime (Get-Date '2026-07-08 09:58:00')
Assert ($mailLate.Subject -match '\(late 10:04\)') "late run must be visible in the subject (got: $($mailLate.Subject))"
$mailOn = Build-DebriefMail -NotePath $tmp -ToAddress 'me@example.com' -RunStart (Get-Date '2026-07-08 08:30:05') -BootTime (Get-Date '2026-07-08 07:00:00')
Assert (-not ($mailOn.Subject -match 'late')) "on-time run must not be flagged late"
# the email path must honour -OnDemand too, or a requested briefing arrives subject-tagged "(late)"
$mailOnDemand = Build-DebriefMail -NotePath $tmp -ToAddress 'me@example.com' -RunStart (Get-Date '2026-07-08 10:04:31') -BootTime (Get-Date '2026-07-08 09:58:00') -OnDemand
Assert (-not ($mailOnDemand.Subject -match 'late')) "on-demand run must not be flagged late in the subject (got: $($mailOnDemand.Subject))"

Remove-Item $tmp -Force

# --- Fix 3: Get-DebriefChannel had the same fail-open value parsing as Test-ChatEnabled (the two were
# --- copied from each other): '(telegram|email|both)\b' matched the PREFIX of a malformed value, so
# --- 'telegram-only' was silently accepted as 'telegram'. A value its author did not spell correctly
# --- must fall back to the documented default, not be guessed at.
# --- jarvis-debrief.ps1 runs a full debrief the moment it is dot-sourced, so the function is lifted
# --- out by source extraction and defined in an isolated scope with its $vault in place. Extraction
# --- failing is itself an assertion: if the function is renamed or reshaped, this test says so.
$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Get-DebriefChannel \{.*?^\}')
Assert ($fnMatch.Success) "could not extract Get-DebriefChannel from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

$vault = Join-Path $env:TEMP ('jarvis-debrief-channel-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $vault | Out-Null
try {
  # valid values are unchanged
  foreach ($valid in @('telegram','email','both')) {
    Set-Content -Encoding UTF8 (Join-Path $vault 'CONFIG.md') "- modules:`n  debrief_delivery: $valid"
    Assert ((Get-DebriefChannel) -eq $valid) "a valid debrief_delivery '$valid' must still be honoured"
  }
  # ...including the casing and trailing-whitespace tolerance the old regex had
  Set-Content -Encoding UTF8 (Join-Path $vault 'CONFIG.md') "- modules:`n  debrief_delivery: Telegram  "
  Assert ((Get-DebriefChannel) -eq 'telegram') "casing and trailing whitespace must still resolve to a valid channel"

  # malformed values fall back to the default instead of matching on a prefix
  foreach ($bad in @('telegram-only','email-digest','both-ways','telegram and email','tele','none','')) {
    Set-Content -Encoding UTF8 (Join-Path $vault 'CONFIG.md') "- modules:`n  debrief_delivery: $bad"
    Assert ((Get-DebriefChannel) -eq 'email') "malformed debrief_delivery '$bad' must fall back to the default 'email', got '$(Get-DebriefChannel)'"
  }
  # absent key and unreadable file still default
  Set-Content -Encoding UTF8 (Join-Path $vault 'CONFIG.md') "- modules:`n  telegram: on"
  Assert ((Get-DebriefChannel) -eq 'email') "an absent debrief_delivery key must default to email"
  Remove-Item (Join-Path $vault 'CONFIG.md') -Force
  Assert ((Get-DebriefChannel) -eq 'email') "a missing CONFIG.md must default to email"
} finally {
  Remove-Item $vault -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "send-debrief: ALL PASS"
