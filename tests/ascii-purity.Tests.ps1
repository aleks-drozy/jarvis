# tests/ascii-purity.Tests.ps1 - repo battle scar, widened from two files to the whole tree:
# EVERY tracked .ps1/.vbs must be pure ASCII. PS 5.1 reads .ps1 as ANSI, so a non-ASCII byte
# silently mis-decodes on a stranger's codepage. Originally enforced only for the two bank
# scripts (see get-bank-data.Tests.ps1's pointer); the guarantee was always meant to be
# repo-wide and now the enforcement is too.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

function Get-NonAsciiByteCount([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $bad = 0
  for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad++ } }
  return $bad
}

# Positive control: a scanner that cannot see a planted non-ASCII byte must not be trusted
# to report a clean tree.
$tmp = Join-Path $env:TEMP ("ascii-control-{0}.tmp" -f [guid]::NewGuid())
[IO.File]::WriteAllBytes($tmp, [byte[]](35, 32, 195, 169))   # "# " + UTF-8 e-acute
try {
  Assert ((Get-NonAsciiByteCount $tmp) -eq 2) "positive control: planted 2-byte UTF-8 char must count as 2"
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $repo
try {
  $files = @(git ls-files '*.ps1' '*.vbs')
  Assert ($files.Count -gt 30) "expected a sane script list from git ls-files (got $($files.Count))"
  $dirty = @()
  foreach ($f in $files) {
    $bad = Get-NonAsciiByteCount (Join-Path $repo $f)
    if ($bad -gt 0) { $dirty += ("{0} ({1} non-ASCII bytes)" -f $f, $bad) }
  }
  Assert ($dirty.Count -eq 0) ("every tracked .ps1/.vbs must be pure ASCII: " + ($dirty -join '; '))
  Write-Host "ascii-purity: ALL PASS"
} finally { Pop-Location }
