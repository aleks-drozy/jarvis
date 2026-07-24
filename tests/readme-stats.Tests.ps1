# tests/readme-stats.Tests.ps1 - the README makes countable claims; this suite recounts them.
# The same discipline the structural security tests apply to code, applied to the docs: a number
# the tree can derive must match the number the README states, or the build fails and the failure
# message says what the correct number is. Numbers the tree cannot derive (commit counts, CI run
# counts) must be pinned to a tag, so they are historical facts rather than rotting claims.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo   = Resolve-Path (Join-Path $PSScriptRoot '..')
$readme = Get-Content (Join-Path $repo 'README.md') -Raw

# --- measure reality ---
$suiteFiles = Get-ChildItem (Join-Path $repo 'tests') -Filter *.Tests.ps1
$psSuiteCount = $suiteFiles.Count
$assertCount = (Select-String -Path (Join-Path $repo 'tests\*.Tests.ps1') -Pattern '\bAssert\s*\(' -AllMatches |
  ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
$lineCount = (Get-Content (Join-Path $repo 'tests\*.Tests.ps1') | Measure-Object -Line).Lines

# --- claim 1: "N suites: M native PowerShell" ---
Assert ($readme -match '(\d+) suites: (\d+) native PowerShell') "README must state the suite count in the pinned phrasing"
$claimTotal = [int]$Matches[1]; $claimPs = [int]$Matches[2]
Assert ($claimPs -eq $psSuiteCount) "README claims $claimPs PowerShell suites; tests/ holds $psSuiteCount - update the README"
Assert ($claimTotal -eq ($psSuiteCount + 1)) "README claims $claimTotal total suites; measured $($psSuiteCount + 1) (PS + 1 Node)"

# --- claim 2: assert call sites ---
Assert ($readme -match '([\d,]+) `?Assert`? call sites') "README must state the Assert-call-site count in the pinned phrasing"
$claimAsserts = [int]($Matches[1] -replace ',','')
Assert ($claimAsserts -eq $assertCount) "README claims $claimAsserts Assert call sites; measured $assertCount - update the README"

# --- claim 3: suite line count ---
Assert ($readme -match '([\d,]+) lines\b') "README must state the suite line count"
$claimLines = [int]($Matches[1] -replace ',','')
Assert ($claimLines -eq $lineCount) "README claims $claimLines suite lines; measured $lineCount - update the README"

# --- convention: commit-count claims must be tag-pinned, never 'so far' ---
# NOTE: [^.\r\n] not [^.`n] - in a single-quoted PS string the backtick is literal, and the
# regex would wrongly exclude the letter n from the sentence span.
# DEVIATION (documented, see task-7-report.md): a bare [^.\r\n]* excludes every period, including
# the two inside a dotted tag like v3.0.0 - so a match could never contain the full tag and the
# v\d+\.\d+ pin check below could never pass, for any README wording. (?:\.(?=\d)|[^.\r\n])* keeps
# the same sentence-boundary intent (still stops at a period followed by a space/EOL) while letting
# a period followed by a digit - i.e. a version number - stay inside the span.
$sentenceSpan = '(?:\.(?=\d)|[^.\r\n])*'
foreach ($m in [regex]::Matches($readme, $sentenceSpan + '\b\d+ commits\b' + $sentenceSpan)) {
  Assert ($m.Value -match 'v\d+\.\d+(\.\d+)?') ("commit-count claims must be pinned to a tag: '" + $m.Value.Trim() + "'")
}
foreach ($m in [regex]::Matches($readme, $sentenceSpan + '\bCI run[s]?\b' + $sentenceSpan + '\b\d+ of \d+\b' + $sentenceSpan)) {
  Assert ($m.Value -match 'v\d+\.\d+(\.\d+)?') ("CI-run-count claims must be pinned to a tag: '" + $m.Value.Trim() + "'")
}
Write-Host "readme-stats: ALL PASS"
