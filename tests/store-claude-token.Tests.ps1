# tests/store-claude-token.Tests.ps1 - the Claude token must be stored in EXACTLY the shape the headless
# briefing (jarvis-debrief.ps1) and desktop chat (app/lib/chat.js) read it back:
#   Import-Clixml -> SecureString -> PSCredential('t', $sec).GetNetworkCredential().Password
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\store-claude-token.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$tmp = Join-Path $env:TEMP ("jarvis-token-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
try {
  $secret = 'sk-ant-oat-EXAMPLE-token-value-12345'
  $sec = ConvertTo-SecureString $secret -AsPlainText -Force
  $p = Save-ClaudeToken -Token $sec -Path $tmp
  Assert (Test-Path $p) "token file written"
  # read it back the EXACT way both consumers do - if the shape is wrong, this throws or mismatches
  $readSec = Import-Clixml $p
  $plain = (New-Object System.Management.Automation.PSCredential('t', $readSec)).GetNetworkCredential().Password
  Assert ($plain -eq $secret) "round-trips to the exact plaintext the consumers expect (got '$plain')"
  # it must be a BARE SecureString, not a PSCredential (the consumers wrap it themselves)
  Assert ($readSec -is [System.Security.SecureString]) "stored object is a bare SecureString"
  # creates the parent directory if absent
  $newRoot = Join-Path ([IO.Path]::GetTempPath()) ("jarvis-tok-newdir-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
  $tmp2 = Join-Path $newRoot 'sub\token.xml'
  $p2 = Save-ClaudeToken -Token $sec -Path $tmp2
  Assert (Test-Path $p2) "creates missing parent directory"
  Remove-Item $newRoot -Recurse -Force -ErrorAction SilentlyContinue
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
Write-Host "store-claude-token: ALL PASS"
