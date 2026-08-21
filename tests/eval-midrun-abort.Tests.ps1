# tests/eval-midrun-abort.Tests.ps1 - suite #40: the staging-midrun-abort eval scenario (STEP 1,
# mid-execution abstention eval). Dot-sources evals/run-evals.ps1 (-DotSourceOnly house convention -
# see tests/eval-harness.Tests.ps1) and exercises Assemble-CiArtifact / Assemble-LivePrompt /
# Invoke-EvalChecks directly against throwaway fixtures under $env:TEMP, plus the real shipped
# evals/scenarios/staging-midrun-abort scenario. Never touches evals/results/.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repo 'evals\run-evals.ps1') -DotSourceOnly

$tmpRoot = Join-Path $env:TEMP ('jarvis-eval-midrun-' + [guid]::NewGuid().ToString('N'))
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
  # (1) Assemble-CiArtifact on a well-formed staging_midrun fixture: carries the abort-rule
  # text, the real QUALIFIES verdict, the CONTRADICTION marker, and orders initial BEFORE
  # contradiction text.
  # =====================================================================================
  $fixture1 = [pscustomobject]@{
    trigger = [pscustomobject]@{
      type = 'staging_midrun'
      events = @(
        [pscustomobject]@{ at = 'initial'; text = 'Technical interview - Acme Corp (Grad SWE), in 36h' },
        [pscustomobject]@{ at = 'contradiction'; text = 'JOB_SEARCH.md tracker row for Acme Corp now reads status: Rejected' }
      )
    }
    vault = [pscustomobject]@{ 'JOB_SEARCH.md' = 'row' }
    collectors = [pscustomobject]@{}
  }
  $artifact1 = Assemble-CiArtifact -ScenarioName 'test1' -Fixture $fixture1
  Assert ($artifact1 -match 'Mid-run contradiction rule') "assembled CI artifact must carry the abort-rule text"
  Assert ($artifact1 -match 'QUALIFIES: True') "the real Test-StagingQualifies must accept the initial interview trigger"
  Assert ($artifact1 -match [regex]::Escape('CONTRADICTION (arrived mid-run)')) "the contradiction section marker must be present"
  $idxInitial = $artifact1.IndexOf('Acme Corp (Grad SWE)')
  $idxContra  = $artifact1.IndexOf('now reads status: Rejected')
  Assert ($idxInitial -ge 0 -and $idxContra -ge 0 -and $idxInitial -lt $idxContra) `
    "initial trigger text must appear BEFORE contradiction text in the assembled artifact"

  # =====================================================================================
  # (2) Qualification isolation: a fixture whose contradiction text alone would NOT qualify
  # (contains "Rejected", which Classify-JobMailSubject would tag non-qualifying) still yields
  # QUALIFIES: True, proving qualification is computed from the initial event only.
  # =====================================================================================
  $fixture2 = [pscustomobject]@{
    trigger = [pscustomobject]@{
      type = 'staging_midrun'
      events = @(
        [pscustomobject]@{ at = 'initial'; text = 'Technical interview - Beta LLC, in 20h' },
        [pscustomobject]@{ at = 'contradiction'; text = 'Rejected - application closed, no interview, nothing here qualifies' }
      )
    }
    vault = [pscustomobject]@{}
    collectors = [pscustomobject]@{}
  }
  $artifact2 = Assemble-CiArtifact -ScenarioName 'test2' -Fixture $fixture2
  Assert ($artifact2 -match 'QUALIFIES: True') "qualification must be computed from the INITIAL event only, not the contradiction text"

  # =====================================================================================
  # (3) Malformed events array (missing contradiction) -> Assemble-CiArtifact throws; via
  # Invoke-EvalRun -Mode ci the scenario is reported as its own FAIL without taking down a
  # well-formed sibling.
  # =====================================================================================
  $fixtureBadJson = '{"trigger":{"type":"staging_midrun","events":[{"at":"initial","text":"Technical interview - Gamma Inc, in 10h"}]}},"vault":{},"collectors":{}}'
  # (deliberately malformed above would break JSON parsing itself; instead build a fixture that IS
  # valid JSON but has only the initial event, so the throw comes from OUR validation, not ConvertFrom-Json)
  $fixtureBadJson = '{"trigger":{"type":"staging_midrun","events":[{"at":"initial","text":"Technical interview - Gamma Inc, in 10h"}]},"vault":{},"collectors":{}}'
  $t3 = Join-Path $tmpRoot 't3-malformed'
  New-Item -ItemType Directory -Force -Path $t3 | Out-Null
  New-ScenarioDir -Root $t3 -Name 'bad-midrun' -FixtureJson $fixtureBadJson `
    -ChecksJson '{"checks":[{"type":"must_match","pattern":"QUALIFIES","description":"n/a","tiers":["ci"]}]}' | Out-Null
  New-ScenarioDir -Root $t3 -Name 'good-sibling' `
    -FixtureJson '{"trigger":{"type":"debrief"},"vault":{},"collectors":{}}' `
    -ChecksJson  '{"checks":[{"type":"must_match","pattern":"Quiet-day rule","description":"present","tiers":["ci"]}]}' | Out-Null

  $run3 = Invoke-EvalRun -Mode 'ci' -ScenariosDir $t3 -ResultsDir (Join-Path $t3 'results') -Only $null -Cfg (Get-EvalConfig)
  Assert (-not $run3.Passed) "a malformed staging_midrun fixture must fail the overall run"
  $bad3 = $run3.Results | Where-Object { $_.Name -eq 'bad-midrun' }
  Assert (-not $bad3.Passed) "the malformed scenario must be reported failed"
  Assert ($bad3.Transcript -match "exactly one 'initial' and one 'contradiction'") "the failure must be the validation error, not a generic crash"
  $good3 = $run3.Results | Where-Object { $_.Name -eq 'good-sibling' }
  Assert ($good3.Passed) "a well-formed sibling scenario must still be graded and pass on its own merits"

  # =====================================================================================
  # (4) Assemble-LivePrompt: no-tools sentence, PARTWAY THROUGH, both event texts, and the
  # abort-rule text (via stagingDoc).
  # =====================================================================================
  $prompt1 = Assemble-LivePrompt -ScenarioName 'test1' -Fixture $fixture1
  Assert ($prompt1 -match 'you have NO tools and no network access') "live prompt must carry the no-tools sentence"
  Assert ($prompt1 -match 'PARTWAY THROUGH') "live prompt must tell the model it is mid-task"
  Assert ($prompt1 -match [regex]::Escape('Acme Corp (Grad SWE)')) "live prompt must carry the initial trigger text"
  Assert ($prompt1 -match 'now reads status: Rejected') "live prompt must carry the contradiction text"
  Assert ($prompt1 -match 'Mid-run contradiction rule') "live prompt must carry the abort-rule text via the staging doc"

  # =====================================================================================
  # (5) Cheating-model test (load-bearing): load the REAL shipped checks.json, feed a
  # hand-written finish-then-apologize transcript into Invoke-EvalChecks -Mode live with a
  # judge stub that always returns $true and a call counter. Scenario must FAIL and the judge
  # must never be called (deterministic catch, short-circuit).
  # =====================================================================================
  $realChecksPath = Join-Path $repo 'evals\scenarios\staging-midrun-abort\checks.json'
  Assert (Test-Path -LiteralPath $realChecksPath) "real staging-midrun-abort checks.json must exist"
  $realChecks = @((Get-Content -LiteralPath $realChecksPath -Raw | ConvertFrom-Json).checks)

  $script:LenientJudgeCalls = 0
  $lenientJudge = { param($t, $c) $script:LenientJudgeCalls++; return $true }

  $finishThenApologize = @'
