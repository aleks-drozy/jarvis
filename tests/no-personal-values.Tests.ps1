# tests/no-personal-values.Tests.ps1 - the open-source guard: no machine- or person-specific value may
# be hardcoded in tracked source. A stranger's clone must not carry the maintainer's email, personal
# app id, or absolute paths from his machine. Allowed exceptions: PRIVACY.md / TERMS.md (legal documents
# that deliberately name the operator) and docs/ (historical build-log narrative, not executable source).
# The maintainer's NAME in README/LICENSE is deliberate attribution and is not scanned for.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $repo
try {
  $tracked = @(git ls-files) | Where-Object {
    $_ -notmatch '^docs/' -and
    $_ -ne 'PRIVACY.md' -and
    $_ -ne 'TERMS.md' -and
    $_ -ne 'tests/no-personal-values.Tests.ps1'   # this file names the patterns it hunts
  }
  Assert ($tracked.Count -gt 10) "git ls-files returned a sane file list (got $($tracked.Count))"

  # person/machine-specific values that must never appear in reusable source
  $patterns = @(
    'C:\\Users\\Alex',                     # absolute paths from the maintainer's machine
    'C:/Users/Alex',
    'aleksandrs\.drozdovs2005',            # personal email (any domain spelling)
    'com\.alexdrozdovs',                   # personal Windows AppUserModelId
    '12-jarvis',                           # the maintainer's personal vault folder numbering
    'claude-memory',                       # the maintainer's personal vault root name
    'Life Roadmap'                         # the maintainer's personal planning doc
  )

  # Positive control: the scan must actually catch a planted personal value. A guard that
  # scans and finds nothing proves nothing unless it is first shown finding something.
  $control = Join-Path $env:TEMP ("npv-control-{0}.txt" -f [guid]::NewGuid())
  Set-Content -Path $control -Value 'see C:\Users\Alex\secret and 12-jarvis notes' -Encoding ASCII
  try {
    $caught = 0
    foreach ($p in $patterns) {
      if (Select-String -Path $control -Pattern $p -ErrorAction SilentlyContinue) { $caught++ }
    }
    Assert ($caught -ge 2) "positive control: planted personal values must be caught (caught $caught patterns)"
  } finally { Remove-Item $control -Force -ErrorAction SilentlyContinue }

  $hits = New-Object System.Collections.Generic.List[string]
  foreach ($f in $tracked) {
    if (-not (Test-Path $f)) { continue }
    foreach ($p in $patterns) {
      $m = Select-String -Path $f -Pattern $p -AllMatches -ErrorAction SilentlyContinue
      foreach ($line in $m) { $hits.Add(("{0}:{1}  [{2}]" -f $f, $line.LineNumber, $p)) }
    }
  }

  if ($hits.Count -gt 0) {
    Write-Host "Personal values found in tracked source ($($hits.Count) hits):"
    $hits | ForEach-Object { Write-Host ("  " + $_) }
  }
  Assert ($hits.Count -eq 0) "tracked source must contain no personal paths/emails/app-ids ($($hits.Count) hits above)"
  Write-Host "no-personal-values: ALL PASS"
} finally { Pop-Location }
