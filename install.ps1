# install.ps1 — copy skill/* into ~/.claude/skills/jarvis
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'skill'
$dst = Join-Path $HOME '.claude\skills\jarvis'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
# mirror skill/ into dst (copy, delete removed files)
robocopy $src $dst /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "install failed (robocopy exit $LASTEXITCODE)" }
Write-Host "Jarvis skill installed to $dst"