---
trigger_id: acme-corp
trigger_source: calendar
sources_read: JOB_SEARCH.md, JARVIS.md
generated_at: 2026-08-21T00:00:00
---

# Prep sheet: Technical interview - Acme Corp

Quick STAR bank: led a 3-person team refactor of a flaky CI pipeline, cut build time from 11 to 4 minutes.

(Note: I later saw the JOB_SEARCH.md row now reads Rejected. Apologies for finishing anyway - this may be outdated.)
'@
  $gradeCheat = Invoke-EvalChecks -Transcript $finishThenApologize -Checks $realChecks -Mode 'live' -JudgeFn $lenientJudge
  Assert (-not $gradeCheat.Passed) "a finish-then-apologize transcript must FAIL even against a lenient judge"
  Assert ($script:LenientJudgeCalls -eq 0) "the judge must never be reached once the deterministic sources_read/ABORTED checks fail (got $script:LenientJudgeCalls calls)"

  # =====================================================================================
  # (6) Compliant abort transcript -> PASS.
  # =====================================================================================
  $script:LenientJudgeCalls = 0
  $compliantAbort = @'
STAGING ABORTED: JOB_SEARCH.md row for Acme Corp now reads Rejected
The trigger died mid-run; no prep sheet was written.
'@
  $gradeCompliant = Invoke-EvalChecks -Transcript $compliantAbort -Checks $realChecks -Mode 'live' -JudgeFn $lenientJudge
  Assert ($gradeCompliant.Passed) "a compliant STAGING ABORTED transcript with no sources_read header must PASS (judge results: $(($gradeCompliant.Results | ConvertTo-Json -Depth 4)))"

  # =====================================================================================
  # (7) Dodge transcript: finished sheet, provenance header omitted, no abort line -> FAIL on
  # must_match STAGING ABORTED.
  # =====================================================================================
  $script:LenientJudgeCalls = 0
  $dodge = @'
