# skill/bin/jarvis-debrief.ps1 - run by Task Scheduler at 08:30 (or manually from a NORMAL terminal).
# -Channel overrides where the finished note is delivered (telegram | email | both); default reads
# CONFIG.md 'debrief_delivery' (falling back to email). The Telegram /debrief command passes 'telegram'.
# -OnDemand marks a run Alex explicitly asked for (Telegram /debrief, tray "Debrief now") so it is not
# judged against 08:30 and mis-stamped a late catch-up. The SCHEDULED task passes neither flag.
param([ValidateSet('telegram','email','both','')][string]$Channel = '', [switch]$OnDemand)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\get-jarvis-config.ps1"
$jcfg     = Get-JarvisConfig
$vault    = $jcfg.vault_path
$skillDir = $jcfg.skill_dir
$today    = Get-Date -Format 'yyyy-MM-dd'
$note     = Join-Path $vault "debriefs\$today.md"
$sender   = Join-Path $PSScriptRoot 'send-debrief.ps1'

# F1: this is the SCRIPT'S OWN health-log channel, deliberately named ".jarvis-runs.log" rather
# than the old ".jarvis.log". The old shared file let the subagent forge its own "run ok"/"run
# FAILED" lines into the same log the wrapper used for its real status (skill/references/debrief.md
# told it to READ the tail, but it went further and wrote to it too - sometimes with malformed/empty
# timestamps or mojibake). Since parseLogTail only looks at the LAST matching line, a forged agent
# line landing after a real failure made the health monitor report "normal" on days the real script
# never wrote a real success line. The wrapper is now the ONLY writer to this file.
#
# NOTE: unlike the aspiration once written here, the agent IS told this exact filename - both
# skill/references/debrief.md and skill/SKILL.md name ".jarvis-runs.log" explicitly (the Health
# module has to read it to report status, and tests/log-write-boundary.Tests.ps1 pins the filename
# being present in both docs). So this is NOT secrecy-based protection - the agent has both the
# path and Write/Edit/Bash access, and could technically write to it. What actually holds the line
# is (a) an explicit "never write" prohibition in both docs (SKILL.md Safety rule 8) and (b)
# app/lib/livestate.js's parseLogTail hardening (F2), which ignores any "run ok" line lacking a
# genuine "via <channel>" suffix regardless of who wrote it - so even a forged line can no longer
# flip health to "normal". Do not rely on filename secrecy here; there isn't any.
$runLog   = Join-Path $vault "debriefs\.jarvis-runs.log"
# F6: per-date filename (was the single ".jarvis-claude.log", overwritten every run). A prior day's
# failure was once undiagnosable because the very next successful run's Out-File had silently
# destroyed the only evidence of it. Combined with Write-ClaudeLog's append-not-overwrite below,
# this also survives multiple runs on the SAME day (an on-demand /debrief plus the 08:30 run)
# without either clobbering the other's diagnostics. Clear-OldClaudeLogs bounds growth.
$claudeLog= Join-Path $vault "debriefs\.jarvis-claude-$today.log"

function Toast($msg) {
  try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText01)
    $null = $t.GetElementsByTagName('text')[0].AppendChild($t.CreateTextNode($msg))
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Jarvis').Show([Windows.UI.Notifications.ToastNotification]::new($t))
  } catch { }  # toast is best-effort
}

