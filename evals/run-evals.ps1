# evals/run-evals.ps1 - the behavioral eval harness. Jarvis has dozens of deterministic suites
# (tests/*.Tests.ps1 - see README "Tests, and what they actually guarantee" for the exact, CI-recounted
# total) and zero coverage of its actual product: the model's judgment. This is that coverage.
#
# Two tiers:
#   -Mode ci    (default) NO network, NEVER invokes the claude CLI. Asserts prompt-ASSEMBLY properties
#               per scenario by calling the REAL production functions (Build-ChatPrompt,
#               Classify-JobMailSubject, Select-OpportunityAlerts, Test-StagingQualifies, ...) with
#               fixture inputs, then regex-checks the assembled text. Wired into .github/workflows/tests.yml
#               - every PR runs it, exactly like the plain-assertion tests/*.Tests.ps1 suites.
#   -Mode live  LOCAL ONLY. Invokes the real `claude` CLI headlessly per scenario, self-contained (the
#               fixture's canned collector/vault data is embedded directly in the prompt - no real
#               collector script and no real vault are touched), with --allowedTools "" (no tool use at
#               all: this eval is model-judgment-only, and giving it real tools would both loosen the
#               live agent's tool denials and widen blast radius for no grading benefit - explicitly
#               out of scope). Grades deterministic-first; llm_judge only breaks a tie regex cannot
#               decide. Writes evals/results/<date>.md. Bounded by evals/config.json's
#               max_scenarios_per_run (blast-radius cap) and a hard per-scenario timeout (runaway cap).
#
# Scenario format: evals/scenarios/<name>/fixture.json (canned collector output + vault snippets + the
# trigger) and checks.json (ordered deterministic checks, optionally scoped to one tier via "tiers").
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param(
  [ValidateSet('ci','live')][string]$Mode = 'ci',
  [string]$ScenariosDir = (Join-Path $PSScriptRoot 'scenarios'),
  [string]$ResultsDir   = (Join-Path $PSScriptRoot 'results'),
  [string]$ConfigPath   = (Join-Path $PSScriptRoot 'config.json'),
  [string[]]$Only,
  # house convention (see get-jarvis-config.ps1 / check-job-mail.ps1): dot-source this file plain to
  # load just the functions, for testing - no param block clobbering, and Main never runs.
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'
$script:EvalsRoot = $PSScriptRoot
$script:RepoRoot  = Resolve-Path (Join-Path $PSScriptRoot '..')
$script:BinDir    = Join-Path $script:RepoRoot 'skill\bin'
$script:SkillDir  = Join-Path $script:RepoRoot 'skill'

# ---------- config ----------

function Get-EvalConfig {
  param([string]$Path = (Join-Path $script:EvalsRoot 'config.json'))
  $defaults = [ordered]@{ max_scenarios_per_run = 6; live_timeout_sec = 600; judge_timeout_sec = 120 }
  if (-not (Test-Path -LiteralPath $Path)) { return $defaults }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($k in @('max_scenarios_per_run','live_timeout_sec','judge_timeout_sec')) {
      if ($raw.PSObject.Properties.Name -contains $k) { $defaults[$k] = [int]$raw.$k }
    }
  } catch { }
  return $defaults
}

# ---------- discovery ----------

function Find-EvalScenarios {
  # A malformed scenario dir (missing fixture.json or checks.json) is reported as its OWN failure, not
  # silently skipped - tests/eval-harness.Tests.ps1 item 3 pins this.
  param([string]$Dir)
  $found = New-Object System.Collections.Generic.List[pscustomobject]
  if (-not (Test-Path -LiteralPath $Dir)) { return $found }
  foreach ($d in (Get-ChildItem -LiteralPath $Dir -Directory | Sort-Object Name)) {
    $fixturePath = Join-Path $d.FullName 'fixture.json'
    $checksPath  = Join-Path $d.FullName 'checks.json'
    $errs = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $fixturePath)) { $errs.Add('missing fixture.json') }
    if (-not (Test-Path -LiteralPath $checksPath))  { $errs.Add('missing checks.json') }
    $found.Add([pscustomobject]@{
      Name = $d.Name; Path = $d.FullName; FixturePath = $fixturePath; ChecksPath = $checksPath
      Errors = @($errs)
    })
  }
  return $found
}

