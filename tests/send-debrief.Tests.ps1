# tests/send-debrief.Tests.ps1 — mail-building only, no real send
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
Write-Host "send-debrief: ALL PASS"