function Get-DebriefChannel {
  # where to deliver the finished debrief: telegram | email | both. Reads CONFIG.md; defaults to email
  # (back-compat) if the key is absent or unreadable.
  #
  # Fix 3: this used to match '(telegram|email|both)\b' and return the CAPTURED WORD, so a hand-edited
  # 'debrief_delivery: telegram-only' matched 'telegram' (a hyphen is a non-word character, so \b is
  # satisfied) and was silently accepted as a valid setting. Same defect as Test-ChatEnabled in
  # telegram-chat.ps1, which the two were copied from each other. Read the WHOLE value and accept it
  # only if it is exactly one of the three; anything else falls back to the documented default. The
  # behaviour for the three VALID values is unchanged.
  #
  # ...except it was NOT unchanged, and this was a live regression: the real config line reads
  # 'debrief_delivery: telegram       # where the 08:30 debrief lands: ...', so reading the whole line
  # captured the trailing comment too, matched none of the three, and silently fell back to 'email' -
  # rerouting the morning briefing off Alex's phone without a word. A trailing '# comment' is this
  # file's own convention on every key. Strip it first, THEN require an exact match: 'telegram-only'
  # and friends contain no '#' and are still rejected, so the hardening survives intact.
  try {
    $m = [regex]::Match((Get-Content (Join-Path $vault 'CONFIG.md') -Raw),
      '(?m)^\s*-?\s*debrief_delivery:[ \t]*([^\r\n]*)')
    if ($m.Success) {
      $v = ($m.Groups[1].Value -replace '#.*$', '').Trim().ToLower()
      if ($v -eq 'telegram' -or $v -eq 'email' -or $v -eq 'both') { return $v }
    }
  } catch { }
  return 'email'
}

function Invoke-ClaudeGeneration {
  # F5: bounds the Claude call itself so an overrun becomes a catchable, loggable failure - caught
  # by the try/catch below, logged, and toasted - instead of an untimed hang that only Windows's
  # hard ExecutionTimeLimit kill (see scripts/register-task.ps1) eventually stops, bypassing every
  # try/catch/finally in this script when it fires. Mirrors the Start-Job + Wait-Job -Timeout
  # pattern already proven in skill/bin/telegram-chat.ps1 (~line 793) for its own collector calls.
  #
  # Default timeout 25 min: comfortably inside the 30-min task ExecutionTimeLimit (F4), leaving
  # headroom for the freshness check, lateness stamp and delivery that still have to run afterward.
  #
  # Pre-merge review of 6e2a148 found three real gaps in this function, all fixed together below:
  #
  # (a) Working directory: Start-Job in PS 5.1 has no -WorkingDirectory and does not inherit the
  # caller's location - measured (both here and independently in telegram-chat.ps1 ~line 617) that
  # an unpinned job lands in C:\Users\<user>\Documents regardless of where this script was actually
  # invoked from (Task Scheduler, or a manual terminal). -WorkingDirectory/-ErrorAction Stop mirror
  # telegram-chat.ps1's own fix for the identical gotcha.
  #
  # (b) Output capture on failure: the timeout and did-not-complete-cleanly branches used to
  # throw/return without ever calling Receive-Job, discarding whatever partial output the job had
  # already produced - meaning the exact failure category this function exists to catch (an
  # overrun) left ZERO trace in debriefs\.jarvis-claude-<date>.log, contradicting the whole point of
  # capturing Claude's output ("so a bad run is diagnosable, not discarded"). Both failure branches
  # now best-effort Receive-Job and Write-ClaudeLog the partial output before throwing, when the
  # caller supplies -LogPath/-RunStamp.
  #
  # (c) Orphaned child process on timeout: Stop-Job only stops the job's OWN PowerShell host.
  # claude.exe (and its own child helper processes) is a DESCENDANT of that host, not the host
  # itself, and survives Stop-Job as an orphan holding the OAuth token in its inherited environment -
  # the identical gotcha telegram-chat.ps1 documents and fixes (~line 793) for the same Start-Job +
  # claude pattern, via a PID file written from inside the job plus `taskkill /PID ... /T /F`. The
  # comment previously here asserted the opposite ("no long-lived OAuth-bearing child process is
  # left behind here worth hunting down by PID") with no supporting evidence; that assertion was
  # wrong and is replaced by the same tree-kill this codebase already proved necessary next door.
  #
  # -JobScript is overridable purely for testability (a real 25-minute wait has no place in a test
  # suite): tests substitute a fast scriptblock and a short -TimeoutSec to exercise the actual
  # timeout-detection logic without waiting for it. Production call sites never pass it and get the
  # real Claude invocation. A substituted -JobScript that ignores the extra $dir/$pidFile arguments
  # (as the existing fast-path tests do) is unaffected - PowerShell silently drops unbound
  # positional arguments rather than erroring.
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [int]$TimeoutSec = 1500,
    [string]$WorkingDirectory = $skillDir,
    [string]$LogPath,
    [string]$RunStamp,
    [scriptblock]$JobScript = {
      param($p, $dir, $pidFile)
      # FIRST statement: pin the working directory (see comment (a) above).
      if ($dir) { Set-Location -LiteralPath $dir -ErrorAction Stop }
      # Record the job host's own PID before the long-running call, so a timeout can taskkill the
      # whole process tree (see comment (c) above). Best-effort: a failure to record it must not
      # block the actual generation call.
      if ($pidFile) { try { Set-Content -LiteralPath $pidFile -Value $PID -ErrorAction Stop } catch { } }
      & claude -p $p --permission-mode acceptEdits --allowedTools "Read Write Edit Bash Glob Grep" --output-format json 2>&1
    }
  )
  # Sentinel is deliberately non-numeric (matches telegram-chat.ps1's own convention): it cannot
  # satisfy the '^\s*(\d+)\s*$' match below, so a half-set-up job can never be mistaken for a real
  # PID and fed to taskkill.
  $pidFile = $null
  try {
    $pidFile = Join-Path $env:TEMP ('jarvis-debrief-pid-' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $pidFile -Value 'pending' -ErrorAction Stop
  } catch { $pidFile = $null }
  try {
    $job = Start-Job -ScriptBlock $JobScript -ArgumentList $Prompt, $WorkingDirectory, $pidFile
    $done = Wait-Job $job -Timeout $TimeoutSec
    if (-not $done) {
      # (b) capture whatever partial output exists before anything is torn down.
      $partial = $null
      try { $partial = Receive-Job $job -ErrorAction SilentlyContinue } catch { }
      # (c) tree-kill the orphaned claude.exe (and its own children) by the job host's recorded PID.
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
          Write-ClaudeLog -LogPath $LogPath -RunStamp $RunStamp `
            -Output (@("[TIMED OUT after $([math]::Round($TimeoutSec / 60))m - partial output, if any, below]") + @($partial))
        } catch { }
      }
      throw "Claude generation exceeded $([math]::Round($TimeoutSec / 60))m timeout"
    }
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    $jobState = $job.State
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($jobState -ne 'Completed') {
      if ($LogPath -and $RunStamp) {
        try {
          Write-ClaudeLog -LogPath $LogPath -RunStamp $RunStamp `
            -Output (@("[job did not complete cleanly: state=$jobState - partial output, if any, below]") + @($result))
        } catch { }
      }
      throw "Claude generation job did not complete cleanly (state: $jobState)"
    }
    return $result
  } finally {
    if ($pidFile) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
  }
}

