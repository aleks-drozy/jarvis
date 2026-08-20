# tests/debrief-failure-alert.Tests.ps1 - 2026-08-20: the 08-09..08-15 six-day 403 outage proved
# the fail-closed design (F1/F6/etc.) works exactly as built - every failed run correctly logged
# "run FAILED" - but nothing pushed that off-machine, so six days of failures reached Alex's phone as
# silence, not as a message (see KNOWN_ISSUES.md / DECISIONS.md 2026-08-20). This asserts
# Send-FailureAlert (skill/bin/jarvis-debrief.ps1): fires only at 2+ consecutive trailing "run
# FAILED" lines, resets on "run ok"/"run skipped", dedupes same-day, attempts both channels
# independently, never throws out of its own catch, and never writes a log line the health parser
# could mistake for a "run ..." record.
#
# Extraction pattern matches tests/debrief-partial-channel-failure.Tests.ps1: jarvis-debrief.ps1 runs
# a full debrief the moment it is dot-sourced, so the function under test is lifted out by source
# extraction and defined in an isolated scope. Send-Telegram / Send-Debrief are stubbed here - never
# the real network/SMTP calls - Send-FailureAlert calls them by NAME, so whichever same-named
# function is in scope at call time is what actually runs.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Send-FailureAlert \{.*?^\}')
Assert ($fnMatch.Success) "could not extract Send-FailureAlert from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

$today = Get-Date -Format 'yyyy-MM-dd'
$dir = Join-Path $env:TEMP ('jarvis-failure-alert-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function New-RunLog {
  param([string[]]$Lines)
  $f = Join-Path $dir ('runlog-' + [guid]::NewGuid().ToString('N') + '.log')
  if ($Lines) { $Lines | Set-Content -Encoding UTF8 -Path $f }
  else { New-Item -ItemType File -Path $f | Out-Null }
  return $f
}

