# skill/bin/store-claude-token.ps1
# Stores the Claude Code OAuth token (from `claude setup-token`) as a DPAPI-encrypted SecureString at
# ~/.jarvis/claude-token.xml, in the EXACT shape the headless 08:30 briefing (jarvis-debrief.ps1) and the
# desktop chat (app/lib/chat.js) read it: Import-Clixml -> SecureString -> PSCredential('t', $sec).
# Without this file, headless `claude -p` runs get a 401 and both the briefing and chat are dead - so it
# is a required onboarding step, not optional. The token is a secret: never in the repo/vault, never
# echoed, never logged.
#
#   1. claude setup-token          # prints a long-lived subscription token
#   2. store-claude-token.ps1      # paste it when prompted (input is hidden)
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param([switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Save-ClaudeToken {
  param([Parameter(Mandatory)][securestring]$Token,
        [string]$Path = (Join-Path $HOME '.jarvis\claude-token.xml'))
  $dir = Split-Path $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  # Export-Clixml of a SecureString serializes it DPAPI-encrypted to this Windows user - the exact shape
  # Import-Clixml + PSCredential('t', $sec) expects on the read side. Store the BARE SecureString, not a
  # PSCredential (the consumers construct the credential themselves).
  $Token | Export-Clixml $Path
  return $Path
}

if ($DotSourceOnly) { return }
$sec = Read-Host -AsSecureString 'Paste your Claude token (from: claude setup-token)'
if ($null -eq $sec -or $sec.Length -eq 0) { throw 'No token entered - run `claude setup-token` first, then paste its output here.' }
$p = Save-ClaudeToken -Token $sec
Write-Host "Stored (DPAPI-encrypted to this Windows user): $p"
Write-Host 'The 08:30 briefing and desktop chat can now authenticate headlessly.'
