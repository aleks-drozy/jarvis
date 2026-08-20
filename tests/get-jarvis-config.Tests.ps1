# tests/get-jarvis-config.Tests.ps1 - the single-source-of-truth config loader, PS and Node sides.
# Every machine/person-specific value (vault path, owner email, projects root, app id) comes from
# ~/.jarvis/config.json via these loaders; nothing may hardcode them (enforced by no-personal-values).
$ErrorActionPreference = 'Stop'
# CALLER-SCOPE POLLUTION GUARD: dot-sourcing runs in the caller's scope, so the loader must have NO
# param block and set NO variables the caller might own. A param([switch]$DotSourceOnly) here once
# clobbered telegram-bot.ps1's own $DotSourceOnly and made `-Once` exit silently (live, 2026-07-16).
$DotSourceOnly = 'sentinel-must-survive'
. "$PSScriptRoot\..\skill\bin\get-jarvis-config.ps1"
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }
Assert ($DotSourceOnly -eq 'sentinel-must-survive') "dot-sourcing the loader must not touch the caller's variables (got '$DotSourceOnly')"
Remove-Variable DotSourceOnly

$tmpDir = Join-Path $env:TEMP ("jarvis-config-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $tmpDir | Out-Null
try {
  # 1) missing file -> generic defaults, fail-safe: owner_email EMPTY (self-only locks fail closed)
  $cfg = Get-JarvisConfig -Path (Join-Path $tmpDir 'nope.json')
  Assert ($cfg.owner_email -eq '') "missing config -> empty owner_email (locks fail closed), got '$($cfg.owner_email)'"
  Assert ($cfg.vault_path -like "$HOME*") "default vault_path is under HOME, got '$($cfg.vault_path)'"
  Assert ($cfg.projects_root -like "$HOME*") "default projects_root is under HOME"
  Assert ($cfg.app_id -eq 'com.jarvis.assistant') "default app_id is generic"
  Assert ($cfg.skill_dir -like "$HOME*") "default skill_dir is under HOME"
  Assert ($cfg.staging_enabled -eq $false) "default staging_enabled is off (Night Shift is opt-in)"
  Assert ($cfg.staging_hour -eq 3) "default staging_hour is 3 (03:30 local)"

  # 2) full file -> file values win
  $file = Join-Path $tmpDir 'config.json'
  @{ vault_path = 'D:\SomeVault\jarvis'; owner_email = 'owner@example.com'
     projects_root = 'D:\Code'; job_search_dir = 'D:\Jobs'; app_id = 'com.example.jarvis'
     staging_enabled = $true; staging_hour = 4 } |
    ConvertTo-Json | Set-Content -Encoding ASCII $file
  $cfg = Get-JarvisConfig -Path $file
  Assert ($cfg.vault_path -eq 'D:\SomeVault\jarvis') "vault_path from file"
  Assert ($cfg.owner_email -eq 'owner@example.com') "owner_email from file"
  Assert ($cfg.app_id -eq 'com.example.jarvis') "app_id from file"
  Assert ($cfg.staging_enabled -eq $true) "staging_enabled from file"
  Assert ($cfg.staging_hour -eq 4) "staging_hour from file"

  # 3) partial file -> named keys from file, the rest fall back to defaults
  @{ owner_email = 'p@example.com' } | ConvertTo-Json | Set-Content -Encoding ASCII $file
  $cfg = Get-JarvisConfig -Path $file
  Assert ($cfg.owner_email -eq 'p@example.com') "partial: file key wins"
  Assert ($cfg.projects_root -like "$HOME*") "partial: absent key falls back to default"

  # 4) UTF-8 BOM (what PS 5.1 Set-Content -Encoding UTF8 writes) must parse - the bank-heartbeat lesson
  $bom = [byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::ASCII.GetBytes('{"owner_email":"bom@example.com"}')
  [IO.File]::WriteAllBytes($file, $bom)
  $cfg = Get-JarvisConfig -Path $file
  Assert ($cfg.owner_email -eq 'bom@example.com') "BOM-prefixed config parses"

  # 5) CORRUPT file must THROW, never silently fall back to defaults (silent wrong paths are the
  #    "quiet confident wrong" failure this project keeps refusing to ship)
  Set-Content -Encoding ASCII $file 'this is not json {'
  $threw = $false
  try { Get-JarvisConfig -Path $file | Out-Null } catch { $threw = $true }
  Assert $threw "corrupt config throws loudly instead of silently defaulting"

  # 6) Node loader parity: app/lib/config.js must expose the SAME defaults and read the same file
  $node = Get-Command node -ErrorAction SilentlyContinue
  Assert ($null -ne $node) "node on PATH"
  $repo = Resolve-Path (Join-Path $PSScriptRoot '..')
  @{ vault_path = 'D:\SomeVault\jarvis'; owner_email = 'owner@example.com'; staging_enabled = $true; staging_hour = 4 } |
    ConvertTo-Json | Set-Content -Encoding ASCII $file
  $js = "const c=require(process.argv[1])(process.argv[2]); console.log(JSON.stringify({v:c.vault_path,o:c.owner_email,a:c.app_id,se:c.staging_enabled,sh:c.staging_hour}));"
  $out = & node -e $js "$repo\app\lib\config.js" $file
  $parsed = $out | ConvertFrom-Json
  Assert ($parsed.v -eq 'D:\SomeVault\jarvis') "node loader reads the same file (vault)"
  Assert ($parsed.o -eq 'owner@example.com') "node loader reads the same file (email)"
  Assert ($parsed.a -eq 'com.jarvis.assistant') "node loader falls back to the SAME generic app_id default"
  Assert ($parsed.se -eq $true) "node loader reads the same file (staging_enabled)"
  Assert ($parsed.sh -eq 4) "node loader reads the same file (staging_hour)"

  # 6b) FULL default-key-set parity: the 3 spot-checks above only prove those 3 keys match. A key
  #     added to only ONE loader would slip past them silently. Compare the ENTIRE default object -
  #     same key names, same count, same values - so drift on any key (not just the 3 sampled ones)
  #     fails loudly and names the offending key. This is what makes the README's "cannot drift
  #     apart" claim (around line 440) true rather than aspirational.
  $psDefaults = Get-JarvisConfigDefaults | ConvertTo-Json | ConvertFrom-Json
  $missingFile = Join-Path $tmpDir ("missing-" + [Guid]::NewGuid().ToString('N') + '.json')
  Assert (-not (Test-Path $missingFile)) "full parity fixture path must not exist, got an existing path '$missingFile'"
  $jsFull = "const c=require(process.argv[1])(process.argv[2]); console.log(JSON.stringify(c));"
  $jsOut = & node -e $jsFull "$repo\app\lib\config.js" $missingFile
  $jsDefaults = $jsOut | ConvertFrom-Json

  $psKeys = @($psDefaults.PSObject.Properties.Name | Sort-Object)
  $jsKeys = @($jsDefaults.PSObject.Properties.Name | Sort-Object)
  Assert ($psKeys.Count -eq $jsKeys.Count) "full parity: key COUNT differs - PS (Get-JarvisConfigDefaults) has $($psKeys.Count) keys [$($psKeys -join ', ')], JS (config.js DEFAULTS) has $($jsKeys.Count) keys [$($jsKeys -join ', ')]"
  $onlyInPs = @($psKeys | Where-Object { $jsKeys -notcontains $_ })
  $onlyInJs = @($jsKeys | Where-Object { $psKeys -notcontains $_ })
  Assert ($onlyInPs.Count -eq 0) "full parity: key(s) present in PS defaults but missing from JS defaults: $($onlyInPs -join ', ')"
  Assert ($onlyInJs.Count -eq 0) "full parity: key(s) present in JS defaults but missing from PS defaults: $($onlyInJs -join ', ')"

  foreach ($key in $psKeys) {
    $psVal = "$($psDefaults.$key)"
    $jsVal = "$($jsDefaults.$key)"
    Assert ($psVal -eq $jsVal) "full parity: default value for key '$key' differs - PS='$psVal' JS='$jsVal'"
  }

  # corrupt file must throw in node too
  Set-Content -Encoding ASCII $file 'nope {'
  $out2 = cmd /c "node -e `"try{require(process.argv[1])(process.argv[2]);console.log('NOTHREW')}catch(e){console.log('THREW')}`" `"$repo\app\lib\config.js`" `"$file`" 2>&1"
  Assert ("$out2" -match 'THREW') "node loader throws on corrupt config (got: $out2)"
} finally { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
Write-Host "get-jarvis-config: ALL PASS"
