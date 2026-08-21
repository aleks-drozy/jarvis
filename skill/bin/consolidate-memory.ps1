# skill/bin/consolidate-memory.ps1 - weekly semantic-memory consolidation. Runs by Task Scheduler
# Sundays at ~21:00 (opt-in, config consolidation_enabled - see scripts/register-consolidation.ps1),
# or manually from a NORMAL terminal.
#
# WHAT THIS DOES. Jarvis's episodic layer (debriefs/*.md) already exists and is never touched here -
# this script builds the missing SEMANTIC layer: <vault>\PATTERNS.md, a small, durable, cited set of
# facts distilled from the episodic layer, rewritten (never appended-to-forever) each week. Two passes:
#   1. A deterministic pre-pass (Measure-SuggestionOutcomes) parses SUGGESTIONS.md, collapses repeat
#      raises of the same topic (a "slug" - a distinctive hyphenated term shared across entries, e.g.
#      "alpha-signal-lab"), and searches an evidence corpus (vault file/folder names + recent git log
#      subjects across tracked repos) for proof the suggestion was actually acted on. Output is a JSON
#      ledger: {suggestion, category, times_raised, acted, evidence}.
#   2. An agent pass (Invoke-ClaudeGeneration, same job/timeout/tree-kill pattern as stage-prep.ps1)
#      reads the trailing week's debriefs, WEEK-PLAN.md, and that ledger, and rewrites PATTERNS.md from
#      skill/templates/PATTERNS.template.md with three sections: durable facts (every line cited
#      "(source: <episode file(s)>)", superseded in place, never appended forever), suggestion_weights
#      (per-category act-rate from the ledger), and a 5-line weekly learning report.
#
# SAFETY GATE (the whole point): the agent writes its candidate to a STAGING file, never straight to
# PATTERNS.md. Before any replace, Test-PatternsSchema checks every required section header is present
# and every fact line carries a "(source: ...)" citation. A candidate that fails is REJECTED - the OLD
# PATTERNS.md is kept untouched, byte for byte, and the rejection is logged to this script's own log.
# Malformed LLM output can never destroy the memory. A valid candidate is stale-flagged by the pure
# Add-StaleFactFlags function (never trusted to the agent's own date math) and then written via
# atomic temp-file + Move-Item (same pattern as Update-StagingManifest in stage-prep.ps1).
#
# WHAT THIS NEVER DOES: edit or delete anything in debriefs/ (episodic layer is strictly read-only),
# touch jarvis-debrief.ps1's own `.jarvis-runs.log`, do vector/semantic search, ingest any new external
# data source, or auto-delete a stale fact (stale facts are FLAGGED only - Alex removes them by hand).
#
# Extraction pattern (tests/measure-suggestions.Tests.ps1, tests/consolidate-memory.Tests.ps1): like
# stage-prep.ps1, this script runs the whole weekly pass the moment it is invoked (no -DotSourceOnly
# guard), so its functions are lifted out by source extraction into an isolated test scope instead.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
$ErrorActionPreference = 'Stop'
$BIN = $PSScriptRoot

# ============================================================================
# Part 1: deterministic suggestion-outcomes pre-pass
# ============================================================================

# ---------- slug extraction (topic identity across differently-worded re-raises) ----------

function Get-SuggestionSlugs {
  # A "slug" is a distinctive hyphenated term embedded in a suggestion title, e.g. "alpha-signal-lab"
  # or "ict-unicorn-model" - the same vocabulary Alex's own vault already uses for repo/project names,
  # so it is a reliable, deterministic way to recognise "this is the same topic" across re-raises worded
  # differently ("Register alpha-signal-lab..." / "Push alpha-signal-lab public..."). A leading numeric
  # vault-folder prefix ("25-alpha-signal-lab") is stripped so it normalises to the same slug as the
  # bare project name.
  param([string]$Title)
  if (-not $Title) { return , @() }
  $t = $Title.ToLowerInvariant()
  $ms = [regex]::Matches($t, '[a-z][a-z0-9]*(?:-[a-z0-9]+)+')
  $slugs = New-Object System.Collections.Generic.List[string]
  foreach ($m in $ms) {
    $s = ($m.Value -replace '^\d+-', '').Trim('-')
    if ($s.Length -ge 5) { $slugs.Add($s) }
  }
  return , (@($slugs) | Select-Object -Unique)
}

