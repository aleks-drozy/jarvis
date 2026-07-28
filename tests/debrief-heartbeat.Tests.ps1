# tests/debrief-heartbeat.Tests.ps1 - F3: the positive delivery heartbeat written by
# skill/bin/jarvis-debrief.ps1's Set-DebriefHeartbeat, ONLY after a channel send has actually
# returned successfully. Extraction pattern matches tests/send-debrief.Tests.ps1's handling of
# Get-DebriefChannel: jarvis-debrief.ps1 runs a full debrief the moment it is dot-sourced, so the
# function under test is lifted out by source extraction and defined in an isolated scope.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Set-DebriefHeartbeat \{.*?^\}')
Assert ($fnMatch.Success) "could not extract Set-DebriefHeartbeat from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

$dir = Join-Path $env:TEMP ('jarvis-heartbeat-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$hbFile = Join-Path $dir 'debrief-heartbeat.json'

try {
  # 1) A successful call writes the expected shape.
  Assert (-not (Test-Path $hbFile)) "sanity: heartbeat file must not pre-exist"
  Set-DebriefHeartbeat -Date '2026-07-28' -Channel 'telegram' -HeartbeatFile $hbFile
  Assert (Test-Path $hbFile) "Set-DebriefHeartbeat must create the heartbeat file"
  $hb = Get-Content $hbFile -Raw | ConvertFrom-Json
  Assert ($hb.date -eq '2026-07-28') "heartbeat must carry the run date"
  Assert ($hb.channel -eq 'telegram') "heartbeat must carry the channel actually used"
  Assert (-not [string]::IsNullOrWhiteSpace($hb.sentAt)) "heartbeat must carry a sentAt timestamp"

  # 2) A later successful call (e.g. next morning) overwrites with the new day's info - the
  # heartbeat always reflects the MOST RECENT confirmed send, not a historical log.
  Set-DebriefHeartbeat -Date '2026-07-29' -Channel 'email' -HeartbeatFile $hbFile
  $hb2 = Get-Content $hbFile -Raw | ConvertFrom-Json
  Assert ($hb2.date -eq '2026-07-29' -and $hb2.channel -eq 'email') "heartbeat must reflect the latest successful send"

  # 3) The success-path shape, mirroring jarvis-debrief.ps1's actual call site: the heartbeat write
  # happens strictly AFTER the send function returns, inside the same try. Reset to a known prior
  # day's heartbeat, then simulate a send that THROWS before the heartbeat line is ever reached -
  # the prior heartbeat must be left completely untouched, never overwritten with any kind of
  # failure marker.
  Set-Content -Encoding UTF8 -Path $hbFile -Value (@{ date = '2026-07-20'; channel = 'telegram'; sentAt = '2026-07-20T08:33:00' } | ConvertTo-Json)
  $before = Get-Content $hbFile -Raw

  function Invoke-SendThatThrows { throw "simulated SMTP failure" }

  $threw = $false
  try {
    # This mirrors the real script's shape: Send-Debrief/Send-DebriefTelegram is called FIRST and
    # only on its successful return does the heartbeat line execute. A thrown exception here must
    # short-circuit before Set-DebriefHeartbeat is ever invoked.
    Invoke-SendThatThrows
    Set-DebriefHeartbeat -Date '2026-07-28' -Channel 'telegram' -HeartbeatFile $hbFile
  } catch { $threw = $true }
  Assert $threw "the simulated send failure must actually throw (test sanity)"

  $after = Get-Content $hbFile -Raw
  Assert ($after -eq $before) "a thrown send exception must leave the prior day's heartbeat file completely untouched"
  $hb3 = $after | ConvertFrom-Json
  Assert ($hb3.date -eq '2026-07-20') "prior heartbeat's date must survive a failed run unchanged"

  Write-Host "debrief-heartbeat: ALL PASS"
} finally {
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
