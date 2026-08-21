# skill/bin/stage-prep.ps1 - Night Shift: calendar- and alarm-triggered overnight staging of
# reversible prep work. Runs by Task Scheduler at <staging_hour>:30 (opt-in, config staging_enabled -
# see scripts/register-staging.ps1), or manually from a NORMAL terminal.
#
# WHAT THIS DOES (tier 2 for exactly one domain: career events). For each qualifying trigger
# (interview / assessment / application-deadline) found in the next 48h of calendar events or the OPEN
# opportunity store that has not already been staged, it invokes the agent headlessly to gather ALREADY-
# COLLECTED local data (vault JOB_SEARCH.md, outreach/, tracker rows, the opportunity store, prior
# debriefs - no new WebSearch/WebFetch grant, no live posting fetch) and write ONE prep-sheet artifact
# to <vault>\outreach\staged\YYYY-MM-DD-<slug>.md. It gates ONLY at the output boundary: nothing is
# sent, nothing is applied, the calendar stays read-only, no Safety rule moves. A manifest entry is
# recorded ONLY after a successful write (crash-safe idempotency - see Update-StagingManifest).
#
# WHAT THIS NEVER DOES: create/edit calendar events, send/apply/outreach anything, stage a non-career
# trigger, or touch skill/bin/jarvis-debrief.ps1's own `.jarvis-runs.log` (that file is owned
# exclusively by the wrapper script - see SKILL.md Safety rule 8). This script logs to its OWN
# per-date log (`debriefs\.jarvis-staging-<date>.log`) and fails SILENTLY at the top level: a missed
# prep sheet is not alarm-worthy - restraint applies here too, exactly as it does for every other
# unscheduled push (see skill/references/debrief.md's Proactivity gate).
#
# Extraction pattern (tests/stage-prep.Tests.ps1): like jarvis-debrief.ps1, this script runs the whole
# overnight pass the moment it is invoked/dot-sourced (no -DotSourceOnly guard - it has real, time-of-
# night side effects, unlike the read-only collectors), so its functions are lifted out by source
# extraction into an isolated test scope instead.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
$ErrorActionPreference = 'Stop'
$BIN = $PSScriptRoot

# ---------- trigger id (event/opportunity id + date) ----------

