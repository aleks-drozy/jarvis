# tests/install-render.Tests.ps1 - install.ps1 must render {{VAULT}}/{{BIN}}/{{JOB_SEARCH_DIR}} into
# real configured paths and deploy a working skill dir. Runs against TEMP config + TEMP target only -
# never touches the real installed skill.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$tmp  = Join-Path $env:TEMP ("jarvis-install-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  $cfgPath = Join-Path $tmp 'config.json'
  $target  = Join-Path $tmp 'installed-skill'
  $vault   = Join-Path $tmp 'vault'
  @{ vault_path = $vault; owner_email = 'stranger@example.com'; projects_root = (Join-Path $tmp 'proj')
     job_search_dir = (Join-Path $tmp 'jobs'); skill_dir = $target } |
    ConvertTo-Json | Set-Content -Encoding ASCII $cfgPath

  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') `
      -ConfigPath $cfgPath -TargetDir $target | Out-Null
  Assert ($LASTEXITCODE -eq 0) "install.ps1 exits 0 (got $LASTEXITCODE)"

  # rendered markdown: placeholders replaced with the CONFIGURED paths, none left behind
  $skillMd = Get-Content (Join-Path $target 'SKILL.md') -Raw -Encoding UTF8
  Assert ($skillMd -notmatch '\{\{') "no unrendered placeholders in SKILL.md"
  Assert ($skillMd.Contains($vault)) "SKILL.md carries the configured vault path"
  # encoding regression: reading UTF-8 as ANSI then re-writing UTF-8 turns an em dash into "a-circumflex
  # + junk" (U+00E2 ...). The rendered file must not contain that mojibake signature.
  Assert ($skillMd.IndexOf([string][char]0xE2) -lt 0) "rendered SKILL.md is not mojibaked (UTF-8 read/write preserved)"
  $debrief = Get-Content (Join-Path $target 'references\debrief.md') -Raw
  Assert ($debrief -notmatch '\{\{') "no unrendered placeholders in debrief.md"
  Assert ($debrief.Contains($vault)) "debrief.md carries the configured vault path"
  $jobHunter = Get-Content (Join-Path $target 'references\job-hunter.md') -Raw
  Assert ($jobHunter.Contains((Join-Path $tmp 'jobs'))) "job-hunter.md carries the configured job_search_dir"

  # code ships unrendered and complete: bin scripts + the hidden launcher present and byte-identical
  Assert (Test-Path (Join-Path $target 'bin\telegram-bot.ps1')) "bin scripts deployed"
  Assert (Test-Path (Join-Path $target 'bin\telegram-bot-hidden.vbs')) "hidden launcher deployed"
  Assert (Test-Path (Join-Path $target 'bin\get-jarvis-config.ps1')) "config loader deployed"
  $srcBot = Get-Content (Join-Path $repo 'skill\bin\telegram-bot.ps1') -Raw
  $dstBot = Get-Content (Join-Path $target 'bin\telegram-bot.ps1') -Raw
  Assert ($srcBot -eq $dstBot) "bin/*.ps1 are copied verbatim, never templated"

  # -InitVault seeds a usable vault skeleton for a stranger
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') `
      -ConfigPath $cfgPath -TargetDir $target -InitVault | Out-Null
  Assert ($LASTEXITCODE -eq 0) "install.ps1 -InitVault exits 0"
  foreach ($f in @('JARVIS.md','CONFIG.md','JOB_SEARCH.md','FINANCE.md','FITNESS.md','SUGGESTIONS.md','LEDGER.md','CAPTURE.md')) {
    Assert (Test-Path (Join-Path $vault $f)) "vault skeleton has $f"
  }
  Assert (Test-Path (Join-Path $vault 'debriefs')) "vault skeleton has debriefs/"
  # re-running -InitVault must NOT clobber existing vault content
  Set-Content -Encoding ASCII (Join-Path $vault 'FINANCE.md') 'MY REAL DATA'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') `
      -ConfigPath $cfgPath -TargetDir $target -InitVault | Out-Null
  Assert ((Get-Content (Join-Path $vault 'FINANCE.md') -Raw).Contains('MY REAL DATA')) "-InitVault never overwrites an existing vault file"
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host "install-render: ALL PASS"