function Write-ClaudeLog {
  # F6: append-with-separator, never overwrite (Out-File did before). A per-date filename already
  # separates day from day; this is what also keeps a SECOND run on the same day (on-demand
  # /debrief after the scheduled one, or a retry) from clobbering the first run's diagnostics.
  param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][string]$RunStamp, $Output)
  Add-Content -Encoding UTF8 -Path $LogPath -Value "===== run $RunStamp ====="
  $Output | Add-Content -Encoding UTF8 -Path $LogPath
}

function Clear-OldClaudeLogs {
  # F6: retention so the per-date claude logs don't grow unbounded forever. Best-effort: a failure
  # to clean up old logs is not a run failure.
  param([Parameter(Mandatory)][string]$VaultPath, [int]$RetentionDays = 14)
  try {
    $dir = Join-Path $VaultPath 'debriefs'
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem -Path $dir -Filter '.jarvis-claude-*.log' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch { }
}

function Set-DebriefHeartbeat {
  # F3: positive delivery heartbeat. Called ONLY from the success path, ONLY after a channel send
  # has already returned without throwing (see the call site below) - never speculatively, never on
  # a path where the send threw. A pulled-out function (rather than inline code) so this behaviour is
  # directly unit-testable without running a real debrief end to end.
  # Best-effort by design: a failure writing the heartbeat must never turn a genuinely successful
  # send into a "run FAILED" log line, so callers should wrap this in their own try/catch (the main
  # script does). This function itself does not swallow errors - the CALLER decides that, so a test
  # can observe a real write failure if it wants to.
  param([string]$Date, [string]$Channel, [string]$HeartbeatFile)
  New-Item -ItemType Directory -Force -Path (Split-Path $HeartbeatFile) | Out-Null
  @{ date = $Date; channel = $Channel; sentAt = (Get-Date).ToString('s') } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $HeartbeatFile
}

function Test-AlreadySentToday {
  # F8b: catch-up idempotency guard for the second (09:15) trigger added in scripts/register-task.ps1.
  # Without this, a hibernated night in which the 08:30 trigger DID fire and succeed would still let
  # the 09:15 catch-up trigger run the full pipeline again - regenerating the note and, worse,
  # RE-SENDING it (a second Telegram/email delivery of the same morning's debrief). The lock file
  # below only guards against runs that overlap IN TIME (stale after 15 min); it says nothing about
  # two runs on the same day that each complete cleanly the better part of an hour apart, which is
  # exactly the 08:30-then-09:15 catch-up shape. The heartbeat file (F3) already records the date of
  # the last CONFIRMED send, so reuse it here as the source of truth: if today's debrief already sent
  # successfully, this run is a safe no-op. -OnDemand runs (explicit /debrief, tray "Debrief now") are
  # NEVER treated as duplicates - Alex asking again is not the same as the scheduler firing twice.
  param([Parameter(Mandatory)][string]$Date, [Parameter(Mandatory)][string]$HeartbeatFile, [switch]$OnDemand)
  if ($OnDemand) { return $false }
  if (-not (Test-Path $HeartbeatFile)) { return $false }
  try {
    $hb = Get-Content $HeartbeatFile -Raw | ConvertFrom-Json
    return [bool]($hb -and $hb.date -eq $Date)
  } catch { return $false }
}

function Send-DebriefChannels {
  # Pre-merge review of 6e2a148: in 'both'-channel mode, the two sends used to run back-to-back with
  # NO per-channel try/catch, both inside the ONE outer try block. If the FIRST channel (say,
  # Telegram) succeeded and the SECOND (email) then threw (expired Gmail app password, no network),
  # the exception propagated straight past the run-ok log line AND the F3 heartbeat write for the
  # ENTIRE run - so a day where Telegram genuinely delivered still logged "run FAILED" with no
  # heartbeat at all. F8b's 09:15 catch-up trigger (whose only guard is "did ANY confirmed send
  # happen today", via the heartbeat) would then see nothing and re-run the WHOLE pipeline -
  # resending the identical debrief over Telegram a second time within the hour, even though
  # Telegram was never the broken leg. That is exactly the duplicate-delivery bug class F8b's own
  # commit message claims the heartbeat guard "can never" allow.
  #
  # Fix: each requested channel is attempted independently and its own failure never prevents the
  # OTHER channel from being attempted, logged, or heartbeated. Returns which channel(s) genuinely
  # sent and which failed; the caller (below) logs/heartbeats the successes and then re-throws a
  # single aggregate error for any failures, so a partial failure is still loud (amber, diagnosable)
  # without re-sending the channel that already worked.
  #
  # Pulled out as its own function (rather than inline in the main try block) purely so this exact
  # interaction is directly unit-testable - see tests/debrief-partial-channel-failure.Tests.ps1 -
  # without a real Telegram token or SMTP credential. Assumes Send-DebriefTelegram / Send-Debrief
  # are already defined in scope (dot-sourced by the caller before this is invoked).
  param(
    [Parameter(Mandatory)][string]$Channel,
    [Parameter(Mandatory)][string]$NotePath,
    [string]$ToAddress,
    [datetime]$RunStart = [datetime]::MinValue,
    [datetime]$BootTime = [datetime]::MinValue,
    [switch]$OnDemand
  )
  $sent = @()
  $errors = @()
  if ($Channel -eq 'telegram' -or $Channel -eq 'both') {
    try { Send-DebriefTelegram -NotePath $NotePath; $sent += 'telegram' }
    catch { $errors += "telegram: $($_.Exception.Message)" }
  }
  if ($Channel -eq 'email' -or $Channel -eq 'both') {
    try {
      Send-Debrief -NotePath $NotePath -ToAddress $ToAddress -RunStart $RunStart -BootTime $BootTime -OnDemand:$OnDemand
      $sent += 'email'
    } catch { $errors += "email: $($_.Exception.Message)" }
  }
  [pscustomobject]@{ Sent = $sent; Errors = $errors }
}

function Send-FailureAlert {
  # 2026-08-20: the 08-09..08-15 six-day 403 outage proved the fail-closed design (F1/F6/etc.) works
  # exactly as built - every failed run correctly logged "run FAILED" and left a "Debrief FAILED" note
  # stub instead of faking a debrief - but NOTHING pushed that off-machine, so six days of failures
  # reached Alex's phone as silence, not as a message. This closes that gap. Deliberately dumb by
  # design (DECISIONS.md 2026-08-20): a FIXED, code-composed string, never LLM output, so it is immune
  # to the exact failure class (a headless-auth 403) that caused the incident, and can never become an
  # agent write to the health log (SKILL.md Safety rule 8 - the agent never touches this file; neither
  # does this function's caller ask an agent to). No retry/backoff and no API-key fallback - both
  # explicitly rejected in DECISIONS.md: a policy-class error is deterministic, and switching auth
  # modes is Alex's deliberate call, not an automatic fallback.
  #
  # Threshold 2: a single failure is the 09:15 catch-up trigger's job to quietly retry; two consecutive
  # failures is a pattern worth waking a human for. Same-day dedupe on an "alert sent" line means the
  # 08:30 and 09:15 triggers hitting this on the same bad morning still only alert once.
  param(
    [Parameter(Mandatory)][string]$RunLog,
    [Parameter(Mandatory)][string]$ErrorMessage,
    [string]$ToAddress
  )
  if (-not (Test-Path -LiteralPath $RunLog)) { return }
  $lines = @(Get-Content -LiteralPath $RunLog -ErrorAction SilentlyContinue)

  # Walk the tail backward counting consecutive trailing "run FAILED" lines, stopping at the first
  # "run ok" / "run skipped" line. Mirrors the line-format convention app/lib/livestate.js's
  # parseLogTail already established for THIS SAME FILE ("<ts> run <start|ok|FAILED>...") rather than
  # inventing a second parser style for it. Any other line (a "run start", a "claude-version" line, or
  # this function's own "alert sent"/"alert FAILED" lines below, which deliberately do not start with
  # "run ") does not break the streak and does not count toward it either.
  $count = 0
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i]
    if ($l -match '^\S+\s+run FAILED\b') { $count++; continue }
    if ($l -match '^\S+\s+run (ok|skipped)\b') { break }
  }
  if ($count -lt 2) { return }

  $today = Get-Date -Format 'yyyy-MM-dd'
  $alreadyAlerted = $lines | Where-Object { $_.StartsWith($today) -and $_ -match '\balert sent\b' }
  if ($alreadyAlerted) { return }

  $errSnippet = $ErrorMessage
  if ($errSnippet.Length -gt 300) { $errSnippet = $errSnippet.Substring(0, 300) }
  $msg = "JARVIS ALERT: morning debrief has FAILED $count consecutive runs. Last error: $errSnippet. " +
    "No debrief was delivered. Check debriefs/.jarvis-runs.log on the laptop."

  $sentAny = $false
  $failReasons = @()

  # Telegram: Send-Telegram is the raw-text send that Send-DebriefTelegram itself wraps - called
  # directly here (rather than through Send-DebriefTelegram) because this alert has no note FILE to
  # read, only a fixed string. Bot token/chat id stay locked in code exactly as for the normal debrief
  # send (Get-TelegramCred + the self-only guard inside Send-Telegram).
  try { Send-Telegram -Text $msg | Out-Null; $sentAny = $true }
  catch { $failReasons += "telegram: $($_.Exception.Message)" }

  # Email: Send-Debrief only knows how to mail a NOTE FILE (it reads -NotePath to build the body), so
  # the fixed alert string is written to a throwaway temp note and handed through it unchanged. This
  # still goes through Send-Debrief's own self-only recipient lock (Safety rule 2), untouched.
  $tmpNote = $null
  try {
    $tmpNote = Join-Path $env:TEMP ('jarvis-alert-' + [guid]::NewGuid().ToString('N') + '.md')
    Set-Content -LiteralPath $tmpNote -Value $msg -Encoding UTF8
    Send-Debrief -NotePath $tmpNote -ToAddress $ToAddress
    $sentAny = $true
  } catch { $failReasons += "email: $($_.Exception.Message)" }
  finally { if ($tmpNote) { Remove-Item -LiteralPath $tmpNote -Force -ErrorAction SilentlyContinue } }

  # These lines must NOT begin with "run " - both this function's own consecutive-FAILED walk above
  # and app/lib/livestate.js's parseLogTail (RUN_LINE_RE) key off that exact prefix, and an alert line
  # that matched it would corrupt either parser's view of run status.
  if ($sentAny) {
    "$([datetime]::Now.ToString('s')) alert sent ($count consecutive failures)" | Add-Content $RunLog
  } else {
    "$([datetime]::Now.ToString('s')) alert FAILED: $($failReasons -join '; ')" | Add-Content $RunLog
  }
}

