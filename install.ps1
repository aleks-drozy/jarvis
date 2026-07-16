# install.ps1 - configure + deploy the Jarvis skill for THIS machine.
#
#   powershell -File install.ps1                      first run prompts for your paths, then deploys
#   powershell -File install.ps1 -InitVault           also seed a starter vault (never overwrites files)
#   powershell -File install.ps1 -VaultPath ... -OwnerEmail ...   non-interactive first-time setup
#
# What it does:
#   1. Ensures ~/.jarvis/config.json exists (prompting or taking params for: vault path, projects root,
#      job-search dir, owner email). This file holds PATHS AND AN EMAIL - never secrets; credentials
#      live in separate DPAPI-encrypted files (see DEPENDENCIES.md).
#   2. Renders the skill markdown: {{VAULT}} / {{BIN}} / {{JOB_SEARCH_DIR}} become YOUR configured
#      paths (Claude follows literal paths best). Code (.ps1/.vbs/.js) is copied verbatim - it reads
#      the same config at runtime.
#   3. Mirrors the rendered skill into the Claude Code skills directory.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param(
  [string]$ConfigPath = (Join-Path $HOME '.jarvis\config.json'),
  [string]$TargetDir = '',
  [string]$VaultPath = '', [string]$ProjectsRoot = '', [string]$JobSearchDir = '', [string]$OwnerEmail = '',
  [switch]$InitVault
)
$ErrorActionPreference = 'Stop'
$repoSkill = Join-Path $PSScriptRoot 'skill'
. (Join-Path $repoSkill 'bin\get-jarvis-config.ps1')

# ---------- 1. ensure config ----------
$cfgDir = Split-Path $ConfigPath
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force $cfgDir | Out-Null }
if (-not (Test-Path $ConfigPath)) {
  Write-Host 'First-time setup: where should Jarvis live on this machine?'
  Write-Host '(paths are stored in plain JSON at ' -NoNewline; Write-Host $ConfigPath -NoNewline; Write-Host ' - no secrets go here)'
  $d = Get-JarvisConfigDefaults
  if (-not $VaultPath)    { $VaultPath    = Read-Host ("Vault path (the butler's markdown memory) [" + $d.vault_path + "]") }
  if (-not $VaultPath)    { $VaultPath    = $d.vault_path }
  if (-not $ProjectsRoot) { $ProjectsRoot = Read-Host ("Projects root (git repos to watch) [" + $d.projects_root + "]") }
  if (-not $ProjectsRoot) { $ProjectsRoot = $d.projects_root }
  if (-not $JobSearchDir) { $JobSearchDir = Read-Host ("Job-search dir (CV variants land here) [" + $d.job_search_dir + "]") }
  if (-not $JobSearchDir) { $JobSearchDir = $d.job_search_dir }
  if (-not $OwnerEmail)   { $OwnerEmail   = Read-Host 'Your email (the ONLY address Jarvis may ever send to; empty = email disabled)' }
  [ordered]@{
    vault_path = $VaultPath; projects_root = $ProjectsRoot; job_search_dir = $JobSearchDir
    skill_dir = $d.skill_dir; owner_email = $OwnerEmail; app_id = $d.app_id; roadmap_index = ''
  } | ConvertTo-Json | Set-Content -Encoding ASCII $ConfigPath
  Write-Host "Wrote $ConfigPath"
}
$cfg = Get-JarvisConfig -Path $ConfigPath
if (-not $TargetDir) { $TargetDir = $cfg.skill_dir }