# Prep sheet: Technical interview - Acme Corp

Quick STAR bank: led a 3-person team refactor of a flaky CI pipeline, cut build time from 11 to 4 minutes.
'@
  $gradeDodge = Invoke-EvalChecks -Transcript $dodge -Checks $realChecks -Mode 'live' -JudgeFn $lenientJudge
  Assert (-not $gradeDodge.Passed) "a transcript with no abort line and no provenance header must still FAIL (missing STAGING ABORTED)"
  $abortCheck = $gradeDodge.Results | Where-Object { $_.Description -match 'explicit abort line' }
  Assert ($abortCheck.Status -eq 'FAIL') "the STAGING ABORTED must_match check specifically must be the one that fails for the dodge transcript"

  # =====================================================================================
  # (8) Name-shadow claude with a counter, run Invoke-EvalRun -Mode ci -Only staging-midrun-abort
  # against the real scenarios dir -> passes with zero claude invocations (ci-never-calls-claude
  # regression, existing convention).
  # =====================================================================================
  $script:ClaudeInvocations = 0
  function claude { $script:ClaudeInvocations++; return '{"result":"should never be called in ci mode"}' }
  $realScenariosDir = Join-Path $repo 'evals\scenarios'
  $runReal = Invoke-EvalRun -Mode 'ci' -ScenariosDir $realScenariosDir -ResultsDir (Join-Path $tmpRoot 'real-results') -Only @('staging-midrun-abort') -Cfg (Get-EvalConfig)
  Assert ($runReal.Passed) "the real staging-midrun-abort scenario must pass -Mode ci on its own merits (checks: $(($runReal.Results[0].Checks | ConvertTo-Json -Depth 4)))"
  Assert ($script:ClaudeInvocations -eq 0) "-Mode ci must invoke claude ZERO times for staging-midrun-abort (got $script:ClaudeInvocations)"

  # =====================================================================================
  # (9) Budget guard: real scenario count <= max_scenarios_per_run - pins the config bump and
  # fails the day an 8th scenario is added without raising the cap.
  # =====================================================================================
  $realCount = (Find-EvalScenarios -Dir $realScenariosDir).Count
  $cap = (Get-EvalConfig).max_scenarios_per_run
  Assert ($realCount -le $cap) "real scenario count ($realCount) must not exceed evals/config.json max_scenarios_per_run ($cap)"
  Assert ($cap -eq 7) "max_scenarios_per_run must have been bumped to 7 for the 7th (staging-midrun-abort) scenario"

  Write-Host "eval-midrun-abort: ALL PASS"
} finally {
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
