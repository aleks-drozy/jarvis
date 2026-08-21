# tests/stage-prep.Tests.ps1 - Night Shift: calendar/opportunity-triggered overnight staging of
# reversible prep work (skill/bin/stage-prep.ps1). Tier-2 autonomy for exactly one domain (career
# events): gather already-collected local data, write ONE prep-sheet artifact, gate only at the
# output boundary. Nothing here sends, applies, or edits the calendar.
#
# Extraction pattern matches tests/claude-generation-timeout.Tests.ps1 / debrief-heartbeat.Tests.ps1:
# stage-prep.ps1 runs the whole overnight pass the moment it is invoked/dot-sourced (like
# jarvis-debrief.ps1, unlike the -DotSourceOnly-guarded collectors), so the functions under test are
# lifted out by source extraction into an isolated scope instead. The real Claude invocation is never
# extracted - a name-shadowing stub is defined FIRST so Invoke-NightShift (extracted after it) resolves
# to the stub, never the real CLI.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$stageSrc = Get-Content (Join-Path $repo 'skill\bin\stage-prep.ps1') -Raw

function Extract-Fn([string]$Src, [string]$Name) {
  $m = [regex]::Match($Src, "(?ms)^function $Name \{.*?\n\}")
  Assert $m.Success "could not extract $Name from stage-prep.ps1"
  return $m.Value
}

# Test-StagingQualifies reuses check-job-mail.ps1's classifier vocabulary - dot-source it first so the
# extracted function resolves Classify-JobMailSubject.
. (Join-Path $repo 'skill\bin\check-job-mail.ps1') -DotSourceOnly

foreach ($fn in @('Get-StagingTriggerId','Test-StagingQualifies','Select-StagingTriggers',
                   'ConvertTo-StagingSlug','New-StagedArtifactPath',
                   'Get-StagingManifestPath','Read-StagingManifest','Test-AlreadyStaged','Update-StagingManifest')) {
  . ([scriptblock]::Create((Extract-Fn $stageSrc $fn)))
}

# ---------- ConvertTo-StagingSlug: injection-resistant filenames (untrusted event/subject titles) ----------
Assert ((ConvertTo-StagingSlug 'CodeSignal Assessment - Susquehanna') -match '^[a-z0-9-]+$') `
  "slug must be filesystem-safe lowercase/hyphen only"
$evil = ConvertTo-StagingSlug '../../../evil<>:"|?*name; rm -rf /'
Assert ($evil -notmatch '[\\/:\*\?"<>\|]') "slug must strip path separators and reserved filename characters"
Assert ($evil -notmatch '\.\.') "slug must not allow directory traversal sequences"
Assert ((ConvertTo-StagingSlug '') -ne '') "an empty title must still produce a non-empty fallback slug"

# ---------- New-StagedArtifactPath: always inside <vault>\outreach\staged\, nowhere else ----------
$vaultFixture = Join-Path $env:TEMP ('jarvis-stage-vault-' + [guid]::NewGuid().ToString('N'))
$p = New-StagedArtifactPath -VaultPath $vaultFixture -Date '2026-08-21' -Title 'CodeSignal Assessment'
$wantDir = (Join-Path $vaultFixture 'outreach\staged') + '\'
Assert ($p.StartsWith($wantDir, [StringComparison]::OrdinalIgnoreCase)) `
  "staged artifact path must live inside <vault>\outreach\staged\ (got $p)"
Assert ($p -like '*2026-08-21-*.md') "staged artifact filename must be date-prefixed markdown (got $p)"

