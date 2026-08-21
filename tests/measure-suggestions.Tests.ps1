# tests/measure-suggestions.Tests.ps1 - the deterministic pre-pass of skill/bin/consolidate-memory.ps1:
# Measure-SuggestionOutcomes parses <vault>\SUGGESTIONS.md, collapses same-slug re-raises with a count,
# and searches an injected evidence corpus for proof a suggestion was actually acted on. No agent call
# in this file at all - everything under test here is pure/deterministic PowerShell.
#
# Extraction pattern matches tests/stage-prep.Tests.ps1: consolidate-memory.ps1 runs its whole weekly
# pass the moment it is invoked (no -DotSourceOnly guard), so functions under test are lifted out by
# source extraction into an isolated scope instead.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$src = Get-Content (Join-Path $repo 'skill\bin\consolidate-memory.ps1') -Raw

function Extract-Fn([string]$Src, [string]$Name) {
  $m = [regex]::Match($Src, "(?ms)^function $Name \{.*?\n\}")
  Assert $m.Success "could not extract $Name from consolidate-memory.ps1"
  return $m.Value
}

foreach ($fn in @('Get-SuggestionSlugs','Get-SuggestionCategory','ConvertFrom-SuggestionsMarkdown',
                   'Get-SuggestionEvidence','Test-SuggestionActed','Measure-SuggestionOutcomes')) {
  . ([scriptblock]::Create((Extract-Fn $src $fn)))
}

