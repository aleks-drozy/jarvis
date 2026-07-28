# tests/claude-generation-timeout.Tests.ps1 - F5: the Claude call inside jarvis-debrief.ps1 has no
# timeout of its own; a slow/hung call used to be stopped only by Windows's hard ExecutionTimeLimit
# kill (scripts/register-task.ps1), which bypasses this script's own try/catch/finally entirely.
# Invoke-ClaudeGeneration wraps the call in Start-Job + Wait-Job -Timeout (mirroring the pattern
# already proven in skill/bin/telegram-chat.ps1 ~line 793) so an overrun throws a clear,
# timeout-specific exception that the wrapping script's own catch block can log as "run FAILED".
#
# Extraction pattern matches tests/debrief-heartbeat.Tests.ps1 / send-debrief.Tests.ps1:
# jarvis-debrief.ps1 runs a full debrief the moment it is dot-sourced, so the function under test is
# lifted out by source extraction and defined in an isolated scope.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Invoke-ClaudeGeneration \{.*?\n\}')
Assert ($fnMatch.Success) "could not extract Invoke-ClaudeGeneration from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

# 1) A call that finishes well within the timeout must return its output normally, no throw - this
# is the everyday path and must stay untouched by the timeout machinery.
$fast = Invoke-ClaudeGeneration -Prompt 'irrelevant' -TimeoutSec 30 -JobScript {
  param($p)
  "fake claude output for $p"
}
Assert ($fast -match 'fake claude output for irrelevant') "a fast job must return its real output unchanged (got: $fast)"

# 2) A call that would exceed the timeout must throw a TIMEOUT-SPECIFIC exception (not just any
# exception), reaching the wrapping script's own catch block. A very short -TimeoutSec (not the real
# 25-minute production default) keeps this test fast - the job itself sleeps a bit longer than that.
$threw = $false; $msg = ''
try {
  Invoke-ClaudeGeneration -Prompt 'irrelevant' -TimeoutSec 2 -JobScript {
    param($p)
    Start-Sleep -Seconds 8
    "should never be seen"
  }
} catch { $threw = $true; $msg = $_.Exception.Message }
Assert $threw "a job exceeding -TimeoutSec must throw"
Assert ($msg -match 'exceeded' -and $msg -match 'timeout') "the exception must be timeout-specific so it is diagnosable (got: $msg)"

# 3) The timeout value actually reported in the message must reflect what was configured, in
# minutes - so a stranger reading a "run FAILED" log line knows what limit was hit without having to
# go read the source.
Assert ($msg -match '\dm timeout') "the exception message must state the timeout in minutes (got: $msg)"

Write-Host "claude-generation-timeout: ALL PASS"
