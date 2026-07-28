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
  # -JobScript is overridable purely for testability (a real 25-minute wait has no place in a test
  # suite): tests substitute a fast scriptblock and a short -TimeoutSec to exercise the actual
  # timeout-detection logic without waiting for it. Production call sites never pass it and get the
  # real Claude invocation.
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [int]$TimeoutSec = 1500,
    [scriptblock]$JobScript = {
      param($p)
      & claude -p $p --permission-mode acceptEdits --allowedTools "Read Write Edit Bash Glob Grep" --output-format json 2>&1
    }
  )
  $job = Start-Job -ScriptBlock $JobScript -ArgumentList $Prompt
  $done = Wait-Job $job -Timeout $TimeoutSec
  if (-not $done) {
    # Stop-Job only stops the job's own host; it does not need a tree-kill like telegram-chat.ps1's
    # (no long-lived OAuth-bearing child process is left behind here worth hunting down by PID) -
    # the important thing is that THIS script stops waiting and throws so the caller's catch block
    # runs. Best-effort cleanup; a failure to reap the job must not swallow the timeout exception.
    try { Stop-Job $job -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job $job -Force -ErrorAction SilentlyContinue } catch { }
    throw "Claude generation exceeded $([math]::Round($TimeoutSec / 60))m timeout"
  }
  $result = Receive-Job $job -ErrorAction SilentlyContinue
  $jobState = $job.State
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  if ($jobState -ne 'Completed') {
    throw "Claude generation job did not complete cleanly (state: $jobState)"
  }
  return $result
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
  # A lock whose owner is dead, or older than 15 min, is treated as stale and taken over.
  if (Test-Path $lockFile) {
    $held = $null
    try { $held = Get-Content $lockFile -Raw | ConvertFrom-Json } catch { $held = $null }
    $alive = $false
    if ($held -and $held.pid) { $alive = [bool](Get-Process -Id ([int]$held.pid) -ErrorAction SilentlyContinue) }
    $isFresh = $false
    if ($held -and $held.start) { try { $isFresh = ([datetime]$held.start -gt (Get-Date).AddMinutes(-15)) } catch { $isFresh = $false } }
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
  $out = Invoke-ClaudeGeneration -Prompt $prompt -TimeoutSec 1500
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

  # Deliver per channel. Each delivery throws on failure so it is caught below (loud FAILED, never a
  # silent miss). Self-only is enforced inside both senders (email recipient lock; Telegram chat-id lock).
  $channel = if ($Channel) { $Channel } else { Get-DebriefChannel }
  if ($channel -eq 'telegram' -or $channel -eq 'both') {
    . (Join-Path $PSScriptRoot 'telegram-bot.ps1') -DotSourceOnly
    Send-DebriefTelegram -NotePath $note
  }
  if ($channel -eq 'email' -or $channel -eq 'both') {
    Send-Debrief -NotePath $note -ToAddress $OwnerEmail -RunStart $runStart -BootTime $boot -OnDemand:$OnDemand
  }
  if ($lateNote) { Toast "Debrief ready (late catch-up), Sir." } else { Toast "Debrief ready, Sir." }
  $lateTag = ''; if ($lateNote) { $lateTag = ' [late catch-up]' }
  "$([datetime]::Now.ToString('s')) run ok (note written $((Get-Item $note).LastWriteTime.ToString('t')), via $channel)$lateTag" | Add-Content $runLog

  # F3: positive delivery heartbeat, written ONLY after a channel send has returned successfully
  # (never speculatively, never on a path where the send threw). Distinct from the run-status log:
  # this is a single small JSON file the health surface can check for "did today's send actually
  # happen", independent of log-tail parsing. Best-effort: a failure here must never turn a real
  # success into a false "run FAILED".
  try {
    Set-DebriefHeartbeat -Date $today -Channel $channel -HeartbeatFile $heartbeatFile
  } catch { }
} catch {
  $err = $_.Exception.Message
  "$([datetime]::Now.ToString('s')) run FAILED: $err" | Add-Content $runLog
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