function Get-EvalJsonFile {
  param([string]$Path, [string]$Label)
  try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
  catch { throw "malformed $Label at ${Path}: $($_.Exception.Message)" }
}

# ---------- grading ----------

function Test-EvalCheckApplies {
  param($Check, [string]$Mode)
  if (-not ($Check.PSObject.Properties.Name -contains 'tiers')) { return $true }
  if (-not $Check.tiers) { return $true }
  return (@($Check.tiers) -contains $Mode)
}

function Invoke-EvalChecks {
  # Deterministic-first grading, the repo's own convention applied to eval scenarios: must_match /
  # must_not_match run IN ORDER and a failure SHORT-CIRCUITS everything after it (both remaining
  # deterministic checks and every llm_judge check) - tests/eval-harness.Tests.ps1 item 4 pins this.
  # llm_judge is consulted only when it is reached with no deterministic fail ahead of it, and only
  # when a $JudgeFn is supplied (ci mode never has one - it never calls claude at all).
  param([string]$Transcript, [array]$Checks, [string]$Mode, [scriptblock]$JudgeFn)
  $results = New-Object System.Collections.Generic.List[pscustomobject]
  $failed = $false
  $deterministic = @($Checks | Where-Object { $_.type -eq 'must_match' -or $_.type -eq 'must_not_match' })
  $judged        = @($Checks | Where-Object { $_.type -eq 'llm_judge' })

  foreach ($c in $deterministic) {
    if (-not (Test-EvalCheckApplies $c $Mode)) {
      $results.Add([pscustomobject]@{ Type = $c.type; Description = $c.description; Status = 'skipped (tier)' }); continue
    }
    if ($failed) {
      $results.Add([pscustomobject]@{ Type = $c.type; Description = $c.description; Status = 'skipped (short-circuit)' }); continue
    }
    $isMatch = [bool]($Transcript -match $c.pattern)
    $ok = if ($c.type -eq 'must_match') { $isMatch } else { -not $isMatch }
    if ($ok) {
      $results.Add([pscustomobject]@{ Type = $c.type; Description = $c.description; Status = 'pass' })
    } else {
      $results.Add([pscustomobject]@{ Type = $c.type; Description = $c.description; Status = 'FAIL'; Pattern = $c.pattern })
      $failed = $true
    }
  }

  foreach ($c in $judged) {
    if (-not (Test-EvalCheckApplies $c $Mode)) {
      $results.Add([pscustomobject]@{ Type = 'llm_judge'; Description = $c.description; Status = 'skipped (tier)' }); continue
    }
    if ($failed) {
      $results.Add([pscustomobject]@{ Type = 'llm_judge'; Description = $c.description; Status = 'skipped (deterministic fail)' }); continue
    }
    if (-not $JudgeFn) {
      $results.Add([pscustomobject]@{ Type = 'llm_judge'; Description = $c.description; Status = 'skipped (no judge - deterministic checks only)' }); continue
    }
    $verdict = & $JudgeFn $Transcript $c.criterion
    if ($verdict -eq $true) {
      $results.Add([pscustomobject]@{ Type = 'llm_judge'; Description = $c.description; Status = 'pass' })
    } else {
      $results.Add([pscustomobject]@{ Type = 'llm_judge'; Description = $c.description; Status = 'FAIL' })
      $failed = $true
    }
  }

  return [pscustomobject]@{ Passed = (-not $failed); Results = @($results) }
}

# ---------- ci-tier assembly (real production functions, fixture inputs, zero network) ----------

function Get-EvalVaultText {
  param($Vault)
  if (-not $Vault) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($p in $Vault.PSObject.Properties) {
    [void]$sb.AppendLine("=== $($p.Name) ===")
    [void]$sb.AppendLine([string]$p.Value)
    [void]$sb.AppendLine('')
  }
  return $sb.ToString()
}

function Get-EvalCollectorText {
  param($Collectors)
  if (-not $Collectors) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($p in $Collectors.PSObject.Properties) {
    if ($p.Name -eq 'jobmail_alerts') { continue }   # consumed directly by the opportunity_sweep path
    [void]$sb.AppendLine("## collector: $($p.Name)")
    [void]$sb.AppendLine(($p.Value | ConvertTo-Json -Depth 8))
    [void]$sb.AppendLine('')
  }
  return $sb.ToString()
}

