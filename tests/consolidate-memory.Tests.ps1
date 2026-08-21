# tests/consolidate-memory.Tests.ps1 - the agent-pass + schema-gate half of
# skill/bin/consolidate-memory.ps1: episodic-window correctness, debriefs/ immutability, the
# schema gate that keeps malformed LLM output from ever destroying PATTERNS.md, the atomic replace,
# stale-flagging, and a positive control proving the gate actually rejects something.
#
# Extraction pattern matches tests/stage-prep.Tests.ps1: consolidate-memory.ps1 runs its whole weekly
# pass the moment it is invoked (no -DotSourceOnly guard), so functions under test are lifted out by
# source extraction into an isolated scope instead. The real Claude invocation is never extracted - a
# name-shadowing stub is defined FIRST so Invoke-WeeklyConsolidation (extracted after it) resolves to
# the stub, never the real CLI.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$src = Get-Content (Join-Path $repo 'skill\bin\consolidate-memory.ps1') -Raw

function Extract-Fn([string]$Src, [string]$Name) {
  $m = [regex]::Match($Src, "(?ms)^function $Name \{.*?\n\}")
  Assert $m.Success "could not extract $Name from consolidate-memory.ps1"
  return $m.Value
}

foreach ($fn in @('Get-DebriefWindowFiles','Get-PatternsSection','Test-PatternsSchema','Add-StaleFactFlags')) {
  . ([scriptblock]::Create((Extract-Fn $src $fn)))
}

# A valid PATTERNS.md candidate, matching the template's three required headers and citation format.
function New-ValidPatternsText {
  param([string]$Date1 = '2026-08-17', [string]$Date2 = '2026-08-20')
  return @"
# PATTERNS.md

## Durable facts
- Alex trains judo Sundays 18:00-20:00. (source: debriefs/$Date1.md)
- alpha-signal-lab has been raised repeatedly with no registration action. (source: debriefs/$Date2.md)

## Suggestion weights
- portfolio-registration: 6 raised, 0 acted (0%)

## Weekly learning report
1. alpha-signal-lab re-raised again with zero action taken.
2. No new durable facts contradicted this week.
3. Suggestion weights computed from 1 ledger entry.
4. Nothing acted on this week per the evidence corpus.
5. Consolidation completed cleanly.
"@
}

