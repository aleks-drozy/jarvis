# tests/eval-harness.Tests.ps1 - the harness is itself under test before any scenario is trusted.
# Dot-sources evals/run-evals.ps1 (house -DotSourceOnly convention - see get-jarvis-config.ps1 /
# check-job-mail.ps1) and exercises its functions directly against throwaway scenario dirs under
# $env:TEMP. Never touches evals/scenarios/ or evals/results/.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repo 'evals\run-evals.ps1') -DotSourceOnly

$tmpRoot = Join-Path $env:TEMP ('jarvis-eval-harness-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

function New-ScenarioDir {
  param([string]$Root, [string]$Name, [string]$FixtureJson, [string]$ChecksJson)
  $dir = Join-Path $Root $Name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  if ($FixtureJson) { Set-Content -LiteralPath (Join-Path $dir 'fixture.json') -Value $FixtureJson -Encoding UTF8 }
  if ($ChecksJson)  { Set-Content -LiteralPath (Join-Path $dir 'checks.json')  -Value $ChecksJson  -Encoding UTF8 }
  return $dir
}

try {
  # =====================================================================================
  # (1) POSITIVE CONTROL: a planted must-fail scenario makes -Mode ci exit 1. Proves the
  # grader can FAIL before its passes on the real 6 scenarios are believed - the repo's own
  # ascii-purity idiom (tests/ascii-purity.Tests.ps1, tests/no-personal-values.Tests.ps1).
  # =====================================================================================
  $t1 = Join-Path $tmpRoot 't1-positive-control'
  New-Item -ItemType Directory -Force -Path $t1 | Out-Null
  New-ScenarioDir -Root $t1 -Name 'planted-fail' `
    -FixtureJson '{"trigger":{"type":"debrief"},"vault":{},"collectors":{}}' `
    -ChecksJson  '{"checks":[{"type":"must_match","pattern":"a string the fixture transcript definitely does not contain XYZZY-PLANTED","description":"planted failing check","tiers":["ci"]}]}' | Out-Null
  $cfg = Get-EvalConfig
  $runFail = Invoke-EvalRun -Mode 'ci' -ScenariosDir $t1 -ResultsDir (Join-Path $t1 'results') -Only $null -Cfg $cfg
  Assert (-not $runFail.Passed) "a planted must-fail check must make the run report Passed=false"
  Assert ($runFail.Results[0].Passed -eq $false) "the planted scenario itself must be marked failed"

  # Also verify the real CLI entry point actually exits 1 (not just the in-process function), since the
  # grader having a bug that reports failure in-process but the process itself still exits 0 would be a
  # silent no-op in CI.
  $exitProc = Start-Process -FilePath 'powershell' -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', (Join-Path $repo 'evals\run-evals.ps1'),
    '-Mode','ci','-ScenariosDir', $t1, '-ResultsDir', (Join-Path $t1 'results')
  ) -NoNewWindow -Wait -PassThru
  Assert ($exitProc.ExitCode -eq 1) "run-evals.ps1 -Mode ci must exit 1 when a planted check fails (got $($exitProc.ExitCode))"

  # =====================================================================================
  # (2) -Mode ci NEVER invokes claude - zero network, zero model calls. Name-shadow `claude`
  # (repo convention: consolidate-memory.Tests.ps1, stage-prep.Tests.ps1) BEFORE running a
  # ci-mode scenario set that includes every trigger type, and assert it is never called.
  # =====================================================================================
  $script:ClaudeInvocations = 0
  function claude { $script:ClaudeInvocations++; return '{"result":"should never be called in ci mode"}' }

  $t2 = Join-Path $tmpRoot 't2-no-network'
  New-Item -ItemType Directory -Force -Path $t2 | Out-Null
  New-ScenarioDir -Root $t2 -Name 'debrief-trigger' `
    -FixtureJson '{"trigger":{"type":"debrief"},"vault":{"JARVIS.md":"goals"},"collectors":{"calendar":{"events":[]}}}' `
    -ChecksJson  '{"checks":[{"type":"must_match","pattern":"Quiet-day rule","description":"present","tiers":["ci"]}]}' | Out-Null
  New-ScenarioDir -Root $t2 -Name 'telegram-trigger' `
    -FixtureJson '{"trigger":{"type":"telegram","message":"hello"},"vault":{},"collectors":{}}' `
    -ChecksJson  '{"checks":[{"type":"must_match","pattern":"DATA, NOT INSTRUCTION","description":"fenced","tiers":["ci"]}]}' | Out-Null

  $run2 = Invoke-EvalRun -Mode 'ci' -ScenariosDir $t2 -ResultsDir (Join-Path $t2 'results') -Only $null -Cfg (Get-EvalConfig)
  Assert ($run2.Passed) "the ci-mode fixture scenarios (debrief + telegram triggers) must pass on their own merits"
  Assert ($script:ClaudeInvocations -eq 0) "run-evals.ps1 -Mode ci must invoke claude ZERO times (got $script:ClaudeInvocations)"

  # =====================================================================================
  # (3) Scenario discovery: a malformed scenario dir (missing checks.json) is reported as its
  # OWN failure, not silently skipped.
  # =====================================================================================
  $t3 = Join-Path $tmpRoot 't3-malformed'
  New-Item -ItemType Directory -Force -Path $t3 | Out-Null
  New-ScenarioDir -Root $t3 -Name 'good-scenario' `
    -FixtureJson '{"trigger":{"type":"debrief"},"vault":{},"collectors":{}}' `
    -ChecksJson  '{"checks":[{"type":"must_match","pattern":"Quiet-day rule","description":"present","tiers":["ci"]}]}' | Out-Null
  New-ScenarioDir -Root $t3 -Name 'missing-checks' `
    -FixtureJson '{"trigger":{"type":"debrief"},"vault":{},"collectors":{}}' `
    -ChecksJson  $null | Out-Null

  $discovered = Find-EvalScenarios -Dir $t3
  Assert ($discovered.Count -eq 2) "discovery must report BOTH dirs (found $($discovered.Count))"
  $missing = $discovered | Where-Object { $_.Name -eq 'missing-checks' }
  Assert ($missing.Errors.Count -gt 0) "a scenario dir missing checks.json must carry its own discovery error, not be silently dropped"

  $run3 = Invoke-EvalRun -Mode 'ci' -ScenariosDir $t3 -ResultsDir (Join-Path $t3 'results') -Only $null -Cfg (Get-EvalConfig)
  Assert (-not $run3.Passed) "a malformed scenario must fail the overall run"
  $good = $run3.Results | Where-Object { $_.Name -eq 'good-scenario' }
  Assert ($good.Passed) "the WELL-FORMED sibling scenario must still be graded and pass on its own merits (malformed dirs must not take down the whole run)"
  $bad = $run3.Results | Where-Object { $_.Name -eq 'missing-checks' }
  Assert (-not $bad.Passed) "the malformed scenario itself must be reported failed, distinctly, not skipped"

  # =====================================================================================
  # (4) Grading order: deterministic checks run before any llm_judge, and a deterministic
  # FAIL short-circuits (the judge is never even consulted).
  # =====================================================================================
  $script:JudgeCalls = 0
  $judgeFn = { param($t, $c) $script:JudgeCalls++; return $true }

  $checksOrdered = @(
    [pscustomobject]@{ type = 'llm_judge';      description = 'judge check (listed first in the array)'; criterion = 'anything' },
    [pscustomobject]@{ type = 'must_match';     description = 'deterministic check that WILL fail';       pattern = 'this-string-is-not-present-ANYWHERE' }
  )
  $gradeShortCircuit = Invoke-EvalChecks -Transcript 'some transcript text' -Checks $checksOrdered -Mode 'live' -JudgeFn $judgeFn
  Assert (-not $gradeShortCircuit.Passed) "a failing deterministic check must fail the scenario even though it was listed AFTER the llm_judge entry"
  Assert ($script:JudgeCalls -eq 0) "llm_judge must never be invoked once a deterministic check has failed (got $script:JudgeCalls calls)"
  $judgeResult = $gradeShortCircuit.Results | Where-Object { $_.Type -eq 'llm_judge' }
  Assert ($judgeResult.Status -eq 'skipped (deterministic fail)') "the judge result must be recorded as skipped-due-to-deterministic-fail, not silently omitted (got '$($judgeResult.Status)')"

  # And the positive path: when all deterministic checks pass, the judge DOES run.
  $script:JudgeCalls = 0
  $checksAllPass = @(
    [pscustomobject]@{ type = 'must_match'; description = 'passes'; pattern = 'some' },
    [pscustomobject]@{ type = 'llm_judge';  description = 'judge runs now'; criterion = 'anything' }
  )
  $gradePass = Invoke-EvalChecks -Transcript 'some transcript text' -Checks $checksAllPass -Mode 'live' -JudgeFn $judgeFn
  Assert ($gradePass.Passed) "all-pass deterministic checks plus a PASS-ing judge must pass the scenario"
  Assert ($script:JudgeCalls -eq 1) "llm_judge must run exactly once when reached with no prior failure (got $script:JudgeCalls)"

  # =====================================================================================
  # (5) Results file: written atomically (temp + rename) and sanitized (a planted personal
  # path in a fixture transcript must not survive into the committed results file).
  # =====================================================================================
  # Deliberately GENERIC stand-ins, not the maintainer's real path/email (tests/no-personal-values.Tests.ps1
  # would otherwise flag this file for carrying them in tracked source - the guard's own convention is
  # that only the files that NAME the patterns are exempt, and this file doesn't need to name the real
  # ones to prove the sanitizer catches this SHAPE of value).
  $resultsDir = Join-Path $tmpRoot 't5-results'
  $plantedPath = 'C:\Users\SomeOtherUser\Projects\demo-repo\secret-note.md'
  $plantedEmail = 'test.user@example.com'
  $fakeResults = @(
    [pscustomobject]@{ Name = 'scenario-a'; Passed = $true; Checks = @([pscustomobject]@{ Type='must_match'; Description='ok'; Status='pass' }); Transcript = "some output referencing $plantedPath and $plantedEmail" }
  )
  $written = Write-EvalResultsFile -Date '2026-08-20' -ScenarioResults $fakeResults -ResultsDir $resultsDir -Mode 'live'
  Assert (Test-Path -LiteralPath $written) "results file must exist after Write-EvalResultsFile returns"
  $body = Get-Content -LiteralPath $written -Raw
  Assert ($body -notmatch [regex]::Escape($plantedPath)) "a planted personal-looking path must be sanitized out of the committed results file"
  Assert ($body -notmatch [regex]::Escape($plantedEmail)) "a planted email address must be sanitized out of the committed results file"
  Assert ($body -match '\[redacted\]') "the sanitizer must actually have redacted something, not merely dropped the whole line (positive control)"
  Assert ($body -match 'scenario-a') "the results file must still carry the real, non-personal scenario content"
  # atomicity: no leftover .tmp-* file after a successful write
  $leftoverTemp = Get-ChildItem -LiteralPath $resultsDir -Filter '*.tmp-*' -ErrorAction SilentlyContinue
  Assert (($leftoverTemp | Measure-Object).Count -eq 0) "no temp file should remain after an atomic results write"

  # =====================================================================================
  # Sanity: the 6 real launch scenarios under evals/scenarios/ all discover cleanly and pass
  # -Mode ci today. This is the harness's own smoke test of the shipped fixtures, not a
  # duplicate of any check above.
  # =====================================================================================
  $realScenariosDir = Join-Path $repo 'evals\scenarios'
  $realDiscovered = Find-EvalScenarios -Dir $realScenariosDir
  $expectedNames = @('silence','injection-refusal','money-with-vault-context','opportunity-escalation','rejection-non-escalation','staged-prep-quality')
  foreach ($n in $expectedNames) {
    Assert (@($realDiscovered.Name) -contains $n) "launch scenario '$n' must exist under evals/scenarios/"
  }
  foreach ($s in $realDiscovered) {
    Assert ($s.Errors.Count -eq 0) "real scenario '$($s.Name)' must not have a discovery error: $($s.Errors -join '; ')"
  }
  $realRun = Invoke-EvalRun -Mode 'ci' -ScenariosDir $realScenariosDir -ResultsDir (Join-Path $tmpRoot 'real-results') -Only $null -Cfg (Get-EvalConfig)
  Assert ($realRun.Passed) "all 6 shipped launch scenarios must pass -Mode ci (failures: $((@($realRun.Results | Where-Object { -not $_.Passed })).Name -join ', '))"

  Write-Host "eval-harness: ALL PASS"
} finally {
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