# ---------- 2. render into staging ----------
$staging = Join-Path $env:TEMP ("jarvis-skill-staging-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
robocopy $repoSkill $staging /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "staging copy failed (robocopy exit $LASTEXITCODE)" }
$binPath = Join-Path $TargetDir 'bin'
$mdFiles = Get-ChildItem $staging -Recurse -Filter *.md
foreach ($f in $mdFiles) {
  # -Encoding UTF8 on the READ is load-bearing: PS 5.1 defaults to ANSI, and reading UTF-8 markdown
  # (em dashes, emoji) as ANSI then re-writing UTF-8 mojibakes every non-ASCII character
  $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
  $rendered = $raw.Replace('{{VAULT}}', $cfg.vault_path).Replace('{{BIN}}', $binPath).Replace('{{JOB_SEARCH_DIR}}', $cfg.job_search_dir)
  if ($rendered -ne $raw) { Set-Content -LiteralPath $f.FullName -Value $rendered -Encoding UTF8 -NoNewline }
}
# hard fail on any placeholder that survived rendering - a half-rendered skill reads garbage paths
$leftover = @($mdFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '\{\{[A-Z_]+\}\}' })
if ($leftover.Count -gt 0) { throw ("unrendered placeholders remain in: " + (($leftover | ForEach-Object Name) -join ', ')) }

# ---------- 3. deploy ----------
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
robocopy $staging $TargetDir /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "install failed (robocopy exit $LASTEXITCODE)" }
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
Write-Host "Jarvis skill installed to $TargetDir (vault: $($cfg.vault_path))"

# ---------- 4. optional vault skeleton (never overwrites) ----------
if ($InitVault) {
  $v = $cfg.vault_path
  New-Item -ItemType Directory -Force -Path $v | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $v 'debriefs') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $v 'outreach') | Out-Null
  function Seed($name, $content) {
    $p = Join-Path $v $name
    if (Test-Path $p) { return }   # NEVER clobber an existing vault file
    Set-Content -Encoding UTF8 -Path $p -Value $content
    Write-Host "  seeded $name"
  }
  Seed 'JARVIS.md' @'
# Jarvis Charter

## Who you are
(Fill in: your name, what you do, where you are. Jarvis reads this on every invocation.)

## Goals
- Career:
- Physical:
- Mental:
- Material:
- Projects:

## Mission
A truthful daily footing: what got done, what needs doing, one honest nudge. A butler, not a cheerleader.

## Non-negotiables
Hard limits (money, email, third-party content) live in the skill SKILL.md and cannot be overridden here.
'@
  Seed 'CONFIG.md' @'
# Jarvis Config

- address_term: Sir
- debrief_time: "08:30"
- debrief_delivery: email        # telegram | email | both
- modules:
    today: off                   # calendar (set up get-calendar.ps1 first)
    inbox: off                   # Gmail IMAP (set up an app password first)
    projects_agents: on
    job_search: on
    life: on
    fitness: on
    finance: on
    finance_bank: off            # read-only bank feed (see setup-bank.ps1)
    suggestions: on
    telegram: off                # remote bridge (see telegram-bot.ps1 -StoreCredential)
- allowed_write_targets: []      # paths outside this vault Jarvis may APPEND to (default: none)
- ignores: []                    # topics Jarvis must stop raising
'@
  Seed 'JOB_SEARCH.md' "# Job search tracker`n`n| Company | Role | Link | Applied | Status | Follow-up due | Notes |`n|---|---|---|---|---|---|---|`n"
  Seed 'FINANCE.md' "# Finance (Jarvis-maintained)`n`nTell Jarvis your numbers in plain words; he does the math and keeps this file current.`n`n## Goals`n`n## Snapshot`n| Item | Amount | As of |`n|---|---|---|`n`n## Budget`n`n## Log`n"
  Seed 'FITNESS.md' "# Fitness (Jarvis-maintained)`n`nSay 'log workout: ...' and Jarvis appends it here.`n`n## Weekly target`n`n## Bodyweight log`n| Date | Weight | Note |`n|---|---|---|`n`n## Session log`n| Date | Type | Focus | Duration | Felt |`n|---|---|---|---|---|`n"
  Seed 'SUGGESTIONS.md' "# Suggestions backlog`n`nJarvis appends <=1 idea/day, keyed by date.`n"
  Seed 'LEDGER.md' "# Ledger - recurring nudges`n`n| topic | first_raised | times_raised | status | notes |`n|---|---|---|---|---|`n"
  Seed 'CAPTURE.md' "# Capture (quick notes texted in on the go)`n`n<!-- entries: - [YYYY-MM-DD HH:mm] <note> -->`n"
  Write-Host "Vault skeleton ready at $v (existing files were left untouched)."
}