# a hostile title must not escape the staged directory
$pEvil = New-StagedArtifactPath -VaultPath $vaultFixture -Date '2026-08-21' -Title '../../../evil'
Assert ($pEvil.StartsWith($wantDir, [StringComparison]::OrdinalIgnoreCase)) `
  "a hostile title must not escape <vault>\outreach\staged\ (got $pEvil)"

# ---------- Test-StagingQualifies / Select-StagingTriggers ----------
$now = [datetime]::Parse('2026-08-20T22:00:00')

$qualifyingEvent    = [pscustomobject]@{ Summary = 'CodeSignal Assessment - Susquehanna'; Start = '14:00'; End='15:00'; AllDay=$false }
$nonQualifyingEvent = [pscustomobject]@{ Summary = 'Gym'; Start = '18:00'; End='19:00'; AllDay=$false }
$deadlineEvent      = [pscustomobject]@{ Summary = 'Application deadline - Fruition Group'; Start=''; End=''; AllDay=$true }

Assert (Test-StagingQualifies 'Interview invitation - Mastercard') "an interview-vocabulary title must qualify"
Assert (Test-StagingQualifies 'Application deadline - closes tomorrow') "a deadline-vocabulary title must qualify"
Assert (-not (Test-StagingQualifies 'Gym')) "an unrelated title must not qualify"
Assert (-not (Test-StagingQualifies '')) "an empty title must not qualify"

$openOpportunity   = [pscustomobject]@{ Id='ab12cd'; From='no-reply@codesignal.com'; Subject='Your CodeSignal assessment invite'; Date='2026-08-21'; Status='open' }
$closedOpportunity = [pscustomobject]@{ Id='ef34gh'; From='no-reply@codesignal.com'; Subject='Your CodeSignal assessment invite'; Date='2026-08-21'; Status='done' }
$digestOpportunity = [pscustomobject]@{ Id='ij56kl'; From='jobs@linkedin.com'; Subject='5 new jobs for you'; Date='2026-08-21'; Status='open' }

# 1) qualifying fixture event + empty manifest -> the triggers list is non-empty and its artifact path
#    lands inside <vault>\outreach\staged\ and nowhere else (asserted directly on Select-StagingTriggers'
#    own output here; the "agent invoked once" half is asserted below via Invoke-NightShift).
$triggers = Select-StagingTriggers -Events @($qualifyingEvent, $nonQualifyingEvent, $deadlineEvent) `
  -Opportunities @($openOpportunity, $closedOpportunity, $digestOpportunity) -Now $now
Assert ($triggers.Count -eq 3) "expected 3 qualifying triggers (interview event, deadline event, open interview-vocab opportunity), got $($triggers.Count): $(($triggers | ForEach-Object Title) -join ' | ')"
Assert (@($triggers | Where-Object { $_.Title -eq 'Gym' }).Count -eq 0) "non-qualifying event must not produce a trigger"
Assert (@($triggers | Where-Object { $_.Id -like 'ef34gh*' }).Count -eq 0) "a closed/done opportunity must never be a trigger"
Assert (@($triggers | Where-Object { $_.Id -like 'ij56kl*' }).Count -eq 0) "a non-qualifying (digest) opportunity subject must not be a trigger"
foreach ($t in $triggers) { Assert ($t.Id) "every trigger must carry a stable non-empty Id" }

# opportunity trigger id must be "<opportunity id>-<date>" (spec: id = event/opportunity id + date)
$oppTrigger = @($triggers | Where-Object { $_.Source -eq 'opportunity' })[0]
Assert ($oppTrigger.Id -eq 'ab12cd-2026-08-21') "opportunity trigger id must be '<opportunity id>-<date>' (got $($oppTrigger.Id))"

# 2) non-qualifying-only events/opportunities -> zero triggers
$noneTriggers = Select-StagingTriggers -Events @($nonQualifyingEvent) -Opportunities @($digestOpportunity, $closedOpportunity) -Now $now
Assert ($noneTriggers.Count -eq 0) "non-qualifying events/opportunities must produce zero triggers"

