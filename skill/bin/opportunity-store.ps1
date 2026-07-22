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
  #
  # CARRIED FIX (Task 2 review): joining as "$From|$Subject|$Date" is ambiguous - Subject is
  # attacker-controlled (see file header), and a pipe inside it can shift the field boundary so two
  # STRUCTURALLY DIFFERENT triples land on the SAME seed, e.g. ('a','b|c','d') and ('a|b','c','d')
  # both used to join to "a|b|c|d". That is the inverse of a duplicate push: a genuinely new
  # opportunity gets silently treated as already-seen and never pushed. Length-prefixing each field
  # makes the join unambiguous - no field's content can forge a delimiter, because the exact number
  # of characters that belong to it is stated before it.
  param([string]$From, [string]$Subject, [string]$Date)
  $seed = ("$($From.Length):$From|$($Subject.Length):$Subject|$($Date.Length):$Date").ToLower()
  $sha  = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    return (($bytes[0..2] | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

function Read-OpportunityStore {
  # Absent or empty read as an empty set rather than throwing. A broken store must not crash the
  # sweep: a lost record is bad, a lost opportunity is worse.
  #
  # CRITICAL-2 FIX (review): CORRUPT used to also read as a silent empty set, and the caller then
  # unconditionally wrote that empty set back over the file - one interrupted write destroyed every
  # record, and the only signal was a Write-Warning the hidden wscript launcher discards. The spec
  # (DESIGN-OPPORTUNITY-ALARM.md, vault 12-jarvis, S4) requires "fail loud in the log... a lost record must not become a lost
  # opportunity." Now a parse failure QUARANTINES the bad file (renamed to <path>.corrupt-<timestamp>,
  # never deleted) before returning empty, and sets -WasCorrupt so the caller can skip persisting this
  # run entirely rather than clobbering the quarantined evidence with a reconstructed-from-nothing
  # store. -WasCorrupt is an OPTIONAL [ref]: existing callers that never pass it see byte-identical
  # behaviour (empty array on corrupt, same as before this fix).
  param([string]$Path = (Get-OpportunityStorePath), [ref]$WasCorrupt)
  if ($WasCorrupt) { $WasCorrupt.Value = $false }
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
    Write-Warning "opportunity store unreadable, quarantining and treating as empty: $($_.Exception.Message)"
    if ($WasCorrupt) { $WasCorrupt.Value = $true }
    try {
      $quarantine = "$Path.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
      Move-Item -LiteralPath $Path -Destination $quarantine -Force
      Write-Warning "corrupt opportunity store quarantined (not deleted) to $quarantine"
    } catch {
      # Quarantining itself must never crash the sweep either - worst case the bad file just sits
      # there and the next read hits the same catch again.
      Write-Warning "could not quarantine corrupt opportunity store at $Path : $($_.Exception.Message)"
    }
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
  # CRITICAL-2 FIX (review, atomic write): write to a throwaway temp file first, then Move-Item -Force
  # onto the real path. A direct Set-Content onto $Path has a window where the file is truncated and
  # only partially rewritten - an interruption in exactly that window (power loss, a killed process)
  # is how a store goes corrupt in the first place, which Read-OpportunityStore's quarantine path now
  # has to clean up after. Move-Item on the same volume is a single filesystem rename: any reader sees
  # either the fully-old or fully-new file, never a partial one. This also closes the concurrent-read
  # window against telegram-bot.ps1's poller (Invoke-PollOnce runs on a ~3-minute schedule and can call
  # Read-OpportunityStore at any time via the clear-opportunity command).
  $tmpPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  Set-Content -Encoding UTF8 -LiteralPath $tmpPath -Value $json
  Move-Item -LiteralPath $tmpPath -Destination $Path -Force
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

# ---------- sweep-window memory (CRITICAL-1 fix) ----------
# WHY THIS EXISTS. Owner works UPS night shifts - the laptop is closed for long stretches, sometimes a
# whole weekend. A fixed 24h mail-search window means a catch-up sweep after the laptop reopens only
# looks back to "yesterday" - anything that arrived the day before that is never fetched, never
# classified, never pushed. Not late: permanently missed. Persisting WHEN the last sweep last actually
# succeeded lets the next sweep size its window to the real gap instead.

function Get-OpportunitySweepStatePath { return (Join-Path $HOME '.jarvis\opportunity-sweep-state.json') }

function Read-OpportunitySweepState {
  # Returns the last successful sweep's timestamp as [datetime], or $null if there is no usable one
  # (never run before, or the state file is missing/empty/corrupt). Corrupt-as-null is deliberate and
  # safe here, unlike the opportunity store itself: Get-OpportunitySweepWindowHours treats a null
  # LastSweepAt as "never swept", which resolves to the CEILING (widest, safest) window - the same
  # erring-wide-is-safe property the store's id dedupe already gives duplicate pushes.
  param([string]$Path = (Get-OpportunitySweepStatePath))
  if (-not (Test-Path $Path)) { return $null }
  try {
    $raw = (Get-Content -LiteralPath $Path -Raw) -replace ('^' + [char]0xFEFF), ''
    if (-not $raw.Trim()) { return $null }
    $parsed = $raw | ConvertFrom-Json
    if (-not $parsed -or -not $parsed.lastSweepAt) { return $null }
    return [datetime]::Parse($parsed.lastSweepAt)
  } catch { return $null }
}

function Write-OpportunitySweepState {
  # Best-effort and atomic (same reasoning as Write-OpportunityStore). Must NEVER throw: a failure to
  # persist "when did we last sweep" must not take out the sweep that just succeeded.
  param([datetime]$LastSweepAt, [string]$Path = (Get-OpportunitySweepStatePath))
  try {
    $dir = Split-Path $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = [pscustomobject]@{ lastSweepAt = $LastSweepAt.ToString('s') } | ConvertTo-Json -Compress
    $tmpPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    Set-Content -Encoding UTF8 -LiteralPath $tmpPath -Value $json
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
  } catch { }
}

function Get-OpportunitySweepWindowHours {
  # Sizes the mail-search window to the ACTUAL gap since the last successful sweep, instead of a fixed
  # 24h. Laptop closed Friday 18:00, reopened Monday 09:00: the gap is ~63h, so this returns ~63 (not
  # 24) - wide enough that check-job-mail.ps1's SEARCH SINCE covers Saturday. The store's id dedupe
  # (Get-OpportunityId) makes a wide window free of duplicate pushes, so erring wide costs nothing.
  #   Floor:   never shrink below the original design's minimum coverage, and guards a near-zero or
  #            negative gap (clock skew, an immediate re-run).
  #   Ceiling: never grow unbounded from a missing/ancient/corrupt state file - bounds one run to a
  #            still-generous but finite historical trawl.
  # NOTE: deliberately NOT typed [Nullable[datetime]] - PowerShell unwraps a non-null argument straight
  # to a plain [datetime] at the call boundary (verified: .GetType() reports System.DateTime, not the
  # nullable wrapper), so a later ".Value" on it silently resolves to $null and "$Now - $null" throws
  # "Cannot find an overload for op_Subtraction". Leaving the parameter untyped accepts both $null and
  # a real [datetime] without that trap; the cast happens explicitly below instead.
  param($LastSweepAt, [datetime]$Now, [int]$FloorHours = 24, [int]$CeilingHours = 336)
  if ($null -eq $LastSweepAt) { return $CeilingHours }
  $gapHours = [math]::Ceiling(($Now - [datetime]$LastSweepAt).TotalHours)
  if ($gapHours -lt $FloorHours)   { return $FloorHours }
  if ($gapHours -gt $CeilingHours) { return $CeilingHours }
  return [int]$gapHours
}

# ---------- heartbeat (IMPORTANT-3 fix) ----------
# Every sweep failure used to be swallowed into a Write-Warning the hidden wscript launcher discards,
# and the script always exits 0 - so Task Scheduler reports success forever even after (say) the Gmail
# app password expires and the sweep has gone quiet for good. Same convention as get-bank-data.ps1's
# Write-BankHeartbeat, surfaced in Get-StatusText (telegram-bot.ps1) alongside the bank heartbeat.

function Get-OpportunityHeartbeatPath { return (Join-Path $HOME '.jarvis\opportunity-heartbeat.json') }

function Write-OpportunityHeartbeat {
  # Best-effort: a heartbeat write must NEVER affect the sweep's return value or exit-0 contract.
  param([string]$Path = (Get-OpportunityHeartbeatPath), [bool]$Ok, [string]$ErrorMsg, [int]$OpenCount, [datetime]$Now = (Get-Date))
  try {
    $dir = Split-Path $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [pscustomobject]@{ asOf = $Now.ToString('s'); ok = $Ok; error = $ErrorMsg; openCount = $OpenCount } |
      ConvertTo-Json -Compress | Set-Content -Encoding UTF8 -LiteralPath $Path
  } catch { }
}

if ($DotSourceOnly) { return }