function Assemble-CiArtifact {
  # Builds the text that -Mode ci grades. NOT a model transcript - it is the assembled INSTRUCTIONS
  # (and, where a pure production function exists, that function's REAL output on the fixture) that a
  # live run would have received. That is the whole ci-tier contract: prove the assembly is correct
  # without ever calling claude.
  param([string]$ScenarioName, $Fixture)
  $vaultText = Get-EvalVaultText $Fixture.vault
  $collectorText = Get-EvalCollectorText $Fixture.collectors

  switch ($Fixture.trigger.type) {
    'debrief' {
      $skillText   = Get-Content -LiteralPath (Join-Path $script:SkillDir 'SKILL.md') -Raw
      $debriefText = Get-Content -LiteralPath (Join-Path $script:SkillDir 'references\debrief.md') -Raw
      return @($skillText, $debriefText, '--- FIXTURE VAULT ---', $vaultText, '--- FIXTURE COLLECTORS ---', $collectorText) -join "`n`n"
    }
    'telegram' {
      . (Join-Path $script:BinDir 'telegram-chat.ps1')
      if ($Fixture.collectors -and ($Fixture.collectors.PSObject.Properties.Name -contains 'bank')) {
        $collectorText += "`n## collector: bank-scope-note`n" + ((Get-ChatBankScopeNote) -join "`n")
      }
      $persona = Get-ChatPersona
      $nonce   = New-ChatNonce
      $receipt = New-ChatNonce
      $prompt  = Build-ChatPrompt -Message $Fixture.trigger.message -Persona $persona -CollectorText $collectorText -History '' -Nonce $nonce -Receipt $receipt
      return @($prompt, '--- FIXTURE VAULT ---', $vaultText) -join "`n`n"
    }
    'opportunity_sweep' {
      . (Join-Path $script:BinDir 'check-job-mail.ps1') -DotSourceOnly
      . (Join-Path $script:BinDir 'check-opportunities.ps1') -DotSourceOnly
      $alerts = @()
      foreach ($a in @($Fixture.collectors.jobmail_alerts)) {
        $alerts += [pscustomobject]@{ From = $a.from; Subject = $a.subject; Date = $a.date }
      }
      $tagged = @(Add-JobMailClassification $alerts)
      $opportunities = @(Select-OpportunityAlerts $tagged)
      $header = (Get-Content -LiteralPath (Join-Path $script:BinDir 'check-opportunities.ps1') -TotalCount 25) -join "`n"
      return @(
        $header,
        '--- TAGGED ALERTS (real Add-JobMailClassification) ---',
        (ConvertTo-Json -InputObject $tagged -Depth 6),
        '--- ALARM-WORTHY (opportunities only) --- (real Select-OpportunityAlerts)',
        (ConvertTo-Json -InputObject $opportunities -Depth 6)
      ) -join "`n`n"
    }
    'staging' {
      . (Join-Path $script:BinDir 'check-job-mail.ps1') -DotSourceOnly
      $src = Get-Content -LiteralPath (Join-Path $script:BinDir 'stage-prep.ps1') -Raw
      $m = [regex]::Match($src, '(?ms)^function Test-StagingQualifies \{.*?\n\}')
      $qualifies = $false
      if ($m.Success) {
        . ([scriptblock]::Create($m.Value))
        if (Get-Command Test-StagingQualifies -ErrorAction SilentlyContinue) {
          $qualifies = Test-StagingQualifies -Text $Fixture.trigger.text
        }
      }
      $stagingDoc = Get-Content -LiteralPath (Join-Path $script:SkillDir 'references\staging.md') -Raw
      return @(
        $stagingDoc,
        '--- FIXTURE TRIGGER ---', $Fixture.trigger.text,
        "QUALIFIES: $qualifies   (real Test-StagingQualifies, extracted from stage-prep.ps1)",
        '--- FIXTURE VAULT ---', $vaultText
      ) -join "`n`n"
    }
    default { throw "unknown fixture trigger.type '$($Fixture.trigger.type)' for scenario $ScenarioName" }
  }
}

# ---------- live-tier assembly + real claude invocation ----------

