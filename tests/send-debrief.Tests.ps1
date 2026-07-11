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

Remove-Item $tmp -Force
Write-Host "send-debrief: ALL PASS"
