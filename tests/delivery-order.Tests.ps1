# tests/delivery-order.Tests.ps1 - F6: delivery must not be starved by later, non-essential steps.
# jarvis-debrief.ps1 does not lend itself to true runtime call-order testing (it executes a full
# debrief the instant it is dot-sourced / invoked - see tests/send-debrief.Tests.ps1 and
# tests/debrief-heartbeat.Tests.ps1, which both extract individual functions by source position
# rather than running the whole script). This test matches that same level of testability: a static
# source-position assertion pinning that the delivery call (Send-DebriefChannels, as of the
# pre-merge review of 6e2a148 - see tests/debrief-partial-channel-failure.Tests.ps1 for what that
# fixed) appears BEFORE the final "run ok" log write and BEFORE the heartbeat write, and that nothing
# unnecessary sits between the lateness stamp (note finalized) and the delivery call.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw

function IndexOfOrFail([string]$text, [string]$needle, [string]$label) {
  $i = $text.IndexOf($needle)
  Assert ($i -ge 0) "could not find '$label' in jarvis-debrief.ps1"
  return $i
}

$idxLatenessAppend = IndexOfOrFail $debriefSrc 'Add-Content -Encoding UTF8 -Path $note' 'lateness note stamp append'
$idxDeliveryCall    = IndexOfOrFail $debriefSrc 'Send-DebriefChannels -Channel $channel' 'delivery call'
$idxRunOkLog        = IndexOfOrFail $debriefSrc 'run ok (note written' 'final run-ok log line'
$idxHeartbeat       = IndexOfOrFail $debriefSrc 'Set-DebriefHeartbeat -Date $today' 'heartbeat write call'

# The note must be fully finalized (lateness stamp already applied, per design 8 - the user must
# receive a note that already carries the honesty stamp) BEFORE the delivery call runs.
Assert ($idxLatenessAppend -lt $idxDeliveryCall) "the lateness stamp must be appended to the note BEFORE the delivery call"

# Delivery must happen before the two remaining post-delivery bookkeeping writes, so a starved
# tail-end (earlier steps running long) cannot cost Alex the actual deliverable.
Assert ($idxDeliveryCall -lt $idxRunOkLog)  "the delivery call must happen before the final run-ok log write"
Assert ($idxDeliveryCall -lt $idxHeartbeat) "the delivery call must happen before the heartbeat write"

# Nothing unnecessary between "note ready to send" and "actually send it": the gap between the
# lateness stamp and the delivery call should be small - just the channel lookup, not another
# round of I/O (a generation call, another log write, etc). A generous but real bound: this text
# span should not itself contain another Add-Content/Out-File/Set-Content (i.e. no extra unrelated
# write sneaking in between "note is ready" and "send it").
$gap = $debriefSrc.Substring($idxLatenessAppend, $idxDeliveryCall - $idxLatenessAppend)
Assert (-not ([regex]::IsMatch($gap, 'Out-File|Set-Content|Write-ClaudeLog'))) `
  "no unnecessary write should sit between the note being finalized and the delivery call being reached (gap: $gap)"

# The run-ok log line and the heartbeat write must both be gated on at least one channel having
# genuinely succeeded (pre-merge review of 6e2a148) - a static guard that this doesn't regress back
# to an unconditional write regardless of $delivery.Sent.
Assert ($debriefSrc -match '(?s)if \(\$delivery\.Sent\.Count -gt 0\) \{.*?run ok \(note written.*?Set-DebriefHeartbeat -Date \$today') `
  "both the run-ok log line and the heartbeat write must be gated on \$delivery.Sent.Count -gt 0"
Assert ($debriefSrc -match '(?s)if \(\$delivery\.Errors\.Count -gt 0\) \{.*?throw') `
  "a delivery failure on any requested channel must still throw, so the outer catch logs a loud FAILED"

Write-Host "delivery-order: ALL PASS"
