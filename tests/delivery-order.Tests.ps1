# tests/delivery-order.Tests.ps1 - F6: delivery must not be starved by later, non-essential steps.
# jarvis-debrief.ps1 does not lend itself to true runtime call-order testing (it executes a full
# debrief the instant it is dot-sourced / invoked - see tests/send-debrief.Tests.ps1 and
# tests/debrief-heartbeat.Tests.ps1, which both extract individual functions by source position
# rather than running the whole script). This test matches that same level of testability: a static
# source-position assertion pinning that the delivery calls (Send-DebriefTelegram / Send-Debrief)
# appear BEFORE the final "run ok" log write and BEFORE the heartbeat write, and that nothing
# unnecessary sits between the lateness stamp (note finalized) and the send calls.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw

function IndexOfOrFail([string]$text, [string]$needle, [string]$label) {
  $i = $text.IndexOf($needle)
  Assert ($i -ge 0) "could not find '$label' in jarvis-debrief.ps1"
  return $i
}

$idxLatenessAppend = IndexOfOrFail $debriefSrc 'Add-Content -Encoding UTF8 -Path $note' 'lateness note stamp append'
$idxTelegramSend    = IndexOfOrFail $debriefSrc 'Send-DebriefTelegram -NotePath $note' 'Telegram delivery call'
$idxEmailSend       = IndexOfOrFail $debriefSrc 'Send-Debrief -NotePath $note' 'email delivery call'
$idxRunOkLog        = IndexOfOrFail $debriefSrc 'run ok (note written' 'final run-ok log line'
$idxHeartbeat       = IndexOfOrFail $debriefSrc 'Set-DebriefHeartbeat -Date $today' 'heartbeat write call'

# The note must be fully finalized (lateness stamp already applied, per design 8 - the user must
# receive a note that already carries the honesty stamp) BEFORE either delivery call runs.
Assert ($idxLatenessAppend -lt $idxTelegramSend) "the lateness stamp must be appended to the note BEFORE the Telegram send"
Assert ($idxLatenessAppend -lt $idxEmailSend)    "the lateness stamp must be appended to the note BEFORE the email send"

# Delivery must happen before the two remaining post-delivery bookkeeping writes, so a starved
# tail-end (earlier steps running long) cannot cost Alex the actual deliverable.
Assert ($idxTelegramSend -lt $idxRunOkLog)  "Telegram delivery must happen before the final run-ok log write"
Assert ($idxEmailSend -lt $idxRunOkLog)     "email delivery must happen before the final run-ok log write"
Assert ($idxTelegramSend -lt $idxHeartbeat) "Telegram delivery must happen before the heartbeat write"
Assert ($idxEmailSend -lt $idxHeartbeat)    "email delivery must happen before the heartbeat write"

# Nothing unnecessary between "note ready to send" and "actually send it": the gap between the
# lateness stamp and the first delivery call should be small - just the channel lookup, not another
# round of I/O (a generation call, another log write, etc). A generous but real bound: this text
# span should not itself contain another Add-Content/Out-File/Set-Content (i.e. no extra unrelated
# write sneaking in between "note is ready" and "send it").
$gap = $debriefSrc.Substring($idxLatenessAppend, ([Math]::Min($idxTelegramSend, $idxEmailSend)) - $idxLatenessAppend)
Assert (-not ([regex]::IsMatch($gap, 'Out-File|Set-Content|Write-ClaudeLog'))) `
  "no unnecessary write should sit between the note being finalized and the first delivery call being reached (gap: $gap)"

Write-Host "delivery-order: ALL PASS"