# ---------- Get-SuggestionSlugs: normalises a numeric vault-folder prefix onto the same slug ----------
$s1 = Get-SuggestionSlugs 'Register alpha-signal-lab as vault 25-alpha-signal-lab'
Assert ($s1 -contains 'alpha-signal-lab') "must extract the bare slug 'alpha-signal-lab' (got: $($s1 -join ', '))"
Assert (@($s1 | Where-Object { $_ -eq 'alpha-signal-lab' }).Count -eq 1) `
  "the numeric-prefixed form ('25-alpha-signal-lab') must normalise onto the SAME slug, not add a second one (got: $($s1 -join ', '))"
Assert ((Get-SuggestionSlugs '').Count -eq 0) "an empty title must yield zero slugs"
Assert ((Get-SuggestionSlugs 'Gym').Count -eq 0) "a plain non-hyphenated word must yield zero slugs"

# ---------- Get-SuggestionCategory: deterministic keyword bucket ----------
Assert ((Get-SuggestionCategory 'Post the arc on LinkedIn') -eq 'social-post') "a LinkedIn/post title must classify as social-post"
Assert ((Get-SuggestionCategory 'Apply to Fruition Group today') -eq 'job-application') "an apply/application title must classify as job-application"
Assert ((Get-SuggestionCategory 'Register alpha-signal-lab as vault 25-alpha-signal-lab') -eq 'portfolio-registration') "a register/vault title must classify as portfolio-registration"
Assert ((Get-SuggestionCategory 'Log external OSS contributions') -eq 'housekeeping') "a log/triage title must classify as housekeeping"

# ---------- ConvertFrom-SuggestionsMarkdown: fixture matches the real vault's own append format ----------
# Uses the SAME em-dash header format debrief.md's own append step writes (### YYYY-MM-DD <dash> <idea>).
$emdash = [char]0x2014
$fixtureText = @"
# Suggestions backlog

### 2026-08-20 $emdash Register alpha-signal-lab as vault 25-alpha-signal-lab
10 raises now, still the only open item that's pure paperwork.

### 2026-08-19 $emdash Register alpha-signal-lab as vault 25-alpha-signal-lab
9 raises in the ledger and counting.

### 2026-08-17 $emdash Register alpha-signal-lab and close the dead-link gap
The portfolio site has linked to alpha-signal-lab since 08-07.

### 2026-08-08 $emdash Register or mute the new ict-unicorn-model repo
Fired 4 near-identical digest emails overnight.

### 2026-08-03 $emdash Register alpha-signal-lab as vault 25-alpha-signal-lab and push public
Pre-registered ML alpha signal pipeline with adversarial review pass.

### 2026-07-30 $emdash Add the job-hunt-analytics dashboard URL to your CV projects section
The P3 dashboard is live at aleks-drozy.github.io/job-hunt-analytics.
"@

# NOT wrapped in @() - ConvertFrom-SuggestionsMarkdown returns ,$array.ToArray() (a single emitted
# array object); wrapping a comma-returning FUNCTION CALL in @() re-wraps it into a 1-element outer
# array instead of flattening it (verified empirically against this exact function).
$entries = ConvertFrom-SuggestionsMarkdown -Text $fixtureText
Assert ($entries.Count -eq 6) "expected 6 parsed entries from the fixture, got $($entries.Count)"
Assert ($entries[0].Date -eq [datetime]'2026-08-20') "the first parsed entry must carry the correct date"
Assert ($entries[0].Title -eq 'Register alpha-signal-lab as vault 25-alpha-signal-lab') "the first parsed entry must carry the exact title (got: '$($entries[0].Title)')"

# ---------- Measure-SuggestionOutcomes: repeat detection collapses same-slug re-raises with a count ----------
$fixturePath = Join-Path $env:TEMP ('jarvis-suggestions-fixture-' + [guid]::NewGuid().ToString('N') + '.md')
Set-Content -Encoding UTF8 -LiteralPath $fixturePath -Value $fixtureText
try {
  $now = [datetime]'2026-08-20T21:00:00'

  # a) no-evidence run: acted must be false everywhere - never a false positive
  # NOT wrapped in @() - see the comment above ConvertFrom-SuggestionsMarkdown's own call site.
  $ledgerNoEvidence = Measure-SuggestionOutcomes -SuggestionsPath $fixturePath -Now $now -WindowWeeks 6 -EvidenceCorpus @()
  $alpha = @($ledgerNoEvidence | Where-Object { $_.slug -eq 'alpha-signal-lab' })
  Assert ($alpha.Count -eq 1) "alpha-signal-lab must collapse to exactly one ledger entry (got $($alpha.Count))"
  Assert ($alpha[0].times_raised -eq 4) "alpha-signal-lab must be counted 4x within the window (08-03, 08-17, 08-19, 08-20), got $($alpha[0].times_raised)"
  Assert ($alpha[0].acted -eq $false) "with an empty evidence corpus, acted must be false (never a false positive)"
  Assert (@($alpha[0].evidence).Count -eq 0) "with an empty evidence corpus, the evidence array must be empty"

  $ict = @($ledgerNoEvidence | Where-Object { $_.slug -eq 'ict-unicorn-model' })
  Assert ($ict.Count -eq 1) "ict-unicorn-model must be its own separate ledger entry, not merged with alpha-signal-lab"
  Assert ($ict[0].times_raised -eq 1) "ict-unicorn-model was raised once in the fixture, got $($ict[0].times_raised)"
  Assert ($ict[0].acted -eq $false) "ict-unicorn-model must also read as not-acted with no evidence"

  # b) planted evidence marker: acted detection must find it
  $evidenceWithMarker = @('25-alpha-signal-lab', 'unrelated-other-file.md')
  $ledgerWithEvidence = Measure-SuggestionOutcomes -SuggestionsPath $fixturePath -Now $now -WindowWeeks 6 -EvidenceCorpus $evidenceWithMarker
  $alpha2 = @($ledgerWithEvidence | Where-Object { $_.slug -eq 'alpha-signal-lab' })[0]
  Assert ($alpha2.acted -eq $true) "a planted evidence marker ('25-alpha-signal-lab' folder name) must be detected as acted"
  Assert (@($alpha2.evidence) -contains '25-alpha-signal-lab') "the matched evidence string itself must be recorded in the evidence array"
  $ict2 = @($ledgerWithEvidence | Where-Object { $_.slug -eq 'ict-unicorn-model' })[0]
  Assert ($ict2.acted -eq $false) "unrelated evidence must not cause a false positive on a different slug"

  # c) required keys + JSON validity
  foreach ($item in $ledgerWithEvidence) {
    foreach ($k in @('suggestion','category','times_raised','acted','evidence')) {
      Assert ($null -ne $item.PSObject.Properties[$k]) "every ledger entry must carry the '$k' key (spec: {suggestion, category, times_raised, acted, evidence})"
    }
  }
  $json = ConvertTo-Json -InputObject @($ledgerWithEvidence) -Depth 6
  $roundTrip = $null
  $parseThrew = $false
  try { $roundTrip = $json | ConvertFrom-Json } catch { $parseThrew = $true }
  Assert (-not $parseThrew) "the ledger must serialize to valid JSON"
  Assert ($null -ne $roundTrip) "the round-tripped JSON must parse back to a non-null value"

  # d) window correctness: an entry outside the trailing window must not appear at all
  $ledgerNarrowWindow = Measure-SuggestionOutcomes -SuggestionsPath $fixturePath -Now $now -WindowWeeks 1 -EvidenceCorpus @()
  $jobHunt = @($ledgerNarrowWindow | Where-Object { $_.slug -eq 'job-hunt-analytics' })
  Assert ($jobHunt.Count -eq 0) "an entry from 2026-07-30 must fall outside a 1-week trailing window as of 2026-08-20"

  # e) missing/absent SUGGESTIONS.md reads as empty, not an error
  $missingPath = Join-Path $env:TEMP ('jarvis-suggestions-missing-' + [guid]::NewGuid().ToString('N') + '.md')
  $emptyLedger = Measure-SuggestionOutcomes -SuggestionsPath $missingPath -Now $now
  Assert ($emptyLedger.Count -eq 0) "a missing SUGGESTIONS.md must read as zero ledger entries, not throw"
} finally {
  Remove-Item $fixturePath -Force -ErrorAction SilentlyContinue
}

Write-Host "measure-suggestions: ALL PASS"
