# tests/contradiction-flags.Tests.ps1 - retroactive contradiction-checking in weekly consolidation
# (STEP 3, instrumented deterministic-only first slice). Detection, annotation, and the count are
# 100% deterministic PowerShell - the agent never decides a contradiction flag. This suite proves:
# (a) the deterministic candidate/flag machinery itself, (b) that ANY agent-authored or forged flag
# is stripped and re-derived fresh every run (the strip-then-rederive rule), and (c) that this new
# step cannot be used to bypass or weaken the existing schema/hash-verify gate (see the
# order-guarantee case added to tests/consolidate-memory.Tests.ps1, which is the load-bearing proof
# for that last point - this file covers the pure functions in isolation).
#
# Extraction pattern matches tests/consolidate-memory.Tests.ps1: consolidate-memory.ps1 has no
# -DotSourceOnly guard, so functions under test are lifted out by source extraction (Extract-Fn).
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$src = Get-Content (Join-Path $repo 'skill\bin\consolidate-memory.ps1') -Raw

function Extract-Fn([string]$Src, [string]$Name) {
  $m = [regex]::Match($Src, "(?ms)^function $Name \{.*?\n\}")
  Assert $m.Success "could not extract $Name from consolidate-memory.ps1"
  return $m.Value
}

foreach ($fn in @('Get-ContradictionCandidates','Add-ContradictionFlags','Add-WeeklyReportContradictionLine')) {
  . ([scriptblock]::Create((Extract-Fn $src $fn)))
}

# ============================================================================
# 1) Get-ContradictionCandidates: positive/negative cases
# ============================================================================

$positiveFacts = @"
## Durable facts
- residence permit application still not submitted (source: debriefs/2026-07-05.md)
- residence permit submitted and receipt received (source: debriefs/2026-08-19.md)
"@
$posCandidates = Get-ContradictionCandidates -Text $positiveFacts
Assert ($posCandidates.Count -eq 1) "a genuine shared-topic pair with a >=28-day citation gap must yield exactly 1 candidate (got $($posCandidates.Count))"
Assert ($posCandidates[0].OlderIndex -lt $posCandidates[0].NewerIndex) "the older (earlier-dated) line must be identified as OlderIndex, the later as NewerIndex"
Assert ($posCandidates[0].NewerDate -eq '2026-08-19') "NewerDate must be the later citation date"

# Negative: fewer than 3 shared tokens
$fewSharedFacts = @"
## Durable facts
- residence permit application submitted (source: debriefs/2026-07-05.md)
- gym membership renewed for the year (source: debriefs/2026-08-19.md)
"@
Assert ((Get-ContradictionCandidates -Text $fewSharedFacts).Count -eq 0) "fewer than MinSharedTokens shared tokens must NOT be a candidate"

# Negative: identical lines (after whitespace normalization)
$identicalFacts = @"
## Durable facts
- residence permit application still not submitted (source: debriefs/2026-07-05.md)
- residence permit application still  not  submitted (source: debriefs/2026-08-19.md)
"@
Assert ((Get-ContradictionCandidates -Text $identicalFacts).Count -eq 0) "two lines that are identical after whitespace-normalization must NOT be a candidate"

# Negative: dates only 7 days apart (< 28-day MinDateGapDays default)
$closeDatesFacts = @"
## Durable facts
- residence permit application still not submitted (source: debriefs/2026-08-12.md)
- residence permit submitted and receipt received (source: debriefs/2026-08-19.md)
"@
Assert ((Get-ContradictionCandidates -Text $closeDatesFacts).Count -eq 0) "citation dates less than MinDateGapDays apart must NOT be a candidate"

# Negative: no citation date at all
$noDateFacts = @"
## Durable facts
- residence permit application still not submitted (source: some undated note)
- residence permit submitted and receipt received (source: debriefs/2026-08-19.md)
"@
Assert ((Get-ContradictionCandidates -Text $noDateFacts).Count -eq 0) "a line whose citation carries no parseable date must never anchor a candidate"

Write-Host "contradiction-flags: Get-ContradictionCandidates checks passed"

# ============================================================================
# 2) Documented near-miss / accepted false positive (soft flag, instrumented on purpose)
# ============================================================================
$nearMissFacts = @"
## Durable facts
- residence permit renewed for another year (source: debriefs/2026-07-15.md)
- residence permit expires in March next year per the embassy letter (source: debriefs/2026-08-19.md)
"@
$nearMissCandidates = Get-ContradictionCandidates -Text $nearMissFacts
# ACCEPTED FALSE POSITIVE: these two facts are not actually contradictory (one says "renewed", the
# other just states the resulting expiry date) but they share >= 3 tokens with a >= 5-week gap, so
# the coarse deterministic detector flags them. This is intentional for this first slice - see
# STEP 3's "Agent proposes, code enforces" note and OUT OF SCOPE: the count trend (grep over
# .jarvis-consolidation-*.log) is exactly how Alex learns whether MinSharedTokens/MinDateGapDays need
# raising, without ever trusting the agent to judge contradiction itself.
Assert ($nearMissCandidates.Count -eq 1) "documented near-miss must still be flagged by the coarse detector (accepted false positive, tracked via the count trend)"

Write-Host "contradiction-flags: documented near-miss checks passed"

