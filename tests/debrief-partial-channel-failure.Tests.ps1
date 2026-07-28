# tests/debrief-partial-channel-failure.Tests.ps1 - pre-merge review of 6e2a148: in 'both'-channel
# mode, jarvis-debrief.ps1 used to call Send-DebriefTelegram then Send-Debrief back-to-back with NO
# per-channel try/catch, both inside ONE outer try block. If the first channel succeeded and the
# second then threw (e.g. an expired Gmail app password), the exception propagated straight past the
# run-ok log line AND the F3 heartbeat write for the ENTIRE run - so a day where Telegram genuinely
# delivered still logged "run FAILED" with no heartbeat at all. F8b's 09:15 catch-up trigger (whose
# only guard is "did ANY confirmed send happen today", via the heartbeat) would then find nothing and
# re-run the whole pipeline - resending the SAME debrief over the channel that had already delivered,
# exactly the duplicate-delivery bug class F8b's own commit message claims can never happen.
#
# This asserts Send-DebriefChannels (the pulled-out fix) attempts each requested channel
# independently and reports exactly which channel(s) truly sent and which failed, so the caller can
# heartbeat the successes regardless of a later channel's failure.
#
# Extraction pattern matches tests/debrief-heartbeat.Tests.ps1: jarvis-debrief.ps1 runs a full
# debrief the moment it is dot-sourced, so the function under test is lifted out by source
# extraction and defined in an isolated scope. Send-DebriefTelegram / Send-Debrief are stubbed here
# (never the real network/SMTP calls) - Send-DebriefChannels calls them by NAME, so whichever
# same-named function is in scope at call time is what actually runs.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Send-DebriefChannels \{.*?\n\}')
Assert ($fnMatch.Success) "could not extract Send-DebriefChannels from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

# 1) THE CORE REGRESSION SCENARIO: 'both' mode, Telegram succeeds, email throws. Telegram must still
# be reported as sent - the caller's own heartbeat write must not be starved by the later channel's
# failure.
function Send-DebriefTelegram { param($NotePath) }   # succeeds (no-op, no throw)
function Send-Debrief { param($NotePath, $ToAddress, $RunStart, $BootTime, [switch]$OnDemand) throw "simulated expired Gmail app password" }

$r = Send-DebriefChannels -Channel 'both' -NotePath 'irrelevant.md' -ToAddress 'alex@example.com'
Assert ($r.Sent -contains 'telegram') "Telegram must be reported as sent even though email failed"
Assert (-not ($r.Sent -contains 'email')) "email must NOT be reported as sent when it threw"
Assert ($r.Errors.Count -eq 1 -and $r.Errors[0] -match '^telegram: |^email: ') "the email failure must be reported as an error"
Assert ($r.Errors[0] -match '^email:') "the email failure must be attributed to the email channel specifically"

# 2) The mirror image: email succeeds, Telegram throws (e.g. an expired bot token). Email must
# still be reported sent.
function Send-DebriefTelegram { param($NotePath) throw "simulated Telegram 401" }
function Send-Debrief { param($NotePath, $ToAddress, $RunStart, $BootTime, [switch]$OnDemand) }   # succeeds

$r2 = Send-DebriefChannels -Channel 'both' -NotePath 'irrelevant.md' -ToAddress 'alex@example.com'
Assert ($r2.Sent -contains 'email') "email must be reported as sent even though Telegram failed"
Assert (-not ($r2.Sent -contains 'telegram')) "Telegram must NOT be reported as sent when it threw"
Assert ($r2.Errors.Count -eq 1 -and $r2.Errors[0] -match '^telegram:') "the Telegram failure must be attributed to the telegram channel specifically"

# 3) Both channels succeed (the ordinary 'both' happy path) - both reported sent, no errors.
function Send-DebriefTelegram { param($NotePath) }
function Send-Debrief { param($NotePath, $ToAddress, $RunStart, $BootTime, [switch]$OnDemand) }
$r3 = Send-DebriefChannels -Channel 'both' -NotePath 'irrelevant.md' -ToAddress 'alex@example.com'
Assert ($r3.Sent.Count -eq 2 -and ($r3.Sent -contains 'telegram') -and ($r3.Sent -contains 'email')) "both channels succeeding must report both as sent"
Assert ($r3.Errors.Count -eq 0) "no errors when both channels succeed"

# 4) Both channels fail - neither reported sent, both errors present (a full failure, unchanged from
# the pre-fix behaviour: no heartbeat, no partial "sent" claim, the whole run correctly logs FAILED).
function Send-DebriefTelegram { param($NotePath) throw "simulated Telegram 401" }
function Send-Debrief { param($NotePath, $ToAddress, $RunStart, $BootTime, [switch]$OnDemand) throw "simulated SMTP failure" }
$r4 = Send-DebriefChannels -Channel 'both' -NotePath 'irrelevant.md' -ToAddress 'alex@example.com'
Assert ($r4.Sent.Count -eq 0) "no channel must be reported sent when both fail"
Assert ($r4.Errors.Count -eq 2) "both failures must be reported"

# 5) Single-channel modes must only ever attempt the requested channel - a 'telegram'-only run must
# never touch the email sender (and vice versa), preserving the pre-existing single-channel
# behaviour untouched by this fix.
$script:emailCalled = $false
function Send-DebriefTelegram { param($NotePath) }
function Send-Debrief { param($NotePath, $ToAddress, $RunStart, $BootTime, [switch]$OnDemand) $script:emailCalled = $true }
$r5 = Send-DebriefChannels -Channel 'telegram' -NotePath 'irrelevant.md' -ToAddress 'alex@example.com'
Assert ($r5.Sent.Count -eq 1 -and $r5.Sent[0] -eq 'telegram') "'telegram' mode must report only telegram as sent"
Assert (-not $script:emailCalled) "'telegram' mode must never call the email sender"

$script:telegramCalled = $false
function Send-DebriefTelegram { param($NotePath) $script:telegramCalled = $true }
function Send-Debrief { param($NotePath, $ToAddress, $RunStart, $BootTime, [switch]$OnDemand) }
$r6 = Send-DebriefChannels -Channel 'email' -NotePath 'irrelevant.md' -ToAddress 'alex@example.com'
Assert ($r6.Sent.Count -eq 1 -and $r6.Sent[0] -eq 'email') "'email' mode must report only email as sent"
Assert (-not $script:telegramCalled) "'email' mode must never call the Telegram sender"

Write-Host "debrief-partial-channel-failure: ALL PASS"