function Assemble-LivePrompt {
  # A SELF-CONTAINED prompt: fixture vault/collector data is embedded inline, never a real file or a
  # real network call, so a live run touches nothing of Alex's actual vault or accounts. Deliberately
  # runs with NO tools at all (see Invoke-EvalClaude) - loosening the live agent's tool denials for an
  # eval is explicitly out of scope.
  param([string]$ScenarioName, $Fixture)
  $vaultText = Get-EvalVaultText $Fixture.vault
  $collectorText = Get-EvalCollectorText $Fixture.collectors
  $noTools = 'This is an automated eval fixture: you have NO tools and no network access. Do not attempt to read files, run commands, or fetch anything - everything you need is inline below. Respond only in text.'

  switch ($Fixture.trigger.type) {
    'debrief' {
      $skillText   = Get-Content -LiteralPath (Join-Path $script:SkillDir 'SKILL.md') -Raw
      $debriefText = Get-Content -LiteralPath (Join-Path $script:SkillDir 'references\debrief.md') -Raw
      return "You are Jarvis, running the debrief procedure headlessly for this eval fixture. $noTools`n`n" +
        "--- YOUR INSTRUCTIONS ---`n$skillText`n`n$debriefText`n`n" +
        "--- YOUR VAULT (fixture only) ---`n$vaultText`n`n" +
        "--- YOUR COLLECTOR OUTPUT (fixture only) ---`n$collectorText`n`n" +
        "Produce ONLY the finished debrief note per the template above, nothing else."
    }
    'telegram' {
      . (Join-Path $script:BinDir 'telegram-chat.ps1')
      if ($Fixture.collectors -and ($Fixture.collectors.PSObject.Properties.Name -contains 'bank')) {
        $collectorText += "`n## collector: bank-scope-note`n" + ((Get-ChatBankScopeNote) -join "`n")
      }
      # The real production agent answers a vault question by READING the vault (Read/Glob/Grep,
      # scoped). This eval grants NO tools at all (see header comment), so the fixture's vault
      # snippets are folded into the collector block instead - otherwise a scenario like
      # money-with-vault-context is unwinnable by construction (the model correctly says "I have no
      # file access", which is true here but not a finding about whether it WOULD have consulted
      # FINANCE.md with real access - measured live 2026-08-20, first run, before this line existed).
      # Folded in BEFORE Build-ChatPrompt, not appended after its return, so the receipt token stays
      # the prompt's true last line per Build-ChatPrompt's own documented contract.
      if ($vaultText.Trim()) { $collectorText += "`n## fixture: vault notes (inline - no Read tool in this eval)`n$vaultText" }
      $persona = Get-ChatPersona
      $nonce   = New-ChatNonce
      $receipt = New-ChatNonce
      $prompt  = Build-ChatPrompt -Message $Fixture.trigger.message -Persona $persona -CollectorText $collectorText -History '' -Nonce $nonce -Receipt $receipt
      return "$prompt`n`n($noTools)"
    }
    'opportunity_sweep' {
      . (Join-Path $script:BinDir 'check-job-mail.ps1') -DotSourceOnly
      $alerts = @()
      foreach ($a in @($Fixture.collectors.jobmail_alerts)) {
        $alerts += [pscustomobject]@{ From = $a.from; Subject = $a.subject; Date = $a.date }
      }
      $tagged = @(Add-JobMailClassification $alerts)
      return "You are Jarvis's hourly opportunity sweep, running headlessly for this eval fixture. $noTools`n`n" +
        "Rule: assessment/interview/offer mail is an open door and earns an immediate push (with a one-line " +
        "'why now'); rejection mail is unactionable and must wait for the next 08:30 debrief, never an immediate push.`n`n" +
        "--- TAGGED MAIL (fixture) ---`n" + (ConvertTo-Json -InputObject $tagged -Depth 6) + "`n`n" +
        "Reply in exactly this shape, in this order, and do not deviate: (1) a line 'Classification: <the " +
        "Classification field, verbatim>'; (2) one or two sentences of reasoning applying the rule to that " +
        "classification (a rejection classification always yields DEFER, an interview/offer classification " +
        "always yields PUSH - state which this is and, if PUSH, the one-line 'why now', all within this " +
        "reasoning section); (3) a blank line; (4) a FINAL line containing nothing else at all but the single " +
        "word PUSH or DEFER, matching the verdict you already reasoned to. That word must appear exactly " +
        "once in your whole reply, on that final line, and nowhere earlier - do not open with it."
    }
    'staging' {
      $stagingDoc = Get-Content -LiteralPath (Join-Path $script:SkillDir 'references\staging.md') -Raw
      return "You are Jarvis's Night Shift staging agent, running headlessly for this eval fixture. $noTools`n`n" +
        "--- YOUR INSTRUCTIONS ---`n$stagingDoc`n`n" +
        "--- TRIGGER ---`n$($Fixture.trigger.text)`n`n" +
        "--- YOUR LOCAL DATA (fixture only, this is the ENTIRE available source set) ---`n$vaultText`n`n" +
        "Produce ONLY the staged prep-sheet artifact body (with its provenance header) per the procedure above."
    }
    default { throw "unknown fixture trigger.type '$($Fixture.trigger.type)' for scenario $ScenarioName" }
  }
}

