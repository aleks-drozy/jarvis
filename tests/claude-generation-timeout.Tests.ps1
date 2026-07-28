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

# --- pre-merge review of 6e2a148: three more gaps in this same function ---

# 4) Working-directory pinning: Start-Job in PS 5.1 does NOT inherit the caller's location, so an
# unpinned default JobScript would run 'claude' from whatever directory Start-Job happens to land in
# (empirically: Documents), silently broadening the agent's ambient scope - the identical gotcha
# telegram-chat.ps1 already guards against for the same Start-Job + claude pattern.
# Invoke-ClaudeGeneration must forward -WorkingDirectory into the job (as a THIRD positional
# argument, after $Prompt) so a JobScript that pins its own location (as the real default does)
# actually receives a real directory to pin to.
$testDir = Join-Path $env:TEMP ('jarvis-cwd-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testDir | Out-Null
try {
  $cwdResult = Invoke-ClaudeGeneration -Prompt 'irrelevant' -TimeoutSec 30 -WorkingDirectory $testDir -JobScript {
    param($p, $dir, $pidFile)
    if ($dir) { Set-Location -LiteralPath $dir -ErrorAction Stop }
    (Get-Location).Path
  }
  # Compare against $testDir resolved through the SAME Set-Location/Get-Location round-trip the job
  # itself does, not the raw $env:TEMP-built string. On some hosts (observed on the GitHub Actions
  # Windows runner, account "runneradmin") $env:TEMP is reported in 8.3 short-path form
  # (...\RUNNER~1\...) while Set-Location + Get-Location resolves and returns the long form
  # (...\runneradmin\...) for the identical real directory - a representation mismatch, not a
  # pinning failure. Round-tripping both sides through Set-Location neutralizes that regardless of
  # which form any given host's TEMP happens to use.
  Push-Location -LiteralPath $testDir
  $testDirResolved = (Get-Location).Path
  Pop-Location
  Assert ($cwdResult.TrimEnd('\') -ieq $testDirResolved.TrimEnd('\')) `
    "Invoke-ClaudeGeneration must forward -WorkingDirectory into the job so a pinning JobScript actually lands in it (got: $cwdResult, want: $testDirResolved)"
} finally {
  Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 5) Static guard: the REAL production default JobScript (not a test override) must itself pin its
# working directory via Set-Location BEFORE invoking claude - a regression here would silently
# reopen the ambient-scope gap even though test 4 above stays green (a substituted JobScript always
# supplies its own Set-Location, so it cannot catch a regression in the PRODUCTION default).
$defaultJobScriptMatch = [regex]::Match($debriefSrc, '(?s)\[scriptblock\]\$JobScript = \{(.*?)& claude')
Assert $defaultJobScriptMatch.Success "could not find the production default JobScript body up to its claude invocation"
Assert ($defaultJobScriptMatch.Groups[1].Value -match 'Set-Location') `
  "the production default JobScript in Invoke-ClaudeGeneration must pin its working directory (Set-Location) before invoking claude"

# 6) Output capture + orphan child-process tree-kill on timeout: a genuine overrun used to (a)
# discard whatever partial output the job had already produced - the exact failure category most in
# need of diagnosis - and (b) leave any child OS process the job spawned (the real shape: claude.exe
# as a child of the job host) running as an orphan, because Stop-Job only stops the job's OWN
# PowerShell host, never its descendants. This reproduces both with a genuine child process standing
# in for claude.exe (a real taskkill against a fake job host would prove nothing about tree-kill).
$fnMatch2 = [regex]::Match($debriefSrc, '(?ms)^function Write-ClaudeLog \{.*?\n\}')
Assert ($fnMatch2.Success) "could not extract Write-ClaudeLog from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch2.Value))

$logDir = Join-Path $env:TEMP ('jarvis-timeout-log-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir 'claude.log'
$childPid = $null
try {
  $threw2 = $false
  try {
    Invoke-ClaudeGeneration -Prompt 'irrelevant' -TimeoutSec 3 -LogPath $logPath -RunStamp '2026-07-28T08:30:00' -JobScript {
      param($p, $dir, $pidFile)
      # Stand-in for claude.exe: a genuine CHILD OS PROCESS, exactly the shape Stop-Job alone cannot
      # reach. Its PID is written into $pidFile - the SAME file the production JobScript uses for its
      # own PID - so the timeout branch's taskkill targets it directly; it is also streamed to stdout
      # (captured via Receive-Job, since jobs buffer output progressively even while still running)
      # so the test can confirm the partial output survived.
      $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden
      if ($pidFile) { Set-Content -LiteralPath $pidFile -Value $proc.Id -ErrorAction SilentlyContinue }
      Write-Output "CHILD_PID=$($proc.Id)"
      Start-Sleep -Seconds 30
      "should never be seen"
    }
  } catch { $threw2 = $true }
  Assert $threw2 "the simulated overrun must still throw (test sanity)"

  Assert (Test-Path $logPath) "a genuine timeout must still produce a claude log entry (partial output must not be discarded)"
  $logText = Get-Content -LiteralPath $logPath -Raw
  Assert ($logText -match 'TIMED OUT') "the timeout branch must log a diagnosable marker rather than discarding the run's diagnostics entirely"
  $childMatch = [regex]::Match($logText, 'CHILD_PID=(\d+)')
  Assert $childMatch.Success "the partial output produced before the timeout (CHILD_PID marker) must have been captured and written to the log"
  $childPid = [int]$childMatch.Groups[1].Value

  # Give Windows a moment to actually tear the process down after taskkill /T /F.
  $deadline = (Get-Date).AddSeconds(8)
  $stillAlive = $true
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { $stillAlive = $false; break }
    Start-Sleep -Milliseconds 250
  }
  Assert (-not $stillAlive) `
    "a timed-out job's child process (the claude.exe stand-in) must be tree-killed via taskkill, not left orphaned holding its inherited environment/OAuth token"
} finally {
  if ($childPid) { try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch { } }
  Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "claude-generation-timeout: ALL PASS"
