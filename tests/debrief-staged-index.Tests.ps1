# tests/debrief-staged-index.Tests.ps1 - jarvis-debrief.ps1's own read-only index of what Night Shift
# (skill/bin/stage-prep.ps1) staged in the last 48h. The debrief LINKS staged/*.md, it never
# regenerates them (spec item 5) - Get-StagedIndexBlock is the function that builds that link list.
#
# Extraction pattern matches tests/claude-generation-timeout.Tests.ps1: jarvis-debrief.ps1 runs a full
# debrief the moment it is dot-sourced, so the function under test is lifted out by source extraction.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
$fnMatch = [regex]::Match($debriefSrc, '(?ms)^function Get-StagedIndexBlock \{.*?\n\}')
Assert ($fnMatch.Success) "could not extract Get-StagedIndexBlock from jarvis-debrief.ps1"
. ([scriptblock]::Create($fnMatch.Value))

$now = [datetime]::Parse('2026-08-20T08:30:00')

# 1) absent staged/ directory -> empty block (Night Shift never enabled/run - not an error)
$vaultAbsent = Join-Path $env:TEMP ('jarvis-staged-idx-absent-' + [guid]::NewGuid().ToString('N'))
$blockAbsent = Get-StagedIndexBlock -VaultPath $vaultAbsent -Now $now
Assert ($blockAbsent -eq '') "a missing outreach\staged\ directory must produce an empty block, got: '$blockAbsent'"

# 2) staged/ exists but empty -> empty block (nothing staged is not an error either)
$vaultEmpty = Join-Path $env:TEMP ('jarvis-staged-idx-empty-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $vaultEmpty 'outreach\staged') | Out-Null
try {
  $blockEmpty = Get-StagedIndexBlock -VaultPath $vaultEmpty -Now $now
  Assert ($blockEmpty -eq '') "an empty outreach\staged\ directory must produce an empty block, got: '$blockEmpty'"
} finally { Remove-Item $vaultEmpty -Recurse -Force -ErrorAction SilentlyContinue }

# 3) files in-window (last 48h by date-prefixed filename) -> present and lists them; files OUTSIDE the
#    window must be excluded even though they live in the same directory.
$vault = Join-Path $env:TEMP ('jarvis-staged-idx-' + [guid]::NewGuid().ToString('N'))
$stagedDir = Join-Path $vault 'outreach\staged'
New-Item -ItemType Directory -Force -Path $stagedDir | Out-Null
try {
  # in-window: today and yesterday (48h back from 2026-08-20)
  Set-Content -Encoding UTF8 -Path (Join-Path $stagedDir '2026-08-20-codesignal-assessment.md') -Value '# sheet'
  Set-Content -Encoding UTF8 -Path (Join-Path $stagedDir '2026-08-19-mastercard-interview.md') -Value '# sheet'
  # out-of-window: a week old
  Set-Content -Encoding UTF8 -Path (Join-Path $stagedDir '2026-08-13-old-stale-sheet.md') -Value '# sheet'
  # a non-.md file must never be listed even if it matches the date prefix
  Set-Content -Encoding UTF8 -Path (Join-Path $stagedDir '2026-08-20-notes.txt') -Value 'not markdown'

  $block = Get-StagedIndexBlock -VaultPath $vault -Now $now
  Assert ($block -ne '') "in-window staged files must produce a non-empty index block"
  Assert ($block -match 'codesignal-assessment\.md') "the in-window file (today) must be listed"
  Assert ($block -match 'mastercard-interview\.md') "the in-window file (yesterday) must be listed"
  Assert ($block -notmatch 'old-stale-sheet') "a file outside the 48h window must NOT be listed"
  Assert ($block -notmatch 'notes\.txt') "a non-markdown file must never be listed"
  Assert ($block -match '(?i)link') "the block must instruct linking, not regenerating, the staged content"
} finally { Remove-Item $vault -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "debrief-staged-index: ALL PASS"