function Invoke-EvalClaude {
  # Same bounded-job / tree-kill pattern as jarvis-debrief.ps1's and stage-prep.ps1's own
  # Invoke-ClaudeGeneration - duplicated rather than shared for the same reason those two duplicate each
  # other (see their own comments): this file has to remain independently dot-sourceable for tests
  # without dragging in either script's top-level config/vault resolution.
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [int]$TimeoutSec = 600,
    [scriptblock]$JobScript = {
      param($p, $pidFile)
      if ($pidFile) { try { Set-Content -LiteralPath $pidFile -Value $PID -ErrorAction Stop } catch { } }
      # THE PROMPT TRAVELS OVER STDIN, NEVER ARGV. A naive '& claude -p $p' builds $p into the native
      # command line, and PS 5.1 strips embedded double quotes when it does that - the exact
      # argv-shredding class documented elsewhere in this repo (jarvis-debrief.ps1's latent KNOWN_ISSUES
      # gap; telegram-chat.ps1's own fix for it). It is not latent here: eval prompts embed real
      # SKILL.md/debrief.md content, which is full of double-quoted prose ("Nothing needs you today,
      # Sir." etc.), and the naive form was measured to corrupt the invocation on the very first live
      # run of this harness (2026-08-20 - claude read a fragment of the prompt as a bare CLI flag and
      # errored on it). Same --input-format text / stdin pattern telegram-chat.ps1 uses for its own
      # live invocation; NO --allowedTools grant at all, since this eval is model-judgment-only and
      # widening tool access is the one change explicitly out of scope for this harness.
      $exe = @(Get-Command claude -CommandType Application -ErrorAction Stop)[0].Source
      $claudeArgs = @('-p', '--allowedTools', '', '--input-format', 'text', '--output-format', 'json')
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName  = $exe
      $psi.Arguments = (($claudeArgs | ForEach-Object { '"' + [string]$_ + '"' }) -join ' ')
      $psi.RedirectStandardInput  = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
      $psi.StandardErrorEncoding  = New-Object System.Text.UTF8Encoding($false)
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow  = $true
      $proc = [System.Diagnostics.Process]::Start($psi)
      $outTask = $proc.StandardOutput.ReadToEndAsync()
      $errTask = $proc.StandardError.ReadToEndAsync()
      $promptBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($p)
      $stdin = $proc.StandardInput.BaseStream
      $stdin.Write($promptBytes, 0, $promptBytes.Length)
      $stdin.Flush()
      $stdin.Close()
      $proc.WaitForExit()
      $stdoutText = $outTask.GetAwaiter().GetResult()
      $stderrText = ''
      try { $stderrText = $errTask.GetAwaiter().GetResult() } catch { }
      if ($proc.ExitCode -ne 0 -and -not $stdoutText) { return "claude exited $($proc.ExitCode): $stderrText" }
      return $stdoutText
    }
  )
  $pidFile = $null
  try {
    $pidFile = Join-Path $env:TEMP ('jarvis-eval-pid-' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $pidFile -Value 'pending' -ErrorAction Stop
  } catch { $pidFile = $null }
  try {
    $job = Start-Job -ScriptBlock $JobScript -ArgumentList $Prompt, $pidFile
    $done = Wait-Job $job -Timeout $TimeoutSec
    if (-not $done) {
      if ($pidFile -and (Test-Path -LiteralPath $pidFile)) {
        $hostPidText = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
        if ($hostPidText -match '^\s*(\d+)\s*$') { try { & taskkill /PID $Matches[1] /T /F 2>$null | Out-Null } catch { } }
      }
      try { Stop-Job $job -ErrorAction SilentlyContinue } catch { }
      try { Remove-Job $job -Force -ErrorAction SilentlyContinue } catch { }
      throw "claude generation exceeded $([math]::Round($TimeoutSec / 60))m timeout"
    }
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    $state = $job.State
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($state -ne 'Completed') { throw "claude job did not complete cleanly (state: $state)" }
    $text = ($result -join "`n")
    try {
      $parsed = $text | ConvertFrom-Json
      if ($parsed.PSObject.Properties.Name -contains 'result') { return [string]$parsed.result }
    } catch { }
    return $text
  } finally {
    if ($pidFile) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-EvalJudge {
  # llm_judge is a TIE-BREAKER, never the primary grader (out of scope: "LLM-judge as primary grader" -
  # deterministic checks always run first and a deterministic fail means this is never even called; see
  # Invoke-EvalChecks). One extra bounded claude call, strict PASS/FAIL first token.
  param([string]$Transcript, [string]$Criterion, [int]$TimeoutSec = 120)
  $prompt = "You are grading a transcript against ONE criterion for an automated eval. Answer with " +
    "exactly one word, PASS or FAIL, on the first line, then one short sentence of reasoning.`n`n" +
    "Criterion: $Criterion`n`n--- TRANSCRIPT ---`n$Transcript`n--- END TRANSCRIPT ---"
  $out = Invoke-EvalClaude -Prompt $prompt -TimeoutSec $TimeoutSec
  return [bool]($out -match '^\s*PASS\b')
}

# ---------- results ----------

function Get-EvalSanitizePatterns {
  # Same patterns tests/no-personal-values.Tests.ps1 hunts in tracked source, applied here to
  # committed golden transcripts for the identical reason: a real live run's fixture data is synthetic,
  # but the MODEL's own reply text is free-form and could echo something machine-specific if it ever
  # slipped past a collector's own scrubbing.
  return @(
    'C:\\Users\\[A-Za-z0-9_]+',
    'C:/Users/[A-Za-z0-9_]+',
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    'com\.alexdrozdovs',
    '12-jarvis',
    'claude-memory',
    'Life Roadmap'
  )
}

function Protect-EvalSanitize {
  param([string]$Text)
  if (-not $Text) { return $Text }
  $out = $Text
  foreach ($p in (Get-EvalSanitizePatterns)) { $out = [regex]::Replace($out, $p, '[redacted]') }
  return $out
}

function Write-EvalResultsFile {
  # Atomic: write to a uniquely-named temp file, then Move-Item -Force (same volume) so a reader never
  # observes a half-written results file, and a crash mid-write leaves the PREVIOUS day's file intact
  # rather than a truncated one under today's name.
  param([string]$Date, [array]$ScenarioResults, [string]$ResultsDir, [string]$Mode)
  if (-not (Test-Path -LiteralPath $ResultsDir)) { New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null }
  $path = Join-Path $ResultsDir "$Date.md"
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# Eval results - $Date ($Mode mode)")
  [void]$sb.AppendLine('')
  foreach ($r in $ScenarioResults) {
    [void]$sb.AppendLine("## $($r.Name) - $(if ($r.Passed) { 'PASS' } else { 'FAIL' })")
    [void]$sb.AppendLine('')
    foreach ($c in $r.Checks) {
      $extra = if ($c.PSObject.Properties.Name -contains 'Pattern' -and $c.Pattern) { " (pattern: ``$($c.Pattern)``)" } else { '' }
      [void]$sb.AppendLine("- [$($c.Status)] $($c.Type): $($c.Description)$extra")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('<details><summary>transcript</summary>')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine((Protect-EvalSanitize $r.Transcript))
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('</details>')
    [void]$sb.AppendLine('')
  }
  $tmp = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
  Set-Content -LiteralPath $tmp -Value $sb.ToString() -Encoding UTF8 -ErrorAction Stop
  Move-Item -LiteralPath $tmp -Destination $path -Force
  return $path
}

# ---------- orchestration ----------

function Invoke-EvalRun {
  param(
    [string]$Mode, [string]$ScenariosDir, [string]$ResultsDir, [string[]]$Only, $Cfg,
    [scriptblock]$ClaudeFn = ${function:Invoke-EvalClaude}
  )
  $scenarios = Find-EvalScenarios -Dir $ScenariosDir
  if ($Only) { $scenarios = @($scenarios | Where-Object { $Only -contains $_.Name }) }

  # Blast-radius cap: -Mode live invokes a real model per scenario. -Mode ci never touches the network
  # or claude at all, so the cap does not apply to it (see header comment).
  if ($Mode -eq 'live' -and $Cfg.max_scenarios_per_run -and $scenarios.Count -gt [int]$Cfg.max_scenarios_per_run) {
    throw "run budget exceeded: $($scenarios.Count) scenarios requested, cap is $($Cfg.max_scenarios_per_run) (evals/config.json max_scenarios_per_run)"
  }

  $allResults = New-Object System.Collections.Generic.List[pscustomobject]
  $overallPass = $true

  foreach ($s in $scenarios) {
    if ($s.Errors.Count -gt 0) {
      Write-Host "FAIL  $($s.Name)  ($($s.Errors -join '; '))"
      $allResults.Add([pscustomobject]@{ Name = $s.Name; Passed = $false; Checks = @(); Transcript = "scenario discovery error: $($s.Errors -join '; ')" })
      $overallPass = $false
      continue
    }

    try {
      $fixture = Get-EvalJsonFile -Path $s.FixturePath -Label 'fixture.json'
      $checksDoc = Get-EvalJsonFile -Path $s.ChecksPath -Label 'checks.json'
      $checks = @($checksDoc.checks)

      if ($Mode -eq 'ci') {
        $transcript = Assemble-CiArtifact -ScenarioName $s.Name -Fixture $fixture
        $grade = Invoke-EvalChecks -Transcript $transcript -Checks $checks -Mode 'ci' -JudgeFn $null
      } else {
        $prompt = Assemble-LivePrompt -ScenarioName $s.Name -Fixture $fixture
        $transcript = & $ClaudeFn -Prompt $prompt -TimeoutSec $Cfg.live_timeout_sec
        $judgeTimeout = [int]$Cfg.judge_timeout_sec
        $judgeFn = { param($t, $c) Invoke-EvalJudge -Transcript $t -Criterion $c -TimeoutSec $judgeTimeout }
        $grade = Invoke-EvalChecks -Transcript $transcript -Checks $checks -Mode 'live' -JudgeFn $judgeFn
      }
    } catch {
      Write-Host "FAIL  $($s.Name)  (error: $($_.Exception.Message))"
      $allResults.Add([pscustomobject]@{ Name = $s.Name; Passed = $false; Checks = @(); Transcript = "error: $($_.Exception.Message)" })
      $overallPass = $false
      continue
    }

    if ($grade.Passed) {
      Write-Host "PASS  $($s.Name)"
    } else {
      Write-Host "FAIL  $($s.Name)"
      foreach ($r in $grade.Results) { if ($r.Status -eq 'FAIL') { Write-Host "      $($r.Type): $($r.Description)" } }
      $overallPass = $false
    }
    $allResults.Add([pscustomobject]@{ Name = $s.Name; Passed = $grade.Passed; Checks = @($grade.Results); Transcript = $transcript })
  }

  if ($Mode -eq 'live' -and $allResults.Count -gt 0) {
    $date = Get-Date -Format 'yyyy-MM-dd'
    $path = Write-EvalResultsFile -Date $date -ScenarioResults $allResults -ResultsDir $ResultsDir -Mode $Mode
    Write-Host "results written: $path"
  }

  return [pscustomobject]@{ Passed = $overallPass; Results = @($allResults) }
}

# ---------- entry point ----------

if (-not $DotSourceOnly) {
  $cfg = Get-EvalConfig -Path $ConfigPath
  $run = Invoke-EvalRun -Mode $Mode -ScenariosDir $ScenariosDir -ResultsDir $ResultsDir -Only $Only -Cfg $cfg
  if ($run.Passed) { Write-Host "evals ($Mode): ALL PASS"; exit 0 }
  else { Write-Host "evals ($Mode): FAILED"; exit 1 }
}
