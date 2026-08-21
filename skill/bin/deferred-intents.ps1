# skill/bin/deferred-intents.ps1
# The deferred-intent ledger: things Alex said in passing during a debrief source (a "someday" he never
# asked Jarvis to track), detected by the agent, verified and owned by code, resurfaced later through
# the existing opportunity alarm. Pure record logic: no network, no Telegram, mirrors opportunity-store.ps1.
#
# WHY THIS EXISTS. A debrief agent reads Alex's sources every morning and sometimes sees a throwaway
# "I should really renew my residence permit before October" that nobody ever turned into a task. Jarvis
# forgets it the moment the debrief note is written. This file is the memory for exactly that class of
# utterance - proposed by the agent, verified against the actual on-disk source, bounded and owned by code.
#
# Records live in ~/.jarvis/deferred-intents.json - LOCAL ONLY, never the vault, never the repo. They
# carry verbatim personal utterances.
#
# AGENT PROPOSES, CODE ENFORCES: the agent may only append candidates to one staging JSON file
# (Get-DeferredIntentStagingPath). Code alone verifies the quote exists verbatim on disk in the cited
# vault file (Test-DeferredIntentCandidate), bounds the count per run, bounds the resurface window, owns
# the id/dedupe, and owns when a promotion happens. The agent never touches deferred-intents.json,
# opportunities.json, or Telegram.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param([switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Get-DeferredIntentStorePath { return (Join-Path $HOME '.jarvis\deferred-intents.json') }