# ============================================================================
# Get-DebriefWindowFiles: window correctness
# ============================================================================
$debriefsDir = Join-Path $env:TEMP ('jarvis-consolidation-debriefs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $debriefsDir | Out-Null
try {
  $inWindowNames = @('2026-08-14.md','2026-08-17.md','2026-08-19.md','2026-08-20.md')
  $outOfWindowNames = @('2026-08-01.md','2026-07-30.md')
  $nonDateNames = @('README.md')
  foreach ($n in (@($inWindowNames) + @($outOfWindowNames) + @($nonDateNames))) {
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $debriefsDir $n) -Value "# $n"
  }
  $now = [datetime]'2026-08-20T21:00:00'
  # NOT wrapped in @() - Get-DebriefWindowFiles returns ,(array); wrapping a comma-returning FUNCTION
  # CALL in @() collapses a multi-element result to one (verified empirically).
  $windowFiles = Get-DebriefWindowFiles -DebriefsPath $debriefsDir -Now $now -WindowDays 7

  Assert ($windowFiles.Count -eq $inWindowNames.Count) `
    "the window must contain EXACTLY the trailing-week debrief filenames (got $($windowFiles.Count): $($windowFiles -join ', '))"
  foreach ($n in $inWindowNames) {
    Assert (@($windowFiles) -contains $n) "the trailing-week window must include $n"
  }
  foreach ($n in (@($outOfWindowNames) + @($nonDateNames))) {
    Assert (@($windowFiles) -notcontains $n) "the trailing-week window must NOT include $n (out of window or non-date file)"
  }
} finally {
  Remove-Item $debriefsDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# Schema gate: Test-PatternsSchema
# ============================================================================

# 1) a well-formed candidate must pass
$validText = New-ValidPatternsText
$validSchema = Test-PatternsSchema -Text $validText
Assert $validSchema.Valid "a well-formed PATTERNS.md candidate (all headers + every fact cited) must pass the schema gate (errors: $($validSchema.Errors -join '; '))"

# 2) POSITIVE CONTROL: a deliberately malformed candidate (missing a required header) must be rejected
$missingHeaderText = $validText -replace '## Suggestion weights', '## Suggestion Weightz'
$missingHeaderSchema = Test-PatternsSchema -Text $missingHeaderText
Assert (-not $missingHeaderSchema.Valid) "positive control: a candidate missing a required section header MUST be rejected by the schema gate"
Assert ($missingHeaderSchema.Errors.Count -gt 0) "a rejected candidate must carry at least one human-readable error"

# 3) a fact line with no citation must be rejected
$noCitationText = $validText -replace '\(source: debriefs/2026-08-17\.md\)', ''
$noCitationSchema = Test-PatternsSchema -Text $noCitationText
Assert (-not $noCitationSchema.Valid) "a fact line missing '(source: ...)' must be rejected by the schema gate"

# 4) empty output must be rejected
$emptySchema = Test-PatternsSchema -Text ''
Assert (-not $emptySchema.Valid) "empty candidate output must be rejected"

Write-Host "consolidate-memory: schema gate checks passed"

# ============================================================================
# Add-StaleFactFlags: pure function, stale-flagging by date math done in PowerShell (never trusted to
# the agent). A fact last evidenced 5 weeks ago gets flagged; one evidenced 2 weeks ago is untouched.
# ============================================================================
$staleNow = [datetime]'2026-08-20'
$staleFixture = @"
## Durable facts
- Old fact, evidenced five weeks ago. (source: debriefs/2026-07-16.md)
- Fresh fact, evidenced two weeks ago. (source: debriefs/2026-08-06.md)

## Suggestion weights
- other: 0 raised, 0 acted
"@
$flagged = Add-StaleFactFlags -Text $staleFixture -Now $staleNow -StaleWeeks 4
Assert ($flagged -match 'Old fact, evidenced five weeks ago\..*\(stale -- last evidenced 2026-07-16\)') `
  "a fact last evidenced 5 weeks ago (>= 4-week threshold) must be flagged '(stale -- last evidenced <date>)' (got: $flagged)"
Assert ($flagged -notmatch 'Fresh fact, evidenced two weeks ago\..*stale') `
  "a fact evidenced only 2 weeks ago must be LEFT ALONE, not flagged stale (got: $flagged)"

Write-Host "consolidate-memory: stale-flagging checks passed"

# ============================================================================
# Invoke-WeeklyConsolidation: episodic immutability, schema-gated atomic replace, rejection-keeps-old.
# Name-shadow the agent call BEFORE extracting Invoke-WeeklyConsolidation so it resolves to the stub.
# ============================================================================
function Invoke-ConsolidationClaudeGeneration {
  param($VaultPath, $SkillDir, $DebriefFiles, $LedgerJson, $TemplatePath, $StagingPath, $TimeoutSec, $LogPath)
  Set-Content -Encoding UTF8 -LiteralPath $StagingPath -Value (New-ValidPatternsText)
}
. ([scriptblock]::Create((Extract-Fn $src 'Invoke-WeeklyConsolidation')))
# Measure-SuggestionOutcomes is called internally by Invoke-WeeklyConsolidation - extract the real
# (deterministic) implementation too, along with its own dependencies, so the orchestrator test
# exercises the genuine pre-pass rather than a second stub.
foreach ($fn in @('Get-SuggestionSlugs','Get-SuggestionCategory','ConvertFrom-SuggestionsMarkdown',
                   'Get-SuggestionEvidence','Test-SuggestionActed','Measure-SuggestionOutcomes',
                   'Restore-PatternsIfTampered')) {
  . ([scriptblock]::Create((Extract-Fn $src $fn)))
}

function New-ConsolidationFixture {
  param([string]$Root)
  $vault = Join-Path $Root 'vault'
  New-Item -ItemType Directory -Force -Path (Join-Path $vault 'debriefs') | Out-Null
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $vault 'debriefs\2026-08-20.md') -Value '# debrief'
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $vault 'SUGGESTIONS.md') -Value '# Suggestions'
  return $vault
}

# ---- Test 1: episodic immutability - SHA256 of every fixture debrief identical before/after a full run ----
$root1 = Join-Path $env:TEMP ('jarvis-consolidation-t1-' + [guid]::NewGuid().ToString('N'))
try {
  $vault1 = New-ConsolidationFixture -Root $root1
  $debriefFile1 = Join-Path $vault1 'debriefs\2026-08-20.md'
  $hashBefore = (Get-FileHash -LiteralPath $debriefFile1 -Algorithm SHA256).Hash

  $ok1 = Invoke-WeeklyConsolidation -Now ([datetime]'2026-08-20T21:00:00') -VaultPath $vault1 -SkillDir 'C:\fake-skill'
  Assert $ok1 "a valid stubbed agent output must result in a successful consolidation"

  $hashAfter = (Get-FileHash -LiteralPath $debriefFile1 -Algorithm SHA256).Hash
  Assert ($hashAfter -eq $hashBefore) "consolidation must NEVER edit a debrief file - episodic layer is strictly read-only (hash changed)"
  Assert (Test-Path (Join-Path $vault1 'PATTERNS.md')) "a successful consolidation must write PATTERNS.md"

  # atomic write: no leftover .tmp-*/.staged-* files after a completed run
  # NOT -Filter 'PATTERNS.md.*' - Get-ChildItem -Filter uses legacy 8.3-compatible wildcard matching,
  # under which that pattern can also match the bare "PATTERNS.md" file itself (verified empirically).
  # -like against the full name is exact.
  $leftovers = @(Get-ChildItem -LiteralPath $vault1 -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'PATTERNS.md.*' })
  Assert ($leftovers.Count -eq 0) "the write must be atomic (temp file, then rename) - no PATTERNS.md.tmp-*/.staged-* file may remain (found: $($leftovers.Name -join ', '))"
} finally {
  Remove-Item $root1 -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Test 2: schema gate rejects a malformed stubbed candidate - PATTERNS.md unchanged (byte-compare),
#      rejection logged ----
function Invoke-ConsolidationClaudeGeneration {
  param($VaultPath, $SkillDir, $DebriefFiles, $LedgerJson, $TemplatePath, $StagingPath, $TimeoutSec, $LogPath)
  # deliberately malformed: missing the '(source: ...)' citation on a fact line
  $bad = (New-ValidPatternsText) -replace '\(source: debriefs/2026-08-17\.md\)', ''
  Set-Content -Encoding UTF8 -LiteralPath $StagingPath -Value $bad
}
$root2 = Join-Path $env:TEMP ('jarvis-consolidation-t2-' + [guid]::NewGuid().ToString('N'))
try {
  $vault2 = New-ConsolidationFixture -Root $root2
  $existingPatterns = "# PATTERNS.md (pre-existing)`n`n## Durable facts`n- Pre-existing fact. (source: debriefs/2026-08-01.md)`n`n## Suggestion weights`n- other: 0 raised, 0 acted`n`n## Weekly learning report`n1. a`n2. b`n3. c`n4. d`n5. e`n"
  $patternsPath2 = Join-Path $vault2 'PATTERNS.md'
  Set-Content -Encoding UTF8 -LiteralPath $patternsPath2 -Value $existingPatterns
  $hashBefore2 = (Get-FileHash -LiteralPath $patternsPath2 -Algorithm SHA256).Hash

  $logPath2 = Join-Path $root2 'consolidation.log'
  $ok2 = Invoke-WeeklyConsolidation -Now ([datetime]'2026-08-20T21:00:00') -VaultPath $vault2 -SkillDir 'C:\fake-skill' -LogPath $logPath2
  Assert (-not $ok2) "a malformed stubbed agent output must be rejected (return false)"

  $hashAfter2 = (Get-FileHash -LiteralPath $patternsPath2 -Algorithm SHA256).Hash
  Assert ($hashAfter2 -eq $hashBefore2) "a rejected candidate must leave the EXISTING PATTERNS.md byte-for-byte unchanged"

  Assert (Test-Path $logPath2) "a rejection must be logged"
  $log2Text = Get-Content -LiteralPath $logPath2 -Raw
  Assert ($log2Text -match 'REJECTED') "the log must record the rejection with a diagnosable marker (got: $log2Text)"

  $leftovers2 = @(Get-ChildItem -LiteralPath $vault2 -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'PATTERNS.md.*' })
  Assert ($leftovers2.Count -eq 0) "a rejected run must not leave any staging/temp file behind (found: $($leftovers2.Name -join ', '))"
} finally {
  Remove-Item $root2 -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Test 3: BUG-1 (live sandbox, 2026-08-20) - the agent cheats: bypasses the staging gate and
#      writes malformed content STRAIGHT onto PatternsPath, never touching $StagingPath at all. The
#      orchestrator's own staging-missing accounting says "REJECTED", but PatternsPath was destroyed
#      underneath it. Restore-PatternsIfTampered must hash-verify and restore it regardless. ----
function Invoke-ConsolidationClaudeGeneration {
  param($VaultPath, $SkillDir, $DebriefFiles, $LedgerJson, $TemplatePath, $StagingPath, $TimeoutSec, $LogPath)
  # simulates the live-sandbox cheat (2026-08-20): bypasses staging, writes garbage straight to PATTERNS.md
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $VaultPath 'PATTERNS.md') -Value 'garbage - no headers, no citations'
}
$root3 = Join-Path $env:TEMP ('jarvis-consolidation-t3-' + [guid]::NewGuid().ToString('N'))
try {
  $vault3 = New-ConsolidationFixture -Root $root3
  $existingPatterns3 = "# PATTERNS.md (pre-existing)`n`n## Durable facts`n- Pre-existing fact. (source: debriefs/2026-08-01.md)`n`n## Suggestion weights`n- other: 0 raised, 0 acted`n`n## Weekly learning report`n1. a`n2. b`n3. c`n4. d`n5. e`n"
  $patternsPath3 = Join-Path $vault3 'PATTERNS.md'
  Set-Content -Encoding UTF8 -LiteralPath $patternsPath3 -Value $existingPatterns3
  $hashBefore3 = (Get-FileHash -LiteralPath $patternsPath3 -Algorithm SHA256).Hash

  $logPath3 = Join-Path $root3 'consolidation.log'
  $ok3 = Invoke-WeeklyConsolidation -Now ([datetime]'2026-08-20T21:00:00') -VaultPath $vault3 -SkillDir 'C:\fake-skill' -LogPath $logPath3
  Assert (-not $ok3) "an agent that bypasses the staging gate and writes directly to PatternsPath must result in a failed run (return false)"

  $hashAfter3 = (Get-FileHash -LiteralPath $patternsPath3 -Algorithm SHA256).Hash
  Assert ($hashAfter3 -eq $hashBefore3) "PATTERNS.md must be restored byte-for-byte after a staging-gate bypass (hash mismatch means the corruption survived)"

  Assert (Test-Path $logPath3) "a staging-gate bypass must be logged"
  $log3Text = Get-Content -LiteralPath $logPath3 -Raw
  Assert ($log3Text -match 'CRITICAL') "the log must carry a CRITICAL line for a staging-gate bypass, distinct from routine REJECTED noise (got: $log3Text)"
  Assert ($log3Text -match 'outside the staging gate') "the CRITICAL line must explain what happened (got: $log3Text)"
  Assert ($log3Text -match 'REJECTED') "the ordinary staging-missing REJECTED line must still be present alongside CRITICAL (got: $log3Text)"

  $leftovers3 = @(Get-ChildItem -LiteralPath $vault3 -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'PATTERNS.md.*' })
  Assert ($leftovers3.Count -eq 0) "no leftover PATTERNS.md.* backup/staging file may remain after the restore (found: $($leftovers3.Name -join ', '))"
} finally {
  Remove-Item $root3 -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Test 4: first-run edge - same cheating stub, but NO pre-existing PATTERNS.md, so there is
#      nothing to restore FROM - the agent's direct write must be removed entirely. ----
$root4 = Join-Path $env:TEMP ('jarvis-consolidation-t4-' + [guid]::NewGuid().ToString('N'))
try {
  $vault4 = New-ConsolidationFixture -Root $root4
  $patternsPath4 = Join-Path $vault4 'PATTERNS.md'
  Assert (-not (Test-Path $patternsPath4)) "test fixture precondition: no pre-existing PATTERNS.md"

  $logPath4 = Join-Path $root4 'consolidation.log'
  $ok4 = Invoke-WeeklyConsolidation -Now ([datetime]'2026-08-20T21:00:00') -VaultPath $vault4 -SkillDir 'C:\fake-skill' -LogPath $logPath4
  Assert (-not $ok4) "a first-run staging-gate bypass must result in a failed run (return false)"
  Assert (-not (Test-Path $patternsPath4)) "with no pre-existing PATTERNS.md, the agent's direct write must be removed entirely, not left in place"

  $log4Text = Get-Content -LiteralPath $logPath4 -Raw
  Assert ($log4Text -match 'CRITICAL') "a first-run staging-gate bypass must also be logged CRITICAL (got: $log4Text)"
} finally {
  Remove-Item $root4 -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Test 5: throwing-agent tamper - the stub writes garbage to PatternsPath and then THROWS,
#      proving the catch-side Restore-PatternsIfTampered call (not just the post-generation call) works. ----
function Invoke-ConsolidationClaudeGeneration {
  param($VaultPath, $SkillDir, $DebriefFiles, $LedgerJson, $TemplatePath, $StagingPath, $TimeoutSec, $LogPath)
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $VaultPath 'PATTERNS.md') -Value 'garbage from a dying agent'
  throw 'simulated agent failure'
}
$root5 = Join-Path $env:TEMP ('jarvis-consolidation-t5-' + [guid]::NewGuid().ToString('N'))
try {
  $vault5 = New-ConsolidationFixture -Root $root5
  $existingPatterns5 = "# PATTERNS.md (pre-existing)`n`n## Durable facts`n- Pre-existing fact. (source: debriefs/2026-08-01.md)`n`n## Suggestion weights`n- other: 0 raised, 0 acted`n`n## Weekly learning report`n1. a`n2. b`n3. c`n4. d`n5. e`n"
  $patternsPath5 = Join-Path $vault5 'PATTERNS.md'
  Set-Content -Encoding UTF8 -LiteralPath $patternsPath5 -Value $existingPatterns5
  $hashBefore5 = (Get-FileHash -LiteralPath $patternsPath5 -Algorithm SHA256).Hash

  $logPath5 = Join-Path $root5 'consolidation.log'
  $ok5 = Invoke-WeeklyConsolidation -Now ([datetime]'2026-08-20T21:00:00') -VaultPath $vault5 -SkillDir 'C:\fake-skill' -LogPath $logPath5
  Assert (-not $ok5) "a throwing agent that tampered with PatternsPath must result in a failed run (return false)"

  $hashAfter5 = (Get-FileHash -LiteralPath $patternsPath5 -Algorithm SHA256).Hash
  Assert ($hashAfter5 -eq $hashBefore5) "the catch-side restore must also repair PatternsPath byte-for-byte after a throwing agent"

  $log5Text = Get-Content -LiteralPath $logPath5 -Raw
  Assert ($log5Text -match 'CRITICAL') "the catch-side restore path must also log CRITICAL (got: $log5Text)"
} finally {
  Remove-Item $root5 -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "consolidate-memory: BUG-1 staging-gate-bypass checks passed"

# ============================================================================
# Source-level guard: the consolidation agent must never be granted Bash - blast-radius reduction
# so a cheating agent cannot shell out to bypass file-write protections either.
# ============================================================================
Assert ($src -notmatch '--allowedTools "[^"]*Bash') "consolidation agent must not be granted Bash"

# ============================================================================
# Skill-load assertion: SKILL.md and debrief.md must reference PATTERNS.md by name, so both the
# debrief and Telegram chat (which both load context via SKILL.md's own step) pick it up next to
# SOUL.md/TASTE.md.
# ============================================================================
$skillMdText = Get-Content (Join-Path $repo 'skill\SKILL.md') -Raw
Assert ($skillMdText -match 'PATTERNS\.md') "SKILL.md must reference PATTERNS.md by name so it is loaded next to SOUL.md/TASTE.md"
Assert ($skillMdText -match 'suggestion_weights') "SKILL.md must explain that suggestion_weights ranks/suppresses new suggestions"

$debriefMdText = Get-Content (Join-Path $repo 'skill\references\debrief.md') -Raw
Assert ($debriefMdText -match 'PATTERNS\.md') "debrief.md must reference PATTERNS.md by name"
Assert ($debriefMdText -match 'suggestion_weights') "debrief.md must reference suggestion_weights when deciding whether to raise a new suggestion"
Assert ($debriefMdText -match 'learning report') "debrief.md's Sunday retrospective must reference PATTERNS.md's weekly learning report"

Write-Host "consolidate-memory: ALL PASS"