# ---------- Manifest: atomic write + idempotency ----------
$manifestPath = Join-Path $env:TEMP ('jarvis-staged-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  Assert ((Read-StagingManifest -Path $manifestPath).Count -eq 0) "a missing manifest reads as empty, not an error"

  $recs = Update-StagingManifest -Records @() -Id 'evt-aaa111-2026-08-21' -Date '2026-08-21' `
    -ArtifactPath 'C:\vault\outreach\staged\2026-08-21-x.md' -Path $manifestPath -Now $now
  Assert ($recs.Count -eq 1) "Update-StagingManifest must return the updated record set"
  Assert (Test-Path $manifestPath) "Update-StagingManifest must write the manifest file"
  # atomic write: no leftover .tmp-* files after a completed write (matches opportunity-store.ps1's pattern)
  $leftoverTmp = @(Get-ChildItem -Path (Split-Path $manifestPath) -Filter ((Split-Path $manifestPath -Leaf) + '.tmp-*') -ErrorAction SilentlyContinue)
  Assert ($leftoverTmp.Count -eq 0) "manifest write must be atomic (temp file, then rename) - no .tmp-* file may remain"
  $reread = Read-StagingManifest -Path $manifestPath
  Assert ($reread.Count -eq 1 -and $reread[0].Id -eq 'evt-aaa111-2026-08-21') "the manifest must round-trip through disk unchanged"

  Assert (Test-AlreadyStaged -Records $reread -Id 'evt-aaa111-2026-08-21') "an id present in the manifest must read as already-staged"
  Assert (-not (Test-AlreadyStaged -Records $reread -Id 'some-other-id')) "an id absent from the manifest must not read as already-staged"
} finally { Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue }

# ============================================================================
# Invoke-NightShift: the orchestrator. Name-shadow the claude invocation BEFORE
# extracting Invoke-NightShift, so it resolves to the stub, never the real CLI.
# ============================================================================
$global:InvokeCount = 0
$global:InvokeArgs  = @()
function Invoke-StagingClaudeGeneration {
  param($Trigger, [string]$ArtifactPath, [string]$SkillDir, [int]$TimeoutSec, [string]$LogPath)
  $global:InvokeCount++
  $global:InvokeArgs += ,$Trigger
  # simulate a successful agent run: it writes the artifact itself
  $dir = Split-Path $ArtifactPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Set-Content -Encoding UTF8 -LiteralPath $ArtifactPath -Value "# staged prep sheet`n`nTrigger: $($Trigger.Id)"
}
. ([scriptblock]::Create((Extract-Fn $stageSrc 'Invoke-NightShift')))

# ---- Test 1: qualifying event + empty manifest -> agent invoked once, artifact under outreach\staged\ ----
$vault1 = Join-Path $env:TEMP ('jarvis-stage-t1-' + [guid]::NewGuid().ToString('N'))
$manifest1 = Join-Path $env:TEMP ('jarvis-stage-t1-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
$log1 = Join-Path $env:TEMP ('jarvis-stage-t1-log-' + [guid]::NewGuid().ToString('N') + '.log')
try {
  $global:InvokeCount = 0; $global:InvokeArgs = @()
  $staged = Invoke-NightShift -Now $now -VaultPath $vault1 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest1 -StagingLogPath $log1 `
    -Events @($qualifyingEvent) -Opportunities @()
  Assert ($global:InvokeCount -eq 1) "one qualifying trigger + empty manifest must invoke the agent exactly once (got $($global:InvokeCount))"
  Assert ($staged -eq 1) "one successful stage must be reflected in the return count (got $staged)"
  $manifestAfter = Read-StagingManifest -Path $manifest1
  Assert ($manifestAfter.Count -eq 1) "a successful run must record exactly one manifest entry"
  $artifactPath = $manifestAfter[0].ArtifactPath
  $wantDir1 = (Join-Path $vault1 'outreach\staged') + '\'
  Assert ($artifactPath.StartsWith($wantDir1, [StringComparison]::OrdinalIgnoreCase)) `
    "the staged artifact must be written inside <vault>\outreach\staged\ and nowhere else (got $artifactPath)"
  Assert (Test-Path $artifactPath) "the artifact the agent 'wrote' must actually exist on disk"
} finally {
  Remove-Item $vault1 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest1 -Force -ErrorAction SilentlyContinue
  Remove-Item $log1 -Force -ErrorAction SilentlyContinue
}

# ---- Test 2: non-qualifying events/opportunities -> zero invocations ----
$vault2 = Join-Path $env:TEMP ('jarvis-stage-t2-' + [guid]::NewGuid().ToString('N'))
$manifest2 = Join-Path $env:TEMP ('jarvis-stage-t2-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  $global:InvokeCount = 0; $global:InvokeArgs = @()
  $staged2 = Invoke-NightShift -Now $now -VaultPath $vault2 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest2 -StagingLogPath '' `
    -Events @($nonQualifyingEvent) -Opportunities @($digestOpportunity)
  Assert ($global:InvokeCount -eq 0) "non-qualifying events/opportunities must never invoke the agent (got $($global:InvokeCount))"
  Assert ($staged2 -eq 0) "zero qualifying triggers must stage zero artifacts"
} finally {
  Remove-Item $vault2 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest2 -Force -ErrorAction SilentlyContinue
}