# ---------- category (drives suggestion_weights in PATTERNS.md) ----------

function Get-SuggestionCategory {
  # Small deterministic keyword classifier - deliberately simple, not NLP: this only needs to bucket
  # suggestions consistently enough to compute a per-category act-rate, not to be a taxonomy.
  param([string]$Title)
  $t = "$Title".ToLowerInvariant()
  if ($t -match 'linkedin|\bpost\b') { return 'social-post' }
  if ($t -match 'apply|application|interview') { return 'job-application' }
  if ($t -match 'register|vault|portfolio|public') { return 'portfolio-registration' }
  if ($t -match 'triage|\blog\b|\badd\b') { return 'housekeeping' }
  return 'other'
}

# ---------- SUGGESTIONS.md parsing ----------

function ConvertFrom-SuggestionsMarkdown {
  # Entries are headed "### YYYY-MM-DD <dash(es)> <title>" (debrief.md's own append format) - the dash
  # may be a plain hyphen or an en/em dash (the real vault file uses one). The pattern below spells
  # those out as \u2013 / \u2014 regex escapes (plain ASCII text in THIS FILE), so this script stays
  # ASCII-only per the repo's own ascii-purity guard even though the DATA it parses is not.
  param([string]$Text)
  $entries = New-Object System.Collections.Generic.List[object]
  if (-not $Text) { return , $entries.ToArray() }
  $pattern = '(?ms)^### (\d{4}-\d{2}-\d{2}) [\-\u2013\u2014]+ (.+?)\r?\n(.*?)(?=^### |\z)'
  $ms = [regex]::Matches($Text, $pattern)
  foreach ($m in $ms) {
    $dateStr = $m.Groups[1].Value
    $title = $m.Groups[2].Value.Trim()
    $body = $m.Groups[3].Value.Trim()
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dateStr, 'yyyy-MM-dd', $null,
          [System.Globalization.DateTimeStyles]::None, [ref]$date)) { continue }
    $entries.Add([pscustomobject]@{ Date = $date; Title = $title; Body = $body })
  }
  return , $entries.ToArray()
}

# ---------- evidence corpus (production wiring - unit tests always supply -EvidenceCorpus directly) ----------

function Get-VaultEvidenceCorpus {
  # Structural evidence only: FILE/FOLDER NAMES, never file content. A suggestion like "register X as
  # vault NN-X" is acted on precisely when a folder named that way exists - matching on names (not on
  # every note's prose) avoids the false positive of a debrief simply REPEATING the suggestion's own
  # words while still saying "not done yet". debriefs/ and SUGGESTIONS.md itself are excluded for the
  # same reason - they are the RAISING of the suggestion, never evidence of having acted on it.
  param([string]$VaultPath)
  if (-not (Test-Path -LiteralPath $VaultPath)) { return , @() }
  try {
    $names = Get-ChildItem -LiteralPath $VaultPath -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\debriefs(\\|$)' -and $_.Name -ne 'SUGGESTIONS.md' } |
      ForEach-Object { $_.Name }
    return , (@($names) | Select-Object -Unique)
  } catch { return , @() }
}

function Get-GitLogEvidenceCorpus {
  # Recent commit SUBJECT lines from one repo - a commit message mentioning the slug is real evidence
  # the suggestion turned into shipped work, not just a repeated note.
  param([string]$RepoRoot, [int]$MaxCount = 200)
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) { return , @() }
  try {
    $lines = & git -C $RepoRoot log "--format=%s" -n $MaxCount 2>$null
    if ($LASTEXITCODE -ne 0) { return , @() }
    return , @($lines)
  } catch { return , @() }
}