function Get-StagingTriggerId {
  # Stable id for a CALENDAR event (opportunities already carry their own stable Get-OpportunityId - see
  # opportunity-store.ps1 - so this is only used for the calendar side). Same length-prefixed-join +
  # SHA-256-prefix technique as Get-OpportunityId, for the identical reason: an event title is untrusted
  # (calendar text), and a naive "$Source|$SeedText|$Date" join lets a title containing a literal '|'
  # forge a different id's boundary.
  param([string]$Source, [string]$SeedText, [string]$Date)
  $seed = ("$($Source.Length):$Source|$($SeedText.Length):$SeedText|$($Date.Length):$Date").ToLower()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    $hash = (($bytes[0..2] | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
  return "$Source-$hash-$Date"
}

# ---------- trigger qualification ----------

function Test-StagingQualifies {
  # A trigger qualifies when it is an interview/assessment (reuses check-job-mail.ps1's own
  # Classify-JobMailSubject - the SAME vocabulary already trusted to spot these in mail subjects, per
  # spec) or an application deadline (not itself part of that classifier - added here).
  param([string]$Text)
  if (-not $Text) { return $false }
  $cls = Classify-JobMailSubject -Subject $Text
  if ($cls -eq 'interview') { return $true }
  if ($Text -imatch 'deadline|apply by|closing date|closes (today|tomorrow|on)|application closes') { return $true }
  return $false
}

function Select-StagingTriggers {
  # Career triggers only, OUT OF SCOPE for anything else (spec). Calendar events are read-only input
  # (Summary/Date/Start - never edited); opportunities must be Status 'open' AND qualify by subject -
  # a closed/done record or a non-qualifying subject (digest, rejection, generic) is never a trigger.
  param($Events, $Opportunities, [datetime]$Now)
  $triggers = New-Object System.Collections.Generic.List[object]
  foreach ($e in @($Events)) {
    if (-not (Test-StagingQualifies -Text $e.Summary)) { continue }
    $dateStr = if ($e.Date) { "$($e.Date)" } else { $Now.ToString('yyyy-MM-dd') }
    $id = Get-StagingTriggerId -Source 'event' -SeedText $e.Summary -Date $dateStr
    $triggers.Add([pscustomobject]@{
      Id = $id; Source = 'calendar'; Title = $e.Summary; Date = $dateStr; Start = $e.Start
    })
  }
  foreach ($o in @($Opportunities)) {
    if ("$($o.Status)" -ne 'open') { continue }
    if (-not (Test-StagingQualifies -Text $o.Subject)) { continue }
    $dateStr = if ($o.Date) { "$($o.Date)" } else { $Now.ToString('yyyy-MM-dd') }
    $triggers.Add([pscustomobject]@{
      Id = "$($o.Id)-$dateStr"; Source = 'opportunity'; Title = $o.Subject; Date = $dateStr; From = $o.From
    })
  }
  # ".ToArray()" (not "@($triggers)"): wrapping a System.Collections.Generic.List[object] directly in
  # the array subexpression operator throws "Argument types do not match" on this PS 5.1 build -
  # verified empirically. The leading "," then forces the array to survive the return/pipeline boundary
  # even when it holds exactly 0 or 1 elements - PowerShell otherwise unwraps a single-element array
  # return into a bare object, also verified empirically (the identical trap Add-Opportunity/
  # Set-OpportunityStatus in opportunity-store.ps1 dodge by wrapping their return in a hashtable instead).
  return ,$triggers.ToArray()
}

# ---------- artifact path (injection-resistant - event/subject titles are untrusted input) ----------

function ConvertTo-StagingSlug {
  # Strips EVERYTHING except a-z0-9, collapsed to single hyphens: a title containing '..', '/', '\',
  # ':', or any other filesystem-meaningful character cannot survive into the filename, so it cannot
  # escape <vault>\outreach\staged\ or forge a different file. Length-capped so a very long subject
  # line does not produce an unwieldy (or filesystem-limit-hitting) filename.
  param([string]$Text)
  if (-not $Text) { return 'untitled' }
  $s = $Text.ToLowerInvariant()
  $s = ($s -replace '[^a-z0-9]+', '-').Trim('-')
  if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim('-') }
  if (-not $s) { return 'untitled' }
  return $s
}

function New-StagedArtifactPath {
  param([string]$VaultPath, [string]$Date, [string]$Title)
  $slug = ConvertTo-StagingSlug -Text $Title
  $dir = Join-Path $VaultPath 'outreach\staged'
  return (Join-Path $dir "$Date-$slug.md")
}

# ---------- manifest (~/.jarvis/staged.json) - crash-safe idempotency ----------

function Get-StagingManifestPath {
  return (Join-Path $HOME '.jarvis\staged.json')
}

function Read-StagingManifest {
  # Absent, empty, or corrupt all read as an empty set. Unlike opportunity-store.ps1's store, a corrupt
  # manifest is NOT quarantined here: the manifest is a pure idempotency cache (its only job is "did we
  # already stage this"), never the record of a real-world action itself, so re-staging an already-
  # staged trigger after a corrupt read is at worst a harmless re-write of the same local artifact - not
  # a lost opportunity the way a lost opportunity-store record would be.
  param([string]$Path = (Get-StagingManifestPath))
  if (-not (Test-Path $Path)) { return @() }
  try {
    $raw = (Get-Content -LiteralPath $Path -Raw) -replace ('^' + [char]0xFEFF), ''
    if (-not $raw.Trim()) { return @() }
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    # ",@($parsed)" (not "return @($parsed)"): a single-record manifest would otherwise unwrap to a
    # bare object across the return boundary (verified empirically on this PS 5.1 build) - the same
    # trap Update-StagingManifest's own return dodges the same way, see its comment.
    return ,@($parsed)
  } catch { return @() }
}

function Test-AlreadyStaged {
  param($Records, [string]$Id)
  return (@(@($Records) | Where-Object { $_.Id -eq $Id }).Count -gt 0)
}

function Update-StagingManifest {
  # Atomic write - temp file then Move-Item -Force, same pattern as Write-OpportunityStore (opportunity-
  # store.ps1): any reader sees either the fully-old or fully-new file, never a partial one.
  param($Records, [string]$Id, [string]$Date, [string]$ArtifactPath,
        [string]$Path = (Get-StagingManifestPath), [datetime]$Now = (Get-Date))
  $list = @($Records)
  $list += [pscustomobject]@{ Id = $Id; Date = $Date; ArtifactPath = $ArtifactPath; StagedAt = $Now.ToString('s') }
  $dir = Split-Path $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $json = ConvertTo-Json -InputObject @($list) -Depth 5
  $tmpPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  Set-Content -Encoding UTF8 -LiteralPath $tmpPath -Value $json
  Move-Item -LiteralPath $tmpPath -Destination $Path -Force
  # ",$list" (not "return $list"): a single-element array return unwraps to a bare object through the
  # pipeline otherwise - the comma operator forces it to stay an array regardless of count, 0 or 1.
  return ,$list
}

# ---------- live collector wiring (production only - unit tests always supply -Events/-Opportunities) ----------

function Get-StagingCalendarEvents {
  # Tomorrow + the day after (the "next 48h" window, spec) via the existing read-only iCal collector
  # (get-calendar.ps1) - already-whitelisted, no new grant. A missing/unset calendar (or any fetch
  # error) is swallowed here: Night Shift simply has nothing to stage from the calendar side this run,
  # exactly like every other collector in this codebase degrades silently rather than alarming on an
  # optional, unconfigured source.
  param([datetime]$Now)
  . (Join-Path $BIN 'get-calendar.ps1') -DotSourceOnly
  $events = New-Object System.Collections.Generic.List[object]
  try {
    $text = Get-IcsText
    foreach ($offset in 1..2) {
      $day = $Now.Date.AddDays($offset)
      foreach ($e in (Get-TodayEvents -Text $text -Day $day)) {
        $e | Add-Member -NotePropertyName Date -NotePropertyValue $day.ToString('yyyy-MM-dd') -Force
        $events.Add($e)
      }
    }
  } catch { }
  return ,$events.ToArray()
}

function Get-StagingOpenOpportunities {
  . (Join-Path $BIN 'opportunity-store.ps1') -DotSourceOnly
  try { return @(Read-OpportunityStore) } catch { return @() }
}

# ---------- headless agent invocation (bounded timeout, PID-file tree-kill - mirrors jarvis-debrief.ps1's
# own Invoke-ClaudeGeneration; duplicated rather than shared because jarvis-debrief.ps1 executes its
# whole body the instant it is dot-sourced, so it cannot itself be safely dot-sourced from here) ----------

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
      # No WebSearch/WebFetch in --allowedTools - local data only this sprint (spec: OUT OF SCOPE).
      & claude -p $p --permission-mode acceptEdits --allowedTools "Read Write Edit Bash Glob Grep" --output-format json 2>&1
    }
  )
  $pidFile = $null
  try {
    $pidFile = Join-Path $env:TEMP ('jarvis-staging-pid-' + [guid]::NewGuid().ToString('N') + '.txt')
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
      throw "Night Shift Claude generation exceeded $([math]::Round($TimeoutSec / 60))m timeout"
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
      throw "Night Shift Claude generation job did not complete cleanly (state: $jobState)"
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

function Invoke-StagingClaudeGeneration {
  # Builds the trigger-specific prompt and delegates to Invoke-ClaudeGeneration. The trigger's
  # id/source/date/title are passed as plain object arguments through Start-Job -ArgumentList (never
  # spliced into a shell command line the way check-opportunities.ps1 warns against for Send-Telegram),
  # so this is not a shell-injection vector; the same untrusted-text-into-an-LLM-context exposure
  # already exists everywhere else Jarvis reads calendar/mail text on Alex's behalf (debrief.md's own
  # modules), and is bounded the same way here: no send/apply tools in --allowedTools, output boundary
  # only, draft-and-ask still governs anything written for a third party.
  param($Trigger, [string]$ArtifactPath, [string]$SkillDir, [int]$TimeoutSec = 900, [string]$LogPath)
  $prompt = "You are running headlessly as Jarvis (no human present; do not ask questions). " +
    "Read your instructions at $SkillDir\SKILL.md and $SkillDir\references\staging.md, then execute the " +
    "Night Shift staging procedure now for this trigger - id=$($Trigger.Id) source=$($Trigger.Source) " +
    "date=$($Trigger.Date) title=`"$($Trigger.Title)`". Use ONLY already-collected local data (vault " +
    "JOB_SEARCH.md, outreach/, tracker rows, the opportunity store, prior debriefs) - no WebSearch/WebFetch, " +
    "no network calls of any kind. This path has ALREADY been computed for you - WRITE exactly one artifact " +
    "to this EXACT path, character for character, do not shorten, simplify, or rename it: $ArtifactPath " +
    "(create the outreach\staged folder if it does not exist) with a provenance header (trigger id, sources " +
    "read, generated-at). Obey " +
    "the safety rules in SKILL.md - this is a local read/write prep sheet only, never a send/apply/outreach " +
    "action, and the calendar stays read-only. Finish by confirming the file was written."
  Invoke-ClaudeGeneration -Prompt $prompt -TimeoutSec $TimeoutSec -WorkingDirectory $SkillDir `
    -LogPath $LogPath -RunStamp ((Get-Date).ToString('s')) | Out-Null
}

# ---------- orchestrator ----------

function Invoke-NightShift {
  # Returns the number of NEW artifacts successfully staged this run. Never throws: a trigger whose
  # agent call fails must not take out the other triggers, and the whole run must never take out
  # jarvis-debrief.ps1's own health log (see the header comment) - each trigger's failure is caught,
  # logged to -StagingLogPath, and the loop continues.
  param(
    [datetime]$Now = (Get-Date),
    [Parameter(Mandatory)][string]$VaultPath,
    [Parameter(Mandatory)][string]$SkillDir,
    [string]$ManifestPath = '',
    [string]$StagingLogPath = '',
    [array]$Events = $null,
    [array]$Opportunities = $null,
    [int]$TimeoutSec = 900
  )
  if (-not $ManifestPath) { $ManifestPath = Get-StagingManifestPath }
  if ($null -eq $Events)        { $Events        = Get-StagingCalendarEvents -Now $Now }
  if ($null -eq $Opportunities) { $Opportunities  = Get-StagingOpenOpportunities }

  $triggers = Select-StagingTriggers -Events $Events -Opportunities $Opportunities -Now $Now
  $manifestRecords = @(Read-StagingManifest -Path $ManifestPath)
  $staged = 0

  foreach ($t in $triggers) {
    if (Test-AlreadyStaged -Records $manifestRecords -Id $t.Id) { continue }
    $artifactPath = New-StagedArtifactPath -VaultPath $VaultPath -Date $t.Date -Title $t.Title
    $stagedDir = Split-Path $artifactPath
    # LIVE-VERIFICATION FINDING (2026-08-20): a real headless run wrote a genuine, well-grounded
    # artifact but under its OWN shortened filename instead of the exact path it was given, and the
    # strict Test-Path check below then discarded a perfectly good result as a failure. Record what
    # already existed in the staged dir BEFORE this call, so a same-directory, differently-named file
    # can still be recognised as a legitimate (if imperfectly-named) result rather than silently lost -
    # the safety boundary (the directory itself) is unaffected either way.
    # (2026-08-21 follow-up: the agent's real convention put the date at the END of the filename, so a
    # date-PREFIX filter never matched - detection is now a pure before/after directory diff.)
    $beforeNames = @()
    if (Test-Path -LiteralPath $stagedDir) {
      $beforeNames = @((Get-ChildItem -LiteralPath $stagedDir -Filter '*.md' -File -ErrorAction SilentlyContinue).Name)
    }
    try {
      Invoke-StagingClaudeGeneration -Trigger $t -ArtifactPath $artifactPath -SkillDir $SkillDir `
        -TimeoutSec $TimeoutSec -LogPath $StagingLogPath
      $actualPath = $artifactPath
      if (-not (Test-Path -LiteralPath $artifactPath)) {
        $newFiles = @()
        if (Test-Path -LiteralPath $stagedDir) {
          $newFiles = @(Get-ChildItem -LiteralPath $stagedDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Where-Object { $beforeNames -notcontains $_.Name })
        }
        if ($newFiles.Count -eq 1) {
          $actualPath = $newFiles[0].FullName
          if ($StagingLogPath) {
            try {
              Add-Content -Encoding UTF8 -Path $StagingLogPath -Value `
                "$($Now.ToString('s')) NOTE trigger=$($t.Id): agent used a different filename than given (got $($newFiles[0].Name), wanted $(Split-Path $artifactPath -Leaf)) - accepted, still inside outreach\staged\"
            } catch { }
          }
        } else {
          throw "agent did not write the expected artifact at $artifactPath (and $($newFiles.Count) ambiguous new same-date file(s) found instead)"
        }
      }
      # Record the manifest entry ONLY after a successful write (crash-safe idempotency, spec item 4).
      $manifestRecords = Update-StagingManifest -Records $manifestRecords -Id $t.Id -Date $t.Date `
        -ArtifactPath $actualPath -Path $ManifestPath -Now $Now
      $staged++
    } catch {
      if ($StagingLogPath) {
        try {
          Add-Content -Encoding UTF8 -Path $StagingLogPath `
            -Value "$($Now.ToString('s')) FAILED trigger=$($t.Id): $($_.Exception.Message)"
        } catch { }
      }
    }
  }
  return $staged
}