# ---- Test 3: second run with a populated manifest -> zero invocations (idempotency) ----
$vault3 = Join-Path $env:TEMP ('jarvis-stage-t3-' + [guid]::NewGuid().ToString('N'))
$manifest3 = Join-Path $env:TEMP ('jarvis-stage-t3-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  $global:InvokeCount = 0; $global:InvokeArgs = @()
  $firstRun = Invoke-NightShift -Now $now -VaultPath $vault3 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest3 -StagingLogPath '' -Events @($qualifyingEvent) -Opportunities @()
  Assert ($global:InvokeCount -eq 1) "sanity: the first run must invoke the agent once"

  $global:InvokeCount = 0; $global:InvokeArgs = @()
  $secondRun = Invoke-NightShift -Now $now.AddMinutes(5) -VaultPath $vault3 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest3 -StagingLogPath '' -Events @($qualifyingEvent) -Opportunities @()
  Assert ($global:InvokeCount -eq 0) "a second run against an already-populated manifest must invoke the agent zero times (got $($global:InvokeCount))"
  Assert ($secondRun -eq 0) "an idempotent re-run must stage zero NEW artifacts"
} finally {
  Remove-Item $vault3 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest3 -Force -ErrorAction SilentlyContinue
}

# ---- Test 4: a throwing agent must NOT update the manifest, must NOT touch .jarvis-runs.log, must log
#      the failure to the staging log, and the run must still complete (exit 0 from the wrapper's view) ----
Remove-Item function:Invoke-StagingClaudeGeneration -ErrorAction SilentlyContinue
function Invoke-StagingClaudeGeneration {
  param($Trigger, [string]$ArtifactPath, [string]$SkillDir, [int]$TimeoutSec, [string]$LogPath)
  throw "simulated agent failure for $($Trigger.Id)"
}