try {
  # 1) One consecutive failure only - no alert. A single bad run is the 09:15 catch-up's job, not a
  # human's.
  $script:telegramCalled = $false; $script:emailCalled = $false
  function Send-Telegram { param($Text) $script:telegramCalled = $true }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailCalled = $true }
  $log1 = New-RunLog @("$today`T08:30:00 run start", "$today`T08:30:05 run FAILED: boom")
  Send-FailureAlert -RunLog $log1 -ErrorMessage 'boom' -ToAddress 'alex@example.com'
  Assert (-not $script:telegramCalled) "1 consecutive failure must not alert over telegram"
  Assert (-not $script:emailCalled) "1 consecutive failure must not alert over email"
  Assert (-not ((Get-Content $log1 -Raw) -match 'alert sent|alert FAILED')) "1 consecutive failure must not write any alert line"

  # 2) Two consecutive failures - alert fires over both channels, and an "alert sent" line is logged.
  $script:telegramCalled = $false; $script:emailCalled = $false
  function Send-Telegram { param($Text) $script:telegramCalled = $true }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailCalled = $true }
  $log2 = New-RunLog @(
    "$today`T08:30:00 run start", "$today`T08:30:05 run FAILED: first",
    "$today`T09:15:00 run start", "$today`T09:15:05 run FAILED: second")
  Send-FailureAlert -RunLog $log2 -ErrorMessage 'second' -ToAddress 'alex@example.com'
  Assert $script:telegramCalled "2 consecutive failures must alert over telegram"
  Assert $script:emailCalled "2 consecutive failures must alert over email"
  Assert ((Get-Content $log2 -Raw) -match 'alert sent \(2 consecutive failures\)') "must log an 'alert sent (2 consecutive failures)' line"

  # 3) A "run ok" line resets the count - a failure BEFORE a prior success does not accumulate with a
  # single failure after it.
  $script:telegramCalled = $false; $script:emailCalled = $false
  function Send-Telegram { param($Text) $script:telegramCalled = $true }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailCalled = $true }
  $log3 = New-RunLog @(
    "$today`T08:30:00 run start", "$today`T08:30:05 run FAILED: old1",
    "$today`T08:31:00 run start", "$today`T08:31:05 run FAILED: old2",
    "$today`T08:32:00 run start", "$today`T08:32:05 run ok (note written 08:32, via telegram)",
    "$today`T09:15:00 run start", "$today`T09:15:05 run FAILED: new")
  Send-FailureAlert -RunLog $log3 -ErrorMessage 'new' -ToAddress 'alex@example.com'
  Assert (-not $script:telegramCalled) "a 'run ok' must reset the consecutive-failure count"
  Assert (-not $script:emailCalled) "a 'run ok' must reset the consecutive-failure count"

  # 3b) Likewise a "run skipped" line (F8b catch-up no-op / stale-lock skip) resets the count.
  $script:telegramCalled = $false; $script:emailCalled = $false
  function Send-Telegram { param($Text) $script:telegramCalled = $true }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailCalled = $true }
  $log3b = New-RunLog @(
    "$today`T08:30:00 run FAILED: old1",
    "$today`T08:31:00 run FAILED: old2",
    "$today`T08:32:00 run skipped: today's debrief already sent",
    "$today`T09:15:00 run FAILED: new")
  Send-FailureAlert -RunLog $log3b -ErrorMessage 'new' -ToAddress 'alex@example.com'
  Assert (-not $script:telegramCalled) "a 'run skipped' must reset the consecutive-failure count"

  # 4) Same-day dedupe: a run log that already has today's "alert sent" line must not alert again -
  # the 08:30 and 09:15 triggers must not double-alert on the same bad morning.
  $script:telegramCalled = $false; $script:emailCalled = $false
  function Send-Telegram { param($Text) $script:telegramCalled = $true }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailCalled = $true }
  $log4 = New-RunLog @(
    "$today`T08:30:00 run FAILED: first",
    "$today`T08:30:05 run FAILED: second",
    "$today`T08:30:06 alert sent (2 consecutive failures)",
    "$today`T09:15:00 run FAILED: third")
  Send-FailureAlert -RunLog $log4 -ErrorMessage 'third' -ToAddress 'alex@example.com'
  Assert (-not $script:telegramCalled) "same-day dedupe must suppress a second alert"
  Assert (-not $script:emailCalled) "same-day dedupe must suppress a second alert"

  # 5) One channel throwing must not stop the other from being attempted - mirrors
  # Send-DebriefChannels' own per-channel isolation.
  $script:telegramCalled = $false; $script:emailCalled = $false
  function Send-Telegram { param($Text) $script:telegramCalled = $true; throw "simulated Telegram 401" }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailCalled = $true }
  $log5 = New-RunLog @("$today`T08:30:00 run FAILED: a", "$today`T09:15:00 run FAILED: b")
  Send-FailureAlert -RunLog $log5 -ErrorMessage 'b' -ToAddress 'alex@example.com'
  Assert $script:telegramCalled "telegram must still be attempted even though it throws"
  Assert $script:emailCalled "email must still be attempted when telegram throws"
  Assert ((Get-Content $log5 -Raw) -match 'alert sent') "one channel succeeding must still count as 'alert sent'"

  # 6) Both channels throwing must never let the exception escape Send-FailureAlert itself, and must
  # log an 'alert FAILED' line naming the reason instead of an 'alert sent' line.
  function Send-Telegram { param($Text) throw "simulated Telegram 401" }
  function Send-Debrief { param($NotePath, $ToAddress) throw "simulated SMTP failure" }
  $log6 = New-RunLog @("$today`T08:30:00 run FAILED: a", "$today`T09:15:00 run FAILED: b")
  $threw = $false
  try { Send-FailureAlert -RunLog $log6 -ErrorMessage 'b' -ToAddress 'alex@example.com' } catch { $threw = $true }
  Assert (-not $threw) "Send-FailureAlert must never throw even when every channel fails"
  Assert ((Get-Content $log6 -Raw) -match 'alert FAILED: telegram: simulated Telegram 401; email: simulated SMTP failure') `
    "must log 'alert FAILED' naming both channel failures when neither channel sends"

  # 7) Alert log lines must be invisible to the health parser's line-format convention
  # (app/lib/livestate.js RUN_LINE_RE: "^(\S+)\s+run (start|ok|FAILED)\b") - i.e. must NOT begin with
  # "run " - and must also be invisible to this function's OWN consecutive-failure walk (already
  # exercised implicitly by test 2, whose "alert sent" line did not get counted as anything in test 4
  # above; asserted directly here too).
  $runLinePattern = '^\S+\s+run (start|ok|FAILED)\b'
  foreach ($line in (Get-Content $log2)) {
    if ($line -match 'alert sent|alert FAILED') {
      Assert (-not ($line -match $runLinePattern)) "alert line '$line' must not match the health-parser's run-line pattern"
    }
  }

  # 8) Message content: contains the consecutive-failure count and a truncated (<=300 char) error
  # snippet, and is delivered unchanged to both channels.
  $script:telegramText = $null; $script:emailNoteContent = $null
  function Send-Telegram { param($Text) $script:telegramText = $Text }
  function Send-Debrief { param($NotePath, $ToAddress) $script:emailNoteContent = (Get-Content -LiteralPath $NotePath -Raw) }
  $longErr = 'X' * 500
  $log8 = New-RunLog @("$today`T08:30:00 run FAILED: a", "$today`T09:15:00 run FAILED: b")
  Send-FailureAlert -RunLog $log8 -ErrorMessage $longErr -ToAddress 'alex@example.com'
  Assert ($script:telegramText -match 'FAILED 2 consecutive runs') "alert text must state the consecutive-failure count"
  Assert ($script:telegramText -match ('X' * 300)) "alert text must contain the (truncated) error snippet"
  Assert (-not ($script:telegramText -match ('X' * 301))) "error snippet must be truncated to 300 chars, not the full message"
  Assert ($script:telegramText -eq $script:emailNoteContent.TrimEnd("`r","`n")) "the same fixed message must be sent over both channels"

  Write-Host "debrief-failure-alert: ALL PASS"
} finally {
  Remove-Item -Recurse -Force -Path $dir -ErrorAction SilentlyContinue
}