function Get-ProjectsGitLogEvidenceCorpus {
  param([string]$ProjectsRoot, [int]$MaxCount = 200)
  $corpus = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $ProjectsRoot)) { return , $corpus.ToArray() }
  try {
    $repos = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') })
    foreach ($r in $repos) {
      # NOT wrapped in @() - Get-GitLogEvidenceCorpus already returns ,@($lines) (a single emitted
      # array object); @() around a comma-returning FUNCTION CALL re-wraps that single object into a
      # 1-element outer array instead of flattening it (verified empirically - the same trap
      # Select-StagingTriggers's own callers in stage-prep.ps1 dodge by never wrapping its call site).
      foreach ($line in (Get-GitLogEvidenceCorpus -RepoRoot $r.FullName -MaxCount $MaxCount)) {
        $corpus.Add($line)
      }
    }
  } catch { }
  return , $corpus.ToArray()
}

# ---------- acted detection ----------

function Get-SuggestionEvidence {
  # Case-insensitive substring match of the slug against each evidence-corpus entry - deliberately
  # dumb and deterministic (no LLM in this pre-pass, per spec). Capped at 5 so the ledger stays small.
  param([string]$Slug, [string[]]$EvidenceCorpus)
  $needle = "$Slug".ToLowerInvariant()
  $hits = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($EvidenceCorpus)) {
    if ("$line".ToLowerInvariant().Contains($needle)) {
      $hits.Add("$line")
      if ($hits.Count -ge 5) { break }
    }
  }
  return , $hits.ToArray()
}

function Test-SuggestionActed {
  param([string]$Slug, [string[]]$EvidenceCorpus)
  return ((Get-SuggestionEvidence -Slug $Slug -EvidenceCorpus $EvidenceCorpus).Count -gt 0)
}

# ---------- the ledger ----------

function Measure-SuggestionOutcomes {
  # Returns an array of pscustomobject, one per distinct slug raised in the trailing -WindowWeeks
  # weeks, each with the required keys: suggestion, category, times_raised, acted, evidence (plus
  # slug/first_raised/last_raised for traceability). Absent/empty/unparseable SUGGESTIONS.md reads as
  # zero entries, never an error - a missing file this week is not a crash.
  param(
    [string]$SuggestionsPath,
    [datetime]$Now = (Get-Date),
    [int]$WindowWeeks = 6,
    [string[]]$EvidenceCorpus = @()
  )
  $result = New-Object System.Collections.Generic.List[object]
  if (-not $SuggestionsPath -or -not (Test-Path -LiteralPath $SuggestionsPath)) { return , $result.ToArray() }
  $text = ''
  # -Encoding UTF8 on the READ is load-bearing (same lesson as install.ps1's own): PS 5.1 defaults to
  # ANSI, and SUGGESTIONS.md's own em-dash headers would mis-decode into garbage bytes that never
  # match ConvertFrom-SuggestionsMarkdown's pattern, silently producing zero parsed entries. A stray
  # leading BOM char is stripped defensively, same as get-jarvis-config.ps1's own read.
  try {
    $text = (Get-Content -LiteralPath $SuggestionsPath -Raw -Encoding UTF8) -replace ('^' + [char]0xFEFF), ''
  } catch { return , $result.ToArray() }
  # NOT wrapped in @() - see the comment on the Get-GitLogEvidenceCorpus call site above: wrapping a
  # comma-returning function call in @() collapses a multi-element result down to one.
  $entries = ConvertFrom-SuggestionsMarkdown -Text $text

  $cutoff = $Now.Date.AddDays(-7 * $WindowWeeks)
  $windowEntries = @($entries | Where-Object { $_.Date -ge $cutoff -and $_.Date -le $Now.Date })

  $groups = [ordered]@{}
  foreach ($e in $windowEntries) {
    foreach ($slug in (Get-SuggestionSlugs -Title $e.Title)) {
      if (-not $groups.Contains($slug)) { $groups[$slug] = New-Object System.Collections.Generic.List[object] }
      $groups[$slug].Add($e)
    }
  }

  foreach ($slug in ($groups.Keys | Sort-Object)) {
    $items = @($groups[$slug] | Sort-Object Date)
    $latest = $items[$items.Count - 1]
    $evidence = Get-SuggestionEvidence -Slug $slug -EvidenceCorpus $EvidenceCorpus
    $result.Add([pscustomobject]@{
      suggestion   = $latest.Title
      slug         = $slug
      category     = (Get-SuggestionCategory -Title $latest.Title)
      times_raised = $items.Count
      acted        = ($evidence.Count -gt 0)
      evidence     = $evidence
      first_raised = $items[0].Date.ToString('yyyy-MM-dd')
      last_raised  = $latest.Date.ToString('yyyy-MM-dd')
    })
  }
  return , $result.ToArray()
}

