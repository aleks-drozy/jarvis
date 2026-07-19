# skill/bin/telegram-chat.ps1
# Read-only conversational Jarvis over Telegram. Dot-sourced by telegram-bot.ps1.
#
# THE SECURITY CONTRACT (spec DESIGN-TELEGRAM-CHAT sections 2 and 4): this file must never create a
# path from a text message to code execution. The agent is spawned with the allowlist 'Read Glob Grep'
# and nothing else; live data reaches it because PowerShell runs fixed, argument-free collectors HERE
# and injects their output as fenced data. A keyword scan picks WHICH collector by name; it never
# builds a command line and never passes message text as an argument. Changing the allowlist breaks
# the whole argument - tests/telegram-chat.Tests.ps1 fails the build if you do.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param([switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Test-ChatEnabled {
  # Is free-form chat turned on? Reads CONFIG.md 'telegram_chat'. Absent, unreadable, or anything other
  # than 'on' -> FALSE. Fails closed on purpose: the closed command whitelist stays the default and
  # chat is the exception. Same shape as Get-DebriefChannel in jarvis-debrief.ps1.
  param([string]$VaultPath)
  try {
    $cfgFile = Join-Path $VaultPath 'CONFIG.md'
    if (-not (Test-Path $cfgFile)) { return $false }
    $m = [regex]::Match((Get-Content -LiteralPath $cfgFile -Raw), '(?m)^\s*-?\s*telegram_chat:\s*(on|off)\b')
    if ($m.Success) { return ($m.Groups[1].Value.ToLower() -eq 'on') }
  } catch { }
  return $false
}

if ($DotSourceOnly) { return }
