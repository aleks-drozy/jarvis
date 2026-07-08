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
Remove-Item $tmp -Force
Write-Host "send-debrief: ALL PASS"
