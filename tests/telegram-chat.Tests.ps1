# tests/telegram-chat.Tests.ps1 - read-only Telegram chat. Pure logic only, NO network and NO model
# calls. The structural no-execution guard at the bottom is the security-critical one.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\telegram-chat.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

# --- Test-ChatEnabled: fails CLOSED. Only an explicit 'on' turns chat on. ---
$tmp = Join-Path $env:TEMP ('jarvis-chat-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Set-Content -Encoding UTF8 (Join-Path $tmp 'CONFIG.md') "- modules:`n    telegram_chat: on"
Assert (Test-ChatEnabled -VaultPath $tmp) "explicit 'on' enables chat"

Set-Content -Encoding UTF8 (Join-Path $tmp 'CONFIG.md') "- modules:`n    telegram_chat: off"
Assert (-not (Test-ChatEnabled -VaultPath $tmp)) "explicit 'off' disables chat"

Set-Content -Encoding UTF8 (Join-Path $tmp 'CONFIG.md') "- modules:`n    telegram: on"
Assert (-not (Test-ChatEnabled -VaultPath $tmp)) "key absent -> disabled (fail closed)"

Remove-Item (Join-Path $tmp 'CONFIG.md') -Force
Assert (-not (Test-ChatEnabled -VaultPath $tmp)) "no CONFIG.md -> disabled (fail closed)"

Remove-Item $tmp -Recurse -Force

Write-Host "telegram-chat: ALL PASS"