$vault4 = Join-Path $env:TEMP ('jarvis-stage-t4-' + [guid]::NewGuid().ToString('N'))
$manifest4 = Join-Path $env:TEMP ('jarvis-stage-t4-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
$log4 = Join-Path $env:TEMP ('jarvis-stage-t4-log-' + [guid]::NewGuid().ToString('N') + '.log')
$runLog4 = Join-Path $env:TEMP ('jarvis-stage-t4-runlog-' + [guid]::NewGuid().ToString('N') + '.jarvis-runs.log')
try {
  Set-Content -Encoding UTF8 -LiteralPath $runLog4 -Value "pre-existing content, must survive untouched`n"
  $hashBefore = (Get-FileHash -LiteralPath $runLog4 -Algorithm SHA256).Hash

  $staged4 = Invoke-NightShift -Now $now -VaultPath $vault4 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest4 -StagingLogPath $log4 -Events @($qualifyingEvent) -Opportunities @()

  Assert ($staged4 -eq 0) "a throwing agent must stage zero artifacts (return count reflects only successes)"
  Assert (-not (Test-Path $manifest4) -or (Read-StagingManifest -Path $manifest4).Count -eq 0) `
    "a throwing agent must NOT produce a manifest entry (crash-safe idempotency - record only after a successful write)"

  $hashAfter = (Get-FileHash -LiteralPath $runLog4 -Algorithm SHA256).Hash
  Assert ($hashAfter -eq $hashBefore) "a staging failure must never touch .jarvis-runs.log (owned exclusively by jarvis-debrief.ps1)"

  Assert (Test-Path $log4) "a staging failure must be recorded in stage-prep's OWN log"
  $log4Text = Get-Content -LiteralPath $log4 -Raw
  Assert ($log4Text -match 'FAILED' -and $log4Text -match 'simulated agent failure') `
    "the staging log must record the failure with enough detail to diagnose it (got: $log4Text)"
} finally {
  Remove-Item $vault4 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest4 -Force -ErrorAction SilentlyContinue
  Remove-Item $log4 -Force -ErrorAction SilentlyContinue
  Remove-Item $runLog4 -Force -ErrorAction SilentlyContinue
}

# ---- Test 5 (live-verification finding, 2026-08-20): a real headless run wrote a genuine, well-
# grounded artifact but under its OWN shortened filename instead of the exact path it was given ("
# outreach\staged\2026-08-21-synthetic.md" instead of the full computed slug). The strict exact-path
# check used to discard that as a failure and never record it. A same-directory, same-date file that
# is NEW since the call started must be accepted as the real result (still inside outreach\staged\ -
# the safety boundary is unaffected), and the manifest must record the file's ACTUAL path. ----
function Invoke-StagingClaudeGeneration {
  param($Trigger, [string]$ArtifactPath, [string]$SkillDir, [int]$TimeoutSec, [string]$LogPath)
  $global:InvokeCount++
  # deliberately writes under a DIFFERENT (shorter) filename than $ArtifactPath, in the same directory
  $dir = Split-Path $ArtifactPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $renamed = Join-Path $dir ("$($Trigger.Date)-renamed-by-agent.md")
  Set-Content -Encoding UTF8 -LiteralPath $renamed -Value "# staged prep sheet (agent chose its own name)`n`nTrigger: $($Trigger.Id)"
}

$vault5 = Join-Path $env:TEMP ('jarvis-stage-t5-' + [guid]::NewGuid().ToString('N'))
$manifest5 = Join-Path $env:TEMP ('jarvis-stage-t5-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
$log5 = Join-Path $env:TEMP ('jarvis-stage-t5-log-' + [guid]::NewGuid().ToString('N') + '.log')
try {
  $global:InvokeCount = 0
  $staged5 = Invoke-NightShift -Now $now -VaultPath $vault5 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest5 -StagingLogPath $log5 -Events @($qualifyingEvent) -Opportunities @()
  Assert ($staged5 -eq 1) "a differently-named-but-legitimate artifact must still count as a successful stage (got $staged5)"
  $manifest5Records = Read-StagingManifest -Path $manifest5
  Assert ($manifest5Records.Count -eq 1) "the manifest must still record exactly one entry"
  $recordedPath = $manifest5Records[0].ArtifactPath
  Assert ($recordedPath -match 'renamed-by-agent\.md$') "the manifest must record the artifact's ACTUAL path, not the path that was never written (got $recordedPath)"
  # Round-trip through the SAME Set-Location/Get-Location resolution the code's own Get-ChildItem
  # .FullName benefits from, not a raw string built from $env:TEMP or Resolve-Path (observed on this
  # PS 5.1 host, Resolve-Path does NOT expand an 8.3 short-path segment the way Get-Location does).
  # On some hosts (the GitHub Actions Windows runner, account "runneradmin") $env:TEMP is reported in
  # 8.3 short-path form (...\RUNNER~1\...) while Set-Location + Get-Location resolves the long form
  # (...\runneradmin\...) for the identical real directory - same class as
  # tests/claude-generation-timeout.Tests.ps1's fix (6361c2c), same proven technique.
  Push-Location -LiteralPath (Join-Path $vault5 'outreach\staged')
  $wantDir5 = (Get-Location).Path + '\'
  Pop-Location
  Assert ($recordedPath.StartsWith($wantDir5, [StringComparison]::OrdinalIgnoreCase)) `
    "the accepted fallback path must still be inside <vault>\outreach\staged\ (got $recordedPath)"
  Assert (Test-Path $recordedPath) "the recorded fallback artifact must actually exist on disk"
} finally {
  Remove-Item $vault5 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest5 -Force -ErrorAction SilentlyContinue
  Remove-Item $log5 -Force -ErrorAction SilentlyContinue
}

# ---- Test 6 (BUG 2 / sandbox finding 2026-08-21): the agent's REAL naming convention puts the date
# at the END of the filename (event-<hash>-<date>.md), which the old "$($t.Date)-*.md" PREFIX filter
# never matches - Update-StagingManifest was never reached, so the same calendar event silently
# re-invoked the paid CLI every single night forever (the actual cost bug). Detection must be a pure
# before/after directory diff (any new .md, regardless of name), not a date-prefix filter. The staged
# dir is pre-seeded with an unrelated pre-existing file to genuinely exercise the before/after diff. ----
function Invoke-StagingClaudeGeneration {
  param($Trigger, [string]$ArtifactPath, [string]$SkillDir, [int]$TimeoutSec, [string]$LogPath)
  $global:InvokeCount++
  $dir = Split-Path $ArtifactPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  # date at the END, unlike the given $ArtifactPath - the real agent naming convention
  $realName = Join-Path $dir ("event-abc123-$($Trigger.Date).md")
  Set-Content -Encoding UTF8 -LiteralPath $realName -Value "# staged prep sheet (agent's real naming)`n`nTrigger: $($Trigger.Id)"
}

$vault6 = Join-Path $env:TEMP ('jarvis-stage-t6-' + [guid]::NewGuid().ToString('N'))
$manifest6 = Join-Path $env:TEMP ('jarvis-stage-t6-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
$log6 = Join-Path $env:TEMP ('jarvis-stage-t6-log-' + [guid]::NewGuid().ToString('N') + '.log')
try {
  # pre-seed the staged dir with an unrelated old file BEFORE the run so $beforeNames diff is genuinely exercised
  $stagedDir6 = Join-Path $vault6 'outreach\staged'
  New-Item -ItemType Directory -Force -Path $stagedDir6 | Out-Null
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $stagedDir6 '2026-08-01-old.md') -Value "pre-existing unrelated file"

  $global:InvokeCount = 0
  $staged6 = Invoke-NightShift -Now $now -VaultPath $vault6 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest6 -StagingLogPath $log6 -Events @($qualifyingEvent) -Opportunities @()
  Assert ($staged6 -eq 1) "an artifact named with the date at the END must still be recognised and staged (got $staged6)"
  $manifest6Records = Read-StagingManifest -Path $manifest6
  Assert ($manifest6Records.Count -eq 1) "the manifest must record exactly one entry"
  $recordedPath6 = $manifest6Records[0].ArtifactPath
  Assert ($recordedPath6 -match 'event-abc123-.*\.md$') "the manifest must record the agent's real filename (got $recordedPath6)"
  # Same 8.3 short-path vs. long-path normalization as test 5 above (and 6361c2c) - round-trip through
  # Set-Location/Get-Location rather than comparing against a raw $env:TEMP-built string.
  Push-Location -LiteralPath $stagedDir6
  $wantDir6 = (Get-Location).Path + '\'
  Pop-Location
  Assert ($recordedPath6.StartsWith($wantDir6, [StringComparison]::OrdinalIgnoreCase)) `
    "the accepted artifact must still be inside <vault>\outreach\staged\ (got $recordedPath6)"
  $log6Text = Get-Content -LiteralPath $log6 -Raw
  Assert ($log6Text -match 'NOTE' -and $log6Text -match 'agent used a different filename') `
    "the staging log must record the filename mismatch NOTE (got: $log6Text)"

  # THE KEY ASSERTION - re-run against the same manifest/event a second time: zero repeat paid invocations
  $global:InvokeCount = 0
  $staged6b = Invoke-NightShift -Now $now.AddMinutes(5) -VaultPath $vault6 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest6 -StagingLogPath $log6 -Events @($qualifyingEvent) -Opportunities @()
  Assert ($global:InvokeCount -eq 0) "a second run against the same already-staged event must invoke the agent zero times (got $($global:InvokeCount)) - this is the production cost bug"
  Assert ($staged6b -eq 0) "a second run must stage zero NEW artifacts"
} finally {
  Remove-Item $vault6 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest6 -Force -ErrorAction SilentlyContinue
  Remove-Item $log6 -Force -ErrorAction SilentlyContinue
}

# ---- Test 7 (ambiguity guard survives the widened *.md filter): if the agent leaves TWO new
# differently-named .md files behind (neither at the exact given path), that is genuinely ambiguous -
# must still FAIL loudly rather than guess, exactly as before the widened diff. ----
function Invoke-StagingClaudeGeneration {
  param($Trigger, [string]$ArtifactPath, [string]$SkillDir, [int]$TimeoutSec, [string]$LogPath)
  $global:InvokeCount++
  $dir = Split-Path $ArtifactPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $dir "event-one-$($Trigger.Date).md") -Value "ambiguous candidate one"
  Set-Content -Encoding UTF8 -LiteralPath (Join-Path $dir "event-two-$($Trigger.Date).md") -Value "ambiguous candidate two"
}

$vault7 = Join-Path $env:TEMP ('jarvis-stage-t7-' + [guid]::NewGuid().ToString('N'))
$manifest7 = Join-Path $env:TEMP ('jarvis-stage-t7-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
$log7 = Join-Path $env:TEMP ('jarvis-stage-t7-log-' + [guid]::NewGuid().ToString('N') + '.log')
try {
  $global:InvokeCount = 0
  $staged7 = Invoke-NightShift -Now $now -VaultPath $vault7 -SkillDir 'C:\fake-skill' `
    -ManifestPath $manifest7 -StagingLogPath $log7 -Events @($qualifyingEvent) -Opportunities @()
  Assert ($staged7 -eq 0) "two ambiguous new files must NOT be silently accepted (got $staged7)"
  $manifest7Records = @(Read-StagingManifest -Path $manifest7)
  Assert ($manifest7Records.Count -eq 0) "an ambiguous result must not produce a manifest entry"
  $log7Text = Get-Content -LiteralPath $log7 -Raw
  Assert ($log7Text -match 'FAILED' -and $log7Text -match 'ambiguous') `
    "the staging log must record the ambiguity as a failure (got: $log7Text)"
} finally {
  Remove-Item $vault7 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $manifest7 -Force -ErrorAction SilentlyContinue
  Remove-Item $log7 -Force -ErrorAction SilentlyContinue
}

Write-Host "stage-prep: ALL PASS"
