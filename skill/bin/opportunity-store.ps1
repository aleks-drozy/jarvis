# skill/bin/opportunity-store.ps1
# The memory behind the opportunity alarm. Pure record logic: no IMAP, no Telegram, no network.
#
# WHY THIS EXISTS. On 2026-07-10 a Susquehanna CodeSignal assessment invite expired unactioned - the
# only door that opened in 44 applications. Detection alone would not have saved it: Jarvis has to
# REMEMBER that something is open and keep saying so. This file is that memory.
#
# Records live in ~/.jarvis/opportunities.json - LOCAL ONLY, never the vault, never the repo. They
# carry email subjects, which are attacker-controlled and sometimes sensitive.
#
# Cleared records are KEPT, never deleted. The file is a memory, not a queue: deleting a 'done'
# record would let the same message be re-detected and pushed again.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param([switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Get-OpportunityStorePath { return (Join-Path $HOME '.jarvis\opportunities.json') }

function Get-OpportunityId {
  # Stable 6-hex-char id derived from the message itself, so the SAME message always lands on the same
  # id no matter how many times it is seen. That is the whole duplicate guard: an overlapping sweep, a
  # re-delivered message or a restarted task cannot produce a second push. This project already shipped
  # a duplicate-briefing incident (2026-07-16) from missing exactly this property.
  # Six chars is deliberate: Alex types it on a phone to clear a record.
  param([string]$From, [string]$Subject, [string]$Date)
  $seed = ("$From|$Subject|$Date").ToLower()
  $sha  = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    return (($bytes[0..2] | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

function Read-OpportunityStore {
  # Absent, empty or CORRUPT all read as an empty set rather than throwing. A broken store must not
  # crash the sweep: a lost record is bad, a lost opportunity is worse.
  param([string]$Path = (Get-OpportunityStorePath))
  if (-not (Test-Path $Path)) { return @() }
  try {
    $raw = (Get-Content -LiteralPath $Path -Raw) -replace ('^' + [char]0xFEFF), ''
    if (-not $raw.Trim()) { return @() }
    # NOTE: deliberately NOT "return @($raw | ConvertFrom-Json)" (inline, one step). ConvertFrom-Json
    # emits its whole parsed result as a single pipeline object; wrapping that pipeline expression
    # directly in @() inside a "return" produces an array that, once the caller ALSO wraps the call in
    # @() (as this store's own tests correctly do, to guard the "unknown count" case), nests one level
    # deep regardless of record count - verified to reproduce identically for 1 and 2 records. Parsing
    # to a local variable FIRST and wrapping THAT avoids the nesting.
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed)
  } catch {
    Write-Warning "opportunity store unreadable, treating as empty: $($_.Exception.Message)"
    return @()
  }
}

function Write-OpportunityStore {
  # NOTE: deliberately NOT ",@($Records) | ConvertTo-Json" - piping a single-element array into
  # ConvertTo-Json collapses one level of unrolling and serializes it as a {value,Count} wrapper
  # object instead of a JSON array (verified: reproduces for both 1- and 2-element arrays; PS 5.1
  # pipeline semantics, not a Depth issue). Passing -InputObject directly avoids the pipeline
  # unroll entirely and always yields a proper JSON array, including for zero records.
  param($Records, [string]$Path = (Get-OpportunityStorePath))
  $dir = Split-Path $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $json = ConvertTo-Json -InputObject @($Records) -Depth 5
  Set-Content -Encoding UTF8 -LiteralPath $Path -Value $json
}

function Add-Opportunity {
  # Returns @{ Records = <updated>; IsNew = <bool> }. IsNew drives the immediate push, so the
  # already-seen path must be exact - see Get-OpportunityId.
  param($Records, [string]$From, [string]$Subject, [string]$Date, [datetime]$Now)
  $list = @($Records)
  $id = Get-OpportunityId -From $From -Subject $Subject -Date $Date
  if (@($list | Where-Object { $_.Id -eq $id }).Count -gt 0) {
    return @{ Records = $list; IsNew = $false }
  }
  $list += [pscustomobject]@{
    Id         = $id
    From       = $From
    Subject    = $Subject
    Date       = $Date
    Status     = 'open'
    FirstSeen  = $Now.ToString('s')
    LastPushed = $Now.ToString('s')
  }
  return @{ Records = $list; IsNew = $true }
}

function Set-OpportunityStatus {
  # Returns @{ Records = <updated>; Found = <bool> }. An unknown id is NOT an error - Alex may mistype
  # on a phone, and the caller answers him rather than throwing.
  param($Records, [string]$Id, [string]$Status)
  $list = @($Records); $found = $false
  foreach ($r in $list) {
    if ($r.Id -eq $Id) { $r.Status = $Status; $found = $true }
  }
  return @{ Records = $list; Found = $found }
}

function Get-OpportunitiesNeedingReminder {
  # Open, and not already pushed today. One reminder per DAY, not per sweep - the sweep runs hourly and
  # a reminder every hour would train Alex to ignore it, which is how alarms die.
  param($Records, [datetime]$Now)
  $today = $Now.Date
  return @(@($Records) | Where-Object {
    $_.Status -eq 'open' -and (
      -not $_.LastPushed -or ([datetime]::Parse($_.LastPushed)).Date -lt $today
    )
  })
}

if ($DotSourceOnly) { return }
