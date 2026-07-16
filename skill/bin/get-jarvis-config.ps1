# skill/bin/get-jarvis-config.ps1
# THE single source of truth for machine/person-specific values. Every script reads this instead of
# hardcoding a path or an email (enforced by tests/no-personal-values.Tests.ps1). The mirror-image Node
# loader is app/lib/config.js - keep their defaults IDENTICAL (a parity test compares them).
#
# Config file: ~/.jarvis/config.json - created by install.ps1, DPAPI-free (it holds paths and an email,
# not secrets; secrets stay in the separate ~/.jarvis/*.cred.xml files).
# Missing file  -> generic HOME-derived defaults with an EMPTY owner_email, so the self-only send locks
#                  fail CLOSED rather than defaulting to anyone.
# Corrupt file  -> throws loudly. Silently falling back to default paths would read/write the wrong
#                  vault without anyone noticing - the exact "quiet confident wrong" failure this
#                  project keeps refusing to ship.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
#
# DELIBERATELY NO param BLOCK: dot-sourcing runs in the CALLER's scope, so a param here (e.g. the
# house -DotSourceOnly convention) would CLOBBER the caller's variable of the same name - which made
# telegram-bot.ps1 -Once exit silently before doing anything (caught live 2026-07-16; same trap
# setup-bank.ps1 documents). Dot-source this file PLAIN: it only defines functions. Run directly,
# it prints the resolved config as JSON.
$ErrorActionPreference = 'Stop'

function Get-JarvisConfigDefaults {
  # keep in lockstep with DEFAULTS in app/lib/config.js
  return [ordered]@{
    vault_path     = (Join-Path $HOME 'JarvisVault\jarvis')     # the butler's memory (Obsidian-style markdown dir)
    projects_root  = (Join-Path $HOME 'Projects')               # where collect-activity discovers git repos
    job_search_dir = (Join-Path $HOME 'Documents\Job Search')   # where per-role CV variants are written
    skill_dir      = (Join-Path $HOME '.claude\skills\jarvis')  # where install.ps1 puts the rendered skill
    owner_email    = ''                                         # self-only lock target; EMPTY = refuse all sends
    app_id         = 'com.jarvis.assistant'                     # Windows AppUserModelId for notifications
    roadmap_index  = ''                                         # optional: a personal roadmap note the dashboard may show; empty = feature off
  }
}

function Get-JarvisConfig {
  param([string]$Path = (Join-Path $HOME '.jarvis\config.json'))
  $cfg = Get-JarvisConfigDefaults
  if (Test-Path $Path) {
    # strip a UTF-8 BOM before parsing: PS 5.1's Set-Content -Encoding UTF8 writes one, and
    # ConvertFrom-Json rejects it (the bank-heartbeat lesson, learned live 2026-07-15)
    $raw = (Get-Content -LiteralPath $Path -Raw) -replace ('^' + [char]0xFEFF), ''
    $file = $raw | ConvertFrom-Json   # corrupt JSON throws here - deliberately loud
    foreach ($key in @($cfg.Keys)) {
      $prop = $file.PSObject.Properties[$key]
      if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { $cfg[$key] = $prop.Value }
    }
  }
  return [pscustomobject]$cfg
}

# print only when RUN directly (powershell -File ...); when dot-sourced, InvocationName is '.'
if ($MyInvocation.InvocationName -ne '.') { Get-JarvisConfig | ConvertTo-Json }