function Get-DeferredIntentId {
  # Same ambiguity-proof length-prefixed join and 6-hex-char id as Get-OpportunityId
  # (opportunity-store.ps1:19-40) - a phone-typeable id, and immune to a delimiter forged inside an
  # attacker-influenceable field (here, a source-file path or a verbatim utterance).
  param([string]$Utterance, [string]$SourceFile, [string]$MentionedOn)
  $seed = ("$($Utterance.Length):$Utterance|$($SourceFile.Length):$SourceFile|$($MentionedOn.Length):$MentionedOn").ToLower()
  $sha  = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    return (($bytes[0..2] | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

function Read-DeferredIntentStore {
  # Byte-for-byte the opportunity-store pattern (Read-OpportunityStore, opportunity-store.ps1:42-84):
  # BOM strip, parse-to-local-then-@() (the PS 5.1 nesting trap), corrupt file quarantined to
  # <path>.corrupt-<timestamp> never deleted, -WasCorrupt set, empty on any failure.
  param([string]$Path = (Get-DeferredIntentStorePath), [ref]$WasCorrupt)
  if ($WasCorrupt) { $WasCorrupt.Value = $false }
  if (-not (Test-Path $Path)) { return @() }
  try {
    $raw = (Get-Content -LiteralPath $Path -Raw) -replace ('^' + [char]0xFEFF), ''
    if (-not $raw.Trim()) { return @() }
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed)
  } catch {
    Write-Warning "deferred-intent store unreadable, quarantining and treating as empty: $($_.Exception.Message)"
    if ($WasCorrupt) { $WasCorrupt.Value = $true }
    try {
      $quarantine = "$Path.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
      Move-Item -LiteralPath $Path -Destination $quarantine -Force
      Write-Warning "corrupt deferred-intent store quarantined (not deleted) to $quarantine"
    } catch {
      Write-Warning "could not quarantine corrupt deferred-intent store at $Path : $($_.Exception.Message)"
    }
    return @()
  }
}

function Write-DeferredIntentStore {
  # Atomic tmp + Move-Item -Force, same as Write-OpportunityStore (opportunity-store.ps1:86-107),
  # including the -InputObject @() ConvertTo-Json note (avoids the single-element pipeline-unroll trap).
  param($Records, [string]$Path = (Get-DeferredIntentStorePath))
  $dir = Split-Path $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $json = ConvertTo-Json -InputObject @($Records) -Depth 5
  $tmpPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  Set-Content -Encoding UTF8 -LiteralPath $tmpPath -Value $json
  Move-Item -LiteralPath $tmpPath -Destination $Path -Force
}

function Get-DeferredIntentStagingPath {
  # Single source of truth for the staging filename - used by BOTH the prompt block and the merge. This
  # is the code-level kill for the staging-filename-mismatch bug class found live this session.
  # Dot-leading + .json means Get-DebriefWindowFiles's date-named-.md filter never picks it up.
  param([string]$VaultPath, [string]$Date)
  return (Join-Path $VaultPath "debriefs\.jarvis-deferred-staging-$Date.json")
}

function Get-DeferredIntentPromptBlock {
  # The exact instruction text appended to the debrief prompt. The agent PROPOSES only: it never decides
  # when or whether an intent resurfaces, never writes to any other ledger or store, and writes nothing
  # at all when there are no candidates.
  param([string]$StagingPath)
  return "Additionally: while reading today's sources, if Alex mentioned in passing something he " +
    "implied he should do but never asked you to track (e.g. 'I should really renew my residence " +
    "permit'), write a JSON array of at most 3 candidates to EXACTLY this path: $StagingPath . Each " +
    'candidate: {"utterance": the sentence VERBATIM as it appears in the source, "source_file": ' +
    'vault-relative path of the file it appears in, "mentioned_on": YYYY-MM-DD, "category": one word, ' +
    '"suggested_resurface_after": YYYY-MM-DD, "why": one line}. You PROPOSE only: you never decide ' +
    'when or whether it resurfaces, never write to any other ledger or store, and if there are no ' +
    'candidates write nothing at all.'
}

function Test-DeferredIntentCandidate {
  # The enforcement gate. Rejects unless ALL hold:
  #  - required fields present
  #  - utterance is 10..300 chars
  #  - mentioned_on parses yyyy-MM-dd EXACTLY
  #  - source_file resolves to a path INSIDE $VaultPath (resolved-path prefix check - path-traversal
  #    guard, agent output is untrusted)
  #  - ANTI-FABRICATION: the utterance appears as a literal substring of that file's actual on-disk
  #    content (whitespace-collapsed, case-insensitive on both sides). The agent cannot mint an intent
  #    Alex never uttered - code re-reads the cited file and checks.
  param($Candidate, [string]$VaultPath)
  if (-not $Candidate) { return $false }
  foreach ($field in @('utterance', 'source_file', 'mentioned_on')) {
    $val = $Candidate.$field
    if (-not $val -or -not "$val".Trim()) { return $false }
  }
  $utterance = [string]$Candidate.utterance
  if ($utterance.Length -lt 10 -or $utterance.Length -gt 300) { return $false }

  $mentionedOn = [string]$Candidate.mentioned_on
  $parsedDate = [datetime]::MinValue
  $ok = [datetime]::TryParseExact($mentionedOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)
  if (-not $ok) { return $false }

  $vaultFull = $null
  $fileFull  = $null
  try {
    $vaultFull = (Resolve-Path -LiteralPath $VaultPath -ErrorAction Stop).Path.TrimEnd('\', '/')
    $candidatePath = Join-Path $VaultPath ([string]$Candidate.source_file)
    $fileFull = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
  } catch {
    return $false
  }
  if (-not ($fileFull.ToLower().StartsWith(($vaultFull + '\').ToLower()) -or $fileFull.ToLower().StartsWith(($vaultFull + '/').ToLower()))) {
    return $false
  }

  $content = $null
  try { $content = Get-Content -LiteralPath $fileFull -Raw } catch { return $false }
  if ($null -eq $content) { return $false }

  $normalize = { param($s) ([regex]::Replace($s, '\s+', ' ')).Trim().ToLower() }
  $normUtterance = & $normalize $utterance
  $normContent   = & $normalize $content
  if (-not $normUtterance) { return $false }
  if ($normContent.IndexOf($normUtterance) -lt 0) { return $false }

  return $true
}

function Get-ResurfaceDate {
  # Parses the agent-proposed resurface date; unparseable falls back to Now+14d. Clamps to
  # [Now+1d, Now+90d] - the agent proposes the moment, code bounds it.
  param([string]$Proposed, [datetime]$Now)
  $parsed = $null
  try {
    $tmp = [datetime]::MinValue
    if ([datetime]::TryParseExact($Proposed, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tmp)) {
      $parsed = $tmp
    }
  } catch { $parsed = $null }
  if (-not $parsed) { $parsed = $Now.Date.AddDays(14) }
  $floor = $Now.Date.AddDays(1)
  $ceiling = $Now.Date.AddDays(90)
  if ($parsed -lt $floor) { return $floor }
  if ($parsed -gt $ceiling) { return $ceiling }
  return $parsed
}

function Merge-DeferredIntentCandidates {
  # Reads the staging JSON (absent/malformed -> zero candidates, NEVER throws), validates each via
  # Test-DeferredIntentCandidate, caps at 3 accepted per run, clamps resurface dates, dedupes by id
  # against the store, atomic write (skip-on-corrupt, mirroring CRITICAL-2), deletes the staging file,
  # returns @{ Proposed; Accepted; Rejected; RejectReasons }.
  param([string]$StagingPath, [string]$StorePath, [string]$VaultPath, [datetime]$Now)
  $result = [pscustomobject]@{ Proposed = 0; Accepted = 0; Rejected = 0; RejectReasons = @() }

  $candidates = @()
  if (Test-Path $StagingPath) {
    try {
      $raw = (Get-Content -LiteralPath $StagingPath -Raw) -replace ('^' + [char]0xFEFF), ''
      if ($raw.Trim()) {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed) { $candidates = @($parsed) }
      }
    } catch {
      # malformed staging JSON - never throw, just treat as zero candidates
      $candidates = @()
    }
  }
  $result.Proposed = $candidates.Count
  if ($candidates.Count -eq 0) {
    try { if (Test-Path $StagingPath) { Remove-Item -LiteralPath $StagingPath -Force } } catch { }
    return $result
  }

  $wasCorrupt = $false
  $store = @(Read-DeferredIntentStore -Path $StorePath -WasCorrupt ([ref]$wasCorrupt))

  $accepted = 0
  $rejectReasons = New-Object System.Collections.Generic.List[string]
  foreach ($c in $candidates) {
    if ($accepted -ge 3) { break }
    if (-not (Test-DeferredIntentCandidate -Candidate $c -VaultPath $VaultPath)) {
      $result.Rejected++
      $rejectReasons.Add("rejected: $($c.utterance)")
      continue
    }
    $id = Get-DeferredIntentId -Utterance ([string]$c.utterance) -SourceFile ([string]$c.source_file) -MentionedOn ([string]$c.mentioned_on)
    if (@($store | Where-Object { $_.Id -eq $id }).Count -gt 0) {
      # already known - not a rejection, just a dedupe skip
      continue
    }
    $resurfaceAfter = Get-ResurfaceDate -Proposed ([string]$c.suggested_resurface_after) -Now $Now
    $store += [pscustomobject]@{
      Id             = $id
      Utterance      = [string]$c.utterance
      SourceFile     = [string]$c.source_file
      MentionedOn    = [string]$c.mentioned_on
      Category       = [string]$c.category
      ResurfaceAfter = $resurfaceAfter.ToString('yyyy-MM-dd')
      Why            = [string]$c.why
      Status         = 'open'
      FirstSeen      = $Now.ToString('s')
      PromotedAt     = $null
    }
    $accepted++
  }
  $result.Accepted = $accepted
  $result.RejectReasons = @($rejectReasons)

  if (-not $wasCorrupt) {
    Write-DeferredIntentStore -Records $store -Path $StorePath
  }
  try { if (Test-Path $StagingPath) { Remove-Item -LiteralPath $StagingPath -Force } } catch { }
  return $result
}

function Add-DeferredIntentPromotions {
  # Pure: for AT MOST ONE intent per call (restraint/blast-radius cap) with Status='open' and
  # Now.Date >= ResurfaceAfter, adds an opportunity record via Add-Opportunity -Type 'deferred_intent',
  # sets the intent Status='promoted', PromotedAt. Promoted intents are never deleted and never
  # re-promoted - store is a memory, not a queue, same doctrine as opportunity-store.
  param($OppRecords, $Intents, [datetime]$Now)
  $opp = @($OppRecords)
  $intents = @($Intents)
  $promotedCount = 0
  $today = $Now.Date
  foreach ($intent in $intents) {
    if ($promotedCount -ge 1) { break }
    if ($intent.Status -ne 'open') { continue }
    $resurfaceAfter = $null
    try { $resurfaceAfter = [datetime]::Parse($intent.ResurfaceAfter) } catch { continue }
    if ($today -lt $resurfaceAfter.Date) { continue }

    $add = Add-Opportunity -Records $opp -From 'deferred-intent' -Subject $intent.Utterance -Date $intent.MentionedOn -Now $Now -Type 'deferred_intent'
    $opp = $add.Records
    if ($add.IsNew) {
      # LastPushed intentionally reset to null (not Add-Opportunity's default of $Now): the promotion
      # itself is NOT a push. The record must flow through the EXISTING reminder loop
      # (Get-OpportunitiesNeedingReminder: LastPushed null -> due) so there is exactly one outbound
      # seam for every opportunity, promoted or mail-derived, rather than a second bespoke send here.
      $newId = Get-OpportunityId -From 'deferred-intent' -Subject $intent.Utterance -Date $intent.MentionedOn
      $newRec = @($opp | Where-Object { $_.Id -eq $newId })[0]
      if ($newRec) { $newRec.LastPushed = $null }
    }
    $intent.Status = 'promoted'
    $intent.PromotedAt = $Now.ToString('s')
    $promotedCount++
  }
  return @{ OppRecords = $opp; Intents = $intents; PromotedCount = $promotedCount }
}

if ($DotSourceOnly) { return }