# ---------- entry point ----------

. (Join-Path $BIN 'check-job-mail.ps1') -DotSourceOnly   # Classify-JobMailSubject, for Test-StagingQualifies
. (Join-Path $BIN 'get-jarvis-config.ps1')
$jcfg = Get-JarvisConfig
$today = Get-Date -Format 'yyyy-MM-dd'
$stagingLog = Join-Path $jcfg.vault_path "debriefs\.jarvis-staging-$today.log"

try {
  if (-not $jcfg.staging_enabled) {
    # Opt-in feature, off by default (spec: config key staging_enabled). Quiet no-op - not even a log
    # line, so an installed-but-unconfigured Night Shift task produces zero noise.
    exit 0
  }
  # Headless auth (same as jarvis-debrief.ps1): feed Claude the long-lived subscription token created
  # by 'claude setup-token'. Stored DPAPI-encrypted at ~/.jarvis/claude-token.xml (never in the repo/
  # vault). Missing token -> throw, caught below -> logged to this script's own staging log only.
  $tokFile = Join-Path $HOME '.jarvis\claude-token.xml'
  if (Test-Path $tokFile) {
    $sec = Import-Clixml $tokFile
    $env:CLAUDE_CODE_OAUTH_TOKEN = (New-Object System.Management.Automation.PSCredential('t', $sec)).GetNetworkCredential().Password
  } else {
    throw "no Claude token at $tokFile - run 'claude setup-token' then store it (see jarvis-debrief.ps1's own setup note)"
  }
  Invoke-NightShift -VaultPath $jcfg.vault_path -SkillDir $jcfg.skill_dir -StagingLogPath $stagingLog | Out-Null
} catch {
  # Failure isolation (spec): Night Shift failing must never touch .jarvis-runs.log or block the
  # debrief. A missed prep sheet is not alarm-worthy - log locally and stay silent.
  try {
    Add-Content -Encoding UTF8 -Path $stagingLog -Value "$((Get-Date).ToString('s')) FAILED (top-level): $($_.Exception.Message)"
  } catch { }
}
exit 0