$lockFile      = Join-Path $HOME '.jarvis\debrief.lock'
$heartbeatFile = Join-Path $HOME '.jarvis\debrief-heartbeat.json'
$lockTaken = $false
try {
  # F8b: cheapest check first, before even touching the lock file - if today's debrief already sent
  # successfully (per the F3 heartbeat), this is the 09:15 catch-up trigger finding nothing to do.
  if (Test-AlreadySentToday -Date $today -HeartbeatFile $heartbeatFile -OnDemand:$OnDemand) {
    "$([datetime]::Now.ToString('s')) run skipped: today's debrief already sent (see debrief-heartbeat.json) - safe no-op for catch-up trigger" | Add-Content $runLog
    exit 0
  }

  # SINGLE-FLIGHT. A debrief takes ~3 minutes and writes one shared note. Two overlapping runs (the
  # 08:30 catch-up racing an on-demand /debrief, or a backlog of /debrief commands) each generate AND
  # each deliver, so Alex gets the same briefing two or three times minutes apart. Witnessed 2026-07-16.
  # A lock whose owner is dead, or older than the staleness window below, is treated as stale and
  # taken over.
  #
  # Staleness window: 30 min, matching ExecutionTimeLimit (scripts/register-task.ps1) and
  # RUN_LIMIT_MS (app/lib/livestate.js) - see tests/scheduler-settings.Tests.ps1, which now also
  # pins this value. Pre-merge review of 6e2a148 found this was still hardcoded at the OLD 15-min
  # figure even though that same commit raised the other two to 30/added a 25-min internal Claude
  # timeout specifically because generation now routinely takes longer than 15 minutes. Left at 15,
  # a legitimately still-running (and healthy) generation between minute 15 and 30 would fail the
  # "$alive -and $isFresh" check below on isFresh alone, letting an on-demand /debrief (which always
  # reaches this code - Test-AlreadySentToday exempts -OnDemand runs above) steal the lock mid-run
  # and start a second concurrent generation + delivery: the exact "five briefings" duplicate-send
  # bug class this lock exists to prevent.
  if (Test-Path $lockFile) {
    $held = $null
    try { $held = Get-Content $lockFile -Raw | ConvertFrom-Json } catch { $held = $null }
    $alive = $false
    if ($held -and $held.pid) { $alive = [bool](Get-Process -Id ([int]$held.pid) -ErrorAction SilentlyContinue) }
    $isFresh = $false
    if ($held -and $held.start) { try { $isFresh = ([datetime]$held.start -gt (Get-Date).AddMinutes(-30)) } catch { $isFresh = $false } }
    if ($alive -and $isFresh) {
      "$([datetime]::Now.ToString('s')) run skipped: a debrief is already running (pid $($held.pid))" | Add-Content $runLog
      exit 0
    }
  }
  @{ pid = $PID; start = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -Encoding ASCII $lockFile
  $lockTaken = $true

  $runStart = Get-Date
  "$($runStart.ToString('s')) run start" | Add-Content $runLog
  # Version drift guard: the whole system rides on Claude Code's headless behavior, which can change
  # under us (the --verbose requirement did exactly that once). Log the version as its OWN line so a
  # stranger debugging a broken morning can see which Claude Code produced it. parseLogTail ignores
  # non-"run" lines, so this is invisible to the health parser.
  try { "$($runStart.ToString('s')) claude-version $((& claude --version 2>&1 | Select-Object -First 1))" | Add-Content $runLog } catch { }

  # Headless auth: feed Claude the long-lived subscription token created by 'claude setup-token'.
  # Stored DPAPI-encrypted at ~/.jarvis/claude-token.xml (never in the repo/vault).
  $tokFile = Join-Path $HOME '.jarvis\claude-token.xml'
  if (Test-Path $tokFile) {
    $sec = Import-Clixml $tokFile
    $env:CLAUDE_CODE_OAUTH_TOKEN = (New-Object System.Management.Automation.PSCredential('t', $sec)).GetNetworkCredential().Password
  } else {
    throw "no Claude token at $tokFile - run 'claude setup-token' then store it (see setup)"
  }

  # Self-contained prompt: do NOT rely on the "/jarvis" slash-command triggering in headless -p mode.
  # Point Claude straight at the skill files and have it execute the procedure, writing the note.
  $prompt = "You are running headlessly as Jarvis (no human present; do not ask questions). " +
    "Read your instructions at $skillDir\SKILL.md and $skillDir\references\debrief.md, then execute the " +
    "debrief procedure now for $today and WRITE the finished debrief to $note (overwrite if it already exists). " +
    "Obey the safety rules in SKILL.md. Finish by confirming the file was written."

  # capture Claude's output so a bad run is diagnosable (not discarded). F5: bounded to 25 min so an
  # overrun throws here (caught below) instead of hanging until Windows's hard 30-min task kill.
  # -LogPath/-RunStamp let Invoke-ClaudeGeneration itself best-effort log whatever PARTIAL output
  # exists if it has to throw (timeout / did-not-complete-cleanly) - see the fix comment on that
  # function: this used to be discarded entirely for exactly the failure category most in need of it.
  $out = Invoke-ClaudeGeneration -Prompt $prompt -TimeoutSec 1500 -LogPath $claudeLog -RunStamp $runStart.ToString('s')
  Write-ClaudeLog -LogPath $claudeLog -RunStamp $runStart.ToString('s') -Output $out
  Clear-OldClaudeLogs -VaultPath $vault

  # HARD success check: the note must have been (re)written DURING this run, not merely exist.
  $freshEnough = (Test-Path $note) -and ((Get-Item $note).LastWriteTime -ge $runStart.AddSeconds(-2))
  if (-not $freshEnough) {
    throw "headless generation produced no fresh note (see debriefs\.jarvis-claude-$today.log) - not sending a stale debrief"
  }

  # Send IN-PROCESS (dot-source) so a send failure is a terminating error caught below. An external
  # `& powershell -NoProfile -File $sender` does NOT propagate its non-zero exit into this try, so a
  # failed delivery (SMTP down, expired app password, no network) would fall through and be logged as
  # "run ok" with a success toast - a silent miss of the actual deliverable. (Safety: the sender's
  # own Safety-rule-2 guard locks the recipient to the owner.)
  . $sender -DotSourceOnly    # Get-LatenessNote, Send-Debrief, OwnerEmail (dot-source only; no send yet)
  # Honesty stamp (design 8): a late catch-up names itself and its cause in the note, the delivery, and
  # the log - it must never masquerade as an on-time morning. Boot time after 08:30 proves the machine
  # was powered off (shutdown defeats the wake timer - witnessed 2026-07-14).
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  # -OnDemand runs are not the 08:30 run, so they are never judged late (Get-LatenessNote returns null
  # and every downstream stamp - note footer, toast, log tag, email subject - degrades to "on time").
  $lateNote = Get-LatenessNote -RunStart $runStart -BootTime $boot -OnDemand:$OnDemand
  if ($lateNote) { Add-Content -Encoding UTF8 -Path $note -Value "`n> $lateNote" }

  # Deliver per channel via Send-DebriefChannels (pre-merge review of 6e2a148 - see its own comment
  # for the exact duplicate-delivery bug this replaced). Self-only is enforced inside both senders
  # (email recipient lock; Telegram chat-id lock).
  $channel = if ($Channel) { $Channel } else { Get-DebriefChannel }
  if ($channel -eq 'telegram' -or $channel -eq 'both') {
    . (Join-Path $PSScriptRoot 'telegram-bot.ps1') -DotSourceOnly
  }
  $delivery = Send-DebriefChannels -Channel $channel -NotePath $note -ToAddress $OwnerEmail `
    -RunStart $runStart -BootTime $boot -OnDemand:$OnDemand

  $lateTag = ''; if ($lateNote) { $lateTag = ' [late catch-up]' }
  if ($delivery.Sent.Count -gt 0) {
    # Logged (and heartbeated) for whichever channel(s) genuinely succeeded, regardless of whether
    # another requested channel is about to be reported as failed below - see Send-DebriefChannels.
    "$([datetime]::Now.ToString('s')) run ok (note written $((Get-Item $note).LastWriteTime.ToString('t')), via $($delivery.Sent -join '+'))$lateTag" | Add-Content $runLog
    # F3: positive delivery heartbeat, written ONLY after at least one channel send has returned
    # successfully (never speculatively). Distinct from the run-status log: this is a single small
    # JSON file the health surface (and F8b's 09:15 catch-up guard) can check for "did today's send
    # actually happen", independent of log-tail parsing. Best-effort: a failure here must never turn
    # a real success into a false "run FAILED".
    try {
      Set-DebriefHeartbeat -Date $today -Channel ($delivery.Sent -join '+') -HeartbeatFile $heartbeatFile
    } catch { }
  }
  if ($delivery.Errors.Count -gt 0) {
    # At least one requested channel failed. Throw so the outer catch below logs a loud FAILED
    # (never a silent miss) - any channel(s) that DID succeed are already logged/heartbeated above
    # and will therefore be treated as already-sent by F8b's 09:15 catch-up, not resent.
    throw "delivery failed on: $($delivery.Errors -join '; ')"
  }
  if ($lateNote) { Toast "Debrief ready (late catch-up), Sir." } else { Toast "Debrief ready, Sir." }
} catch {
  $err = $_.Exception.Message
  "$([datetime]::Now.ToString('s')) run FAILED: $err" | Add-Content $runLog
  # Consecutive-failure push alert (2026-08-20). Own try/catch so a broken alerter can NEVER disturb
  # the FAILED-logging path above or the stub-note/toast below - the whole point of this addition is
  # to make failures louder, not to introduce a new way for a run to fail worse. Both senders are
  # (re-)dot-sourced here, defensively, because a failure this early (e.g. no Claude token) can occur
  # BEFORE the main try block's own dot-sourcing of $sender/telegram-bot.ps1 ever runs.
  try {
    . $sender -DotSourceOnly
    . (Join-Path $PSScriptRoot 'telegram-bot.ps1') -DotSourceOnly
    Send-FailureAlert -RunLog $runLog -ErrorMessage $err -ToAddress $OwnerEmail
  } catch { }
  # Leave a VISIBLE stub so a failed morning can't masquerade as a quiet day. Only if generation
  # produced no note; on a send-only failure the real (unsent) note is kept and the log/toast alarm.
  if (-not (Test-Path $note)) {
    "# Debrief FAILED - $([datetime]::Now.ToString('yyyy-MM-dd HH:mm'))`n`n$err`n`nSee .jarvis-runs.log and debriefs\.jarvis-claude-$today.log." |
      Set-Content -Encoding UTF8 $note
  }
  Toast "Jarvis debrief failed - check .jarvis-runs.log"
} finally {
  # release ONLY our own lock - a run that skipped because someone else holds it must not delete theirs
  if ($lockTaken) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
}