function Restore-PatternsIfTampered {
  # BUG-1 guard (live sandbox finding 2026-08-20): a headless agent with Write/Edit tools once
  # bypassed the staging gate and wrote malformed content STRAIGHT onto PatternsPath while the
  # orchestrator "correctly" logged REJECTED - blind to the fact the protected file was destroyed.
  # This is the technical enforcement the prompt instruction alone cannot provide: compare the
  # current hash of PatternsPath to the pre-agent snapshot; on ANY mismatch, restore the backup
  # (or delete the file if none existed before) and log a CRITICAL line, deliberately distinct
  # from routine "REJECTED:" noise. Idempotent: after a restore the hashes match again, so a
  # second call is a no-op. Returns $true when tampering was detected and repaired.
  param([string]$PatternsPath, [string]$PreHash, [string]$BackupPath, [string]$LogPath, [datetime]$Now)
  $postHash = $null
  if (Test-Path -LiteralPath $PatternsPath) {
    $postHash = (Get-FileHash -LiteralPath $PatternsPath -Algorithm SHA256).Hash
  }
  if ($postHash -eq $PreHash) { return $false }
  if ($PreHash) {
    Copy-Item -LiteralPath $BackupPath -Destination $PatternsPath -Force
  } else {
    # no PATTERNS.md existed before the agent ran - the agent's direct write is removed entirely
    Remove-Item -LiteralPath $PatternsPath -Force -ErrorAction SilentlyContinue
  }
  if ($LogPath) {
    try {
      Add-Content -Encoding UTF8 -Path $LogPath -Value `
        "$($Now.ToString('s')) CRITICAL: PATTERNS.md was modified outside the staging gate (agent wrote the real path directly) - previous content restored"
    } catch { }
  }
  return $true
}

# ============================================================================
# Part 2: episodic window + agent pass + schema-gated atomic write
# ============================================================================

# ---------- trailing-week debrief filenames (window correctness) ----------

function Get-DebriefWindowFiles {
  # Only date-named debrief notes (YYYY-MM-DD.md) inside [-WindowDays, Now] - README.md and any
  # non-date file in debriefs/ are excluded. Read-only: this function never touches the files it lists.
  param([string]$DebriefsPath, [datetime]$Now, [int]$WindowDays = 7)
  if (-not $DebriefsPath -or -not (Test-Path -LiteralPath $DebriefsPath)) { return , @() }
  $cutoff = $Now.Date.AddDays(-$WindowDays)
  $files = @(Get-ChildItem -LiteralPath $DebriefsPath -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object {
      $d = [datetime]::MinValue
      ([datetime]::TryParseExact($_.BaseName, 'yyyy-MM-dd', $null,
        [System.Globalization.DateTimeStyles]::None, [ref]$d)) -and $d -ge $cutoff -and $d -le $Now.Date
    } | Sort-Object Name)
  return , (@($files) | ForEach-Object { $_.Name })
}

# ---------- schema gate (malformed LLM output can never destroy the memory) ----------

function Get-PatternsSection {
  # Text between $Header and whichever OTHER required header comes next (or end of string).
  param([string]$Text, [string]$Header, [string[]]$AllHeaders)
  $idx = $Text.IndexOf($Header)
  if ($idx -lt 0) { return '' }
  $rest = $Text.Substring($idx + $Header.Length)
  $endIdx = $rest.Length
  foreach ($h in $AllHeaders) {
    if ($h -eq $Header) { continue }
    $i = $rest.IndexOf($h)
    if ($i -ge 0 -and $i -lt $endIdx) { $endIdx = $i }
  }
  return $rest.Substring(0, $endIdx)
}

function Test-PatternsSchema {
  # The gate. Every required section header must be present, and every bullet line under "## Durable
  # facts" must carry a "(source: ...)" citation. Anything else -> Valid=$false with human-readable
  # Errors, and the caller must keep the OLD file rather than replace it.
  param([string]$Text)
  $errors = New-Object System.Collections.Generic.List[string]
  if (-not $Text -or -not $Text.Trim()) {
    $errors.Add('empty candidate output')
    return [pscustomobject]@{ Valid = $false; Errors = $errors.ToArray() }
  }
  $requiredHeaders = @('## Durable facts', '## Suggestion weights', '## Weekly learning report')
  foreach ($h in $requiredHeaders) {
    if ($Text -notmatch [regex]::Escape($h)) { $errors.Add("missing required section header: $h") }
  }
  if ($errors.Count -eq 0) {
    $factSection = Get-PatternsSection -Text $Text -Header '## Durable facts' -AllHeaders $requiredHeaders
    $factLines = @($factSection -split "`r?`n" | Where-Object { $_.Trim().StartsWith('-') })
    if ($factLines.Count -eq 0) { $errors.Add('Durable facts section has no fact lines') }
    foreach ($line in $factLines) {
      if ($line -notmatch '\(source: [^()]+\)') {
        $errors.Add("fact line missing '(source: ...)' citation: $($line.Trim())")
      }
    }
  }
  return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

# ---------- stale flagging (pure - never trusted to the agent's own date math) ----------

function Add-StaleFactFlags {
  # For each cited fact line, parse the most recent YYYY-MM-DD found inside its "(source: ...)" span.
  # If that date is >= -StaleWeeks old (default 4, spec) and the line is not already flagged, append
  # " (stale -- last evidenced <date>)". Pure text-in/text-out - no side effects, no file I/O.
  param([string]$Text, [datetime]$Now, [int]$StaleWeeks = 4)
  if (-not $Text) { return $Text }
  $lines = $Text -split "`r?`n"
  $inFacts = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line.TrimEnd() -eq '## Durable facts') { $inFacts = $true; continue }
    if ($inFacts -and $line.StartsWith('## ') -and $line.TrimEnd() -ne '## Durable facts') { $inFacts = $false }
    if (-not $inFacts) { continue }
    if (-not $line.TrimStart().StartsWith('-')) { continue }
    # Skip a line that already carries the flag MARKER specifically (not merely the word "stale" -
    # a fact's own content could legitimately contain that word, e.g. "flagged as stale by X").
    if ($line -match '\(stale -- last evidenced \d{4}-\d{2}-\d{2}\)') { continue }
    $sourceMatch = [regex]::Match($line, '\(source: ([^()]+)\)')
    if (-not $sourceMatch.Success) { continue }
    $dateMatches = [regex]::Matches($sourceMatch.Groups[1].Value, '\d{4}-\d{2}-\d{2}')
    if ($dateMatches.Count -eq 0) { continue }
    $parsedDates = New-Object System.Collections.Generic.List[datetime]
    foreach ($dm in $dateMatches) {
      $d = [datetime]::MinValue
      if ([datetime]::TryParseExact($dm.Value, 'yyyy-MM-dd', $null,
            [System.Globalization.DateTimeStyles]::None, [ref]$d)) { $parsedDates.Add($d) }
    }
    if ($parsedDates.Count -eq 0) { continue }
    $latest = ($parsedDates | Sort-Object)[$parsedDates.Count - 1]
    $weeksSince = [math]::Floor(($Now.Date - $latest.Date).Days / 7)
    if ($weeksSince -ge $StaleWeeks) {
      $lines[$i] = "$line (stale -- last evidenced $($latest.ToString('yyyy-MM-dd')))"
    }
  }
  return ($lines -join "`r`n")
}

# ---------- headless agent invocation (bounded timeout, PID-file tree-kill - duplicated from
# stage-prep.ps1's own Invoke-ClaudeGeneration for the identical reason it duplicates jarvis-debrief.ps1's:
# this script also runs its whole body the instant it is invoked, so it cannot be dot-sourced safely) ----------

function Invoke-ClaudeGeneration {
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [int]$TimeoutSec = 900,
    [string]$WorkingDirectory = $BIN,
    [string]$LogPath,
    [string]$RunStamp,
    [scriptblock]$JobScript = {
      param($p, $dir, $pidFile)
      if ($dir) { Set-Location -LiteralPath $dir -ErrorAction Stop }
      if ($pidFile) { try { Set-Content -LiteralPath $pidFile -Value $PID -ErrorAction Stop } catch { } }
      # No WebSearch/WebFetch in --allowedTools - local data only (spec: OUT OF SCOPE for this sprint).
      & claude -p $p --permission-mode acceptEdits --allowedTools "Read Write Edit Glob Grep" --output-format json 2>&1
    }
  )
  $pidFile = $null
  try {
    $pidFile = Join-Path $env:TEMP ('jarvis-consolidation-pid-' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $pidFile -Value 'pending' -ErrorAction Stop
  } catch { $pidFile = $null }
  try {
    $job = Start-Job -ScriptBlock $JobScript -ArgumentList $Prompt, $WorkingDirectory, $pidFile
    $done = Wait-Job $job -Timeout $TimeoutSec
    if (-not $done) {
      $partial = $null
      try { $partial = Receive-Job $job -ErrorAction SilentlyContinue } catch { }
      if ($pidFile -and (Test-Path -LiteralPath $pidFile)) {
        $hostPidText = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
        if ($hostPidText -match '^\s*(\d+)\s*$') {
          try { & taskkill /PID $Matches[1] /T /F 2>$null | Out-Null } catch { }
        }
      }
      try { Stop-Job $job -ErrorAction SilentlyContinue } catch { }
      try { Remove-Job $job -Force -ErrorAction SilentlyContinue } catch { }
      if ($LogPath -and $RunStamp) {
        try {
          Add-Content -Encoding UTF8 -Path $LogPath -Value "===== run $RunStamp ====="
          (@("[TIMED OUT after $([math]::Round($TimeoutSec / 60))m - partial output, if any, below]") + @($partial)) |
            Add-Content -Encoding UTF8 -Path $LogPath
        } catch { }
      }
      throw "Consolidation Claude generation exceeded $([math]::Round($TimeoutSec / 60))m timeout"
    }
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    $jobState = $job.State
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($jobState -ne 'Completed') {
      if ($LogPath -and $RunStamp) {
        try {
          Add-Content -Encoding UTF8 -Path $LogPath -Value "===== run $RunStamp ====="
          (@("[job did not complete cleanly: state=$jobState - partial output, if any, below]") + @($result)) |
            Add-Content -Encoding UTF8 -Path $LogPath
        } catch { }
      }
      throw "Consolidation Claude generation job did not complete cleanly (state: $jobState)"
    }
    if ($LogPath -and $RunStamp) {
      try {
        Add-Content -Encoding UTF8 -Path $LogPath -Value "===== run $RunStamp ====="
        $result | Add-Content -Encoding UTF8 -Path $LogPath
      } catch { }
    }
    return $result
  } finally {
    if ($pidFile) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-ConsolidationClaudeGeneration {
  # Builds the consolidation prompt and delegates to Invoke-ClaudeGeneration. The agent writes its
  # candidate to a STAGING path, never straight to PatternsPath - the schema gate runs in PowerShell,
  # in Invoke-WeeklyConsolidation, AFTER this returns, before anything real is replaced.
  param(
    [Parameter(Mandatory)][string]$VaultPath,
    [Parameter(Mandatory)][string]$SkillDir,
    [string[]]$DebriefFiles = @(),
    [string]$LedgerJson = '[]',
    [Parameter(Mandatory)][string]$TemplatePath,
    [Parameter(Mandatory)][string]$StagingPath,
    [int]$TimeoutSec = 900,
    [string]$LogPath
  )
  $debriefList = if (@($DebriefFiles).Count -gt 0) { ($DebriefFiles -join ', ') } else { '(none this week)' }
  $prompt = "You are running headlessly as Jarvis (no human present; do not ask questions). " +
    "Read your instructions at $SkillDir\SKILL.md, then perform weekly semantic-memory consolidation. " +
    "Read ONLY these trailing-week debrief files, verbatim, from $VaultPath\debriefs\ : $debriefList . " +
    "Also read $VaultPath\WEEK-PLAN.md if it exists. Here is the deterministic suggestion-outcomes " +
    "ledger, already computed - use it as-is, never recompute or second-guess times_raised/acted: " +
    "$LedgerJson . Using the structure of the template at $TemplatePath, REWRITE the file at EXACTLY " +
    "this staging path, character for character, do not shorten or rename it: $StagingPath . The new " +
    "file MUST contain three sections with these EXACT headers, each on its own line: '## Durable " +
    "facts', '## Suggestion weights', '## Weekly learning report'. Every durable-fact bullet line MUST " +
    "end with a citation in the exact form '(source: <episode file(s)>)' naming the real debrief " +
    "filename(s) it came from - never a fact with no citation. Supersede facts IN PLACE: if this week's " +
    "evidence updates or contradicts an older fact, REPLACE that line, do not keep both - the file is a " +
    "rewrite, not a forever-growing append log. Suggestion weights: one act-rate line per category, " +
    "computed directly from the ledger's times_raised/acted fields. Weekly learning report: EXACTLY 5 " +
    "lines, plain facts, no narrative padding. Do NOT add any 'stale' flag yourself - that is computed " +
    "separately in PowerShell after you finish. " +
    "ABSOLUTE RULE: never create, edit, or delete anything under $VaultPath\debriefs\ - the episodic " +
    "layer is strictly read-only from this procedure, no exceptions. Finish by confirming the staging " +
    "file was written."
  Invoke-ClaudeGeneration -Prompt $prompt -TimeoutSec $TimeoutSec -WorkingDirectory $SkillDir `
    -LogPath $LogPath -RunStamp ((Get-Date).ToString('s'))
}

# ---------- orchestrator ----------

function Invoke-WeeklyConsolidation {
  # Never throws: a failed/rejected consolidation must not take out anything else. Returns $true on a
  # successful PATTERNS.md replace, $false when the run was rejected or the agent call failed (the OLD
  # PATTERNS.md, if any, is always left exactly as it was in that case).
  param(
    [datetime]$Now = (Get-Date),
    [Parameter(Mandatory)][string]$VaultPath,
    [Parameter(Mandatory)][string]$SkillDir,
    [string]$PatternsPath = '',
    [string]$SuggestionsPath = '',
    [string]$DebriefsPath = '',
    [string]$LogPath = '',
    [string[]]$EvidenceCorpus = @(),
    [int]$WindowWeeks = 6,
    [int]$DebriefWindowDays = 7,
    [int]$StaleWeeks = 4,
    [int]$TimeoutSec = 900
  )
  if (-not $PatternsPath)     { $PatternsPath     = Join-Path $VaultPath 'PATTERNS.md' }
  if (-not $SuggestionsPath)  { $SuggestionsPath   = Join-Path $VaultPath 'SUGGESTIONS.md' }
  if (-not $DebriefsPath)     { $DebriefsPath      = Join-Path $VaultPath 'debriefs' }

  $stagingPath = "$PatternsPath.staged-$([guid]::NewGuid().ToString('N')).md"
  $backupPath = "$PatternsPath.bak-$([guid]::NewGuid().ToString('N'))"
  $preHash = $null
  if (Test-Path -LiteralPath $PatternsPath) {
    $preHash = (Get-FileHash -LiteralPath $PatternsPath -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $PatternsPath -Destination $backupPath -Force
  }
  $replaced = $false
  try {
    # NOT wrapped in @() - both return ,$array.ToArray(); see the comment on the
    # Get-GitLogEvidenceCorpus call site above.
    $ledger = Measure-SuggestionOutcomes -SuggestionsPath $SuggestionsPath -Now $Now `
      -WindowWeeks $WindowWeeks -EvidenceCorpus $EvidenceCorpus
    $ledgerJson = ConvertTo-Json -InputObject @($ledger) -Depth 6
    $debriefFiles = Get-DebriefWindowFiles -DebriefsPath $DebriefsPath -Now $Now -WindowDays $DebriefWindowDays
    $templatePath = Join-Path $SkillDir 'templates\PATTERNS.template.md'

    Invoke-ConsolidationClaudeGeneration -VaultPath $VaultPath -SkillDir $SkillDir -DebriefFiles $debriefFiles `
      -LedgerJson $ledgerJson -TemplatePath $templatePath -StagingPath $stagingPath -TimeoutSec $TimeoutSec `
      -LogPath $LogPath | Out-Null

    Restore-PatternsIfTampered -PatternsPath $PatternsPath -PreHash $preHash -BackupPath $backupPath `
      -LogPath $LogPath -Now $Now | Out-Null

    if (-not (Test-Path -LiteralPath $stagingPath)) {
      throw "agent did not write the staging candidate at $stagingPath"
    }
    # -Encoding UTF8 on the READ (same reasoning as the SUGGESTIONS.md read above) - the agent's
    # candidate can legitimately contain non-ASCII text (em dashes, etc).
    $candidateText = Get-Content -LiteralPath $stagingPath -Raw -Encoding UTF8

    $schema = Test-PatternsSchema -Text $candidateText
    if (-not $schema.Valid) {
      throw "PATTERNS.md candidate failed schema validation - keeping the existing file: $($schema.Errors -join '; ')"
    }

    $finalText = Add-StaleFactFlags -Text $candidateText -Now $Now -StaleWeeks $StaleWeeks
    $tmpPath = "$PatternsPath.tmp-$([guid]::NewGuid().ToString('N'))"
    Set-Content -Encoding UTF8 -LiteralPath $tmpPath -Value $finalText
    Move-Item -LiteralPath $tmpPath -Destination $PatternsPath -Force
    $replaced = $true

    if ($LogPath) {
      try {
        Add-Content -Encoding UTF8 -Path $LogPath -Value `
          "$($Now.ToString('s')) OK PATTERNS.md replaced ($($debriefFiles.Count) debrief(s) in window, $($ledger.Count) ledger entries)"
      } catch { }
    }
    return $true
  } catch {
    if (-not $replaced) {
      Restore-PatternsIfTampered -PatternsPath $PatternsPath -PreHash $preHash -BackupPath $backupPath `
        -LogPath $LogPath -Now $Now | Out-Null
    }
    if ($LogPath) {
      try { Add-Content -Encoding UTF8 -Path $LogPath -Value "$($Now.ToString('s')) REJECTED: $($_.Exception.Message)" } catch { }
    }
    return $false
  } finally {
    Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
  }
}

# ---------- entry point ----------

. (Join-Path $BIN 'get-jarvis-config.ps1')
$jcfg = Get-JarvisConfig
$today = Get-Date -Format 'yyyy-MM-dd'
$consolidationLog = Join-Path $jcfg.vault_path "debriefs\.jarvis-consolidation-$today.log"

try {
  if (-not $jcfg.consolidation_enabled) {
    # Opt-in feature, off by default (spec: config key consolidation_enabled). Quiet no-op.
    exit 0
  }
  $tokFile = Join-Path $HOME '.jarvis\claude-token.xml'
  if (Test-Path $tokFile) {
    $sec = Import-Clixml $tokFile
    $env:CLAUDE_CODE_OAUTH_TOKEN = (New-Object System.Management.Automation.PSCredential('t', $sec)).GetNetworkCredential().Password
  } else {
    throw "no Claude token at $tokFile - run 'claude setup-token' then store it (see jarvis-debrief.ps1's own setup note)"
  }
  # NOT wrapped in @() - see the comment on the Get-GitLogEvidenceCorpus call site above.
  $evidence = New-Object System.Collections.Generic.List[string]
  foreach ($v in (Get-VaultEvidenceCorpus -VaultPath $jcfg.vault_path)) { $evidence.Add($v) }
  foreach ($v in (Get-ProjectsGitLogEvidenceCorpus -ProjectsRoot $jcfg.projects_root)) { $evidence.Add($v) }
  Invoke-WeeklyConsolidation -VaultPath $jcfg.vault_path -SkillDir $jcfg.skill_dir `
    -LogPath $consolidationLog -EvidenceCorpus $evidence.ToArray() | Out-Null
} catch {
  # Failure isolation (same contract as stage-prep.ps1): never touch .jarvis-runs.log, never block the
  # debrief. Log locally and stay silent - a missed consolidation is not alarm-worthy.
  try {
    Add-Content -Encoding UTF8 -Path $consolidationLog -Value "$((Get-Date).ToString('s')) FAILED (top-level): $($_.Exception.Message)"
  } catch { }
}
exit 0