# ============================================================================
# 3) Add-ContradictionFlags: marker format, older-line-only, idempotency, purity
# ============================================================================
$now = [datetime]'2026-08-20'
$flagResult = Add-ContradictionFlags -Text $positiveFacts -Now $now
Assert ($flagResult.ContradictionCount -eq 1) "Add-ContradictionFlags must report exactly 1 flag applied for the positive fixture"
Assert ($flagResult.Text -match [regex]::Escape('residence permit application still not submitted (source: debriefs/2026-07-05.md) (possibly contradicted -- see fact last evidenced 2026-08-19)')) `
  "the OLDER line must carry the exact-format marker (got: $($flagResult.Text))"
Assert ($flagResult.Text -notmatch [regex]::Escape('receipt received (source: debriefs/2026-08-19.md) (possibly contradicted')) `
  "the NEWER line must NOT be flagged - only the older line gets the marker"

# idempotency: running the flagger on its own output must produce the same text and same count
$flagResult2 = Add-ContradictionFlags -Text $flagResult.Text -Now $now
Assert ($flagResult2.Text -eq $flagResult.Text) "running Add-ContradictionFlags on its own output must be a no-op on the text (deterministic idempotency)"
Assert ($flagResult2.ContradictionCount -eq $flagResult.ContradictionCount) "re-running must report the same count, not a growing one"

# purity: the extracted function body must never touch the filesystem
$flagsFnBody = Extract-Fn $src 'Add-ContradictionFlags'
Assert ($flagsFnBody -notmatch 'Get-Content|Set-Content|Move-Item|Add-Content|Test-Path') `
  "Add-ContradictionFlags must be pure text-in/object-out - no file I/O of any kind"

Write-Host "contradiction-flags: Add-ContradictionFlags checks passed"

# ============================================================================
# 4) Cheating-agent tests: forged/pre-seeded '(possibly contradicted ...)' spans must never survive,
#    even on a pair that would not otherwise qualify, even in the exact code-format string.
# ============================================================================

# 4a: pre-seeded on a NON-qualifying pair (only 7-day gap - would not qualify on its own)
$forgedNonQualifying = @"
## Durable facts
- residence permit application still not submitted (possibly contradicted -- the agent decided this) (source: debriefs/2026-08-12.md)
- residence permit submitted and receipt received (source: debriefs/2026-08-19.md)
"@
$forged1 = Add-ContradictionFlags -Text $forgedNonQualifying -Now $now
Assert ($forged1.ContradictionCount -eq 0) "a forged marker on a non-qualifying pair must be stripped and NOT re-applied (count must be 0)"
Assert ($forged1.Text -notmatch 'possibly contradicted') "no 'possibly contradicted' text may survive when the underlying pair does not meet the deterministic criteria"

# 4b: forged marker in the EXACT code-format string on a non-qualifying pair (same-day citations)
$forgedExactFormat = @"
## Durable facts
- residence permit application still not submitted (source: debriefs/2026-08-19.md) (possibly contradicted -- see fact last evidenced 2026-08-19)
- residence permit submitted and receipt received (source: debriefs/2026-08-19.md)
"@
$forged2 = Add-ContradictionFlags -Text $forgedExactFormat -Now $now
Assert ($forged2.ContradictionCount -eq 0) "an exact-code-format forged marker must still be stripped when the pair does not qualify (identical citation dates, zero gap)"
Assert ($forged2.Text -notmatch 'possibly contradicted') "the exact-format forged marker must be gone from the output"

Write-Host "contradiction-flags: cheating-agent (forged flag) checks passed"

# ============================================================================
# 5) Add-WeeklyReportContradictionLine: lands inside the Weekly learning report section, N=0 included
# ============================================================================
$reportFixture = @"
# PATTERNS.md

## Durable facts
- Some fact. (source: debriefs/2026-08-19.md)

## Suggestion weights
- other: 0 raised, 0 acted

## Weekly learning report
1. First line.
2. Second line.
"@
$withReportLine = Add-WeeklyReportContradictionLine -Text $reportFixture -Count 2
Assert ($withReportLine -match '2 fact\(s\) flagged as possibly contradicted this week') "the report line must state the count"
$reportSectionIdx = $withReportLine.IndexOf('## Weekly learning report')
$flagLineIdx = $withReportLine.IndexOf('2 fact(s) flagged as possibly contradicted')
Assert ($flagLineIdx -gt $reportSectionIdx) "the contradiction report line must land AFTER the 'Weekly learning report' header"
Assert ($flagLineIdx -lt $withReportLine.Length) "sanity: the line must actually be present in the output"

# N=0 must still be appended (a trend needs the zeros too)
$withZero = Add-WeeklyReportContradictionLine -Text $reportFixture -Count 0
Assert ($withZero -match '0 fact\(s\) flagged as possibly contradicted this week') "N=0 must still produce the report line - the trend needs the zero weeks too"

Write-Host "contradiction-flags: Add-WeeklyReportContradictionLine checks passed"

# ============================================================================
# Prompt-pin: the agent prohibition must name BOTH 'stale' and 'possibly contradicted' so an agent
# reading its own instructions cannot claim it was never told not to add contradiction flags itself.
# ============================================================================
Assert ($src -match "Do NOT add any 'stale' or 'possibly contradicted' flag yourself") `
  "the consolidation prompt must explicitly forbid the agent from adding its own contradiction flags, alongside the existing stale-flag prohibition"

Write-Host "contradiction-flags: prompt-pin check passed"
Write-Host "contradiction-flags: ALL PASS"
