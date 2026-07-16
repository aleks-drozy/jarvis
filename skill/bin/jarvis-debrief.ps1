# skill/bin/jarvis-debrief.ps1 - run by Task Scheduler at 08:30 (or manually from a NORMAL terminal).
# -Channel overrides where the finished note is delivered (telegram | email | both); default reads
# CONFIG.md 'debrief_delivery' (falling back to email). The Telegram /debrief command passes 'telegram'.
param([ValidateSet('telegram','email','both','')][string]$Channel = '')
$ErrorActionPreference = 'Stop'
$vault    = 'C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis'
$skillDir = Join-Path $HOME '.claude\skills\jarvis'
$today    = Get-Date -Format 'yyyy-MM-dd'
$note     = Join-Path $vault "debriefs\$today.md"
$sender   = Join-Path $PSScriptRoot 'send-debrief.ps1'
$log      = Join-Path $vault "debriefs\.jarvis.log"
$claudeLog= Join-Path $vault "debriefs\.jarvis-claude.log"

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
  try {
    $m = [regex]::Match((Get-Content (Join-Path $vault 'CONFIG.md') -Raw),
      '(?m)^\s*-?\s*debrief_delivery:\s*(telegram|email|both)\b')
    if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  } catch { }
  return 'email'
}

$lockFile  = Join-Path $HOME '.jarvis\debrief.lock'
$lockTaken = $false
try {
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
      "$([datetime]::Now.ToString('s')) run skipped: a debrief is already running (pid $($held.pid))" | Add-Content $log
      exit 0
    }
  }
  @{ pid = $PID; start = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -Encoding ASCII $lockFile
  $lockTaken = $true

  $runStart = Get-Date
  "$($runStart.ToString('s')) run start" | Add-Content $log

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

  # capture Claude's output so a bad run is diagnosable (not discarded)
  $out = & claude -p $prompt --permission-mode acceptEdits `
      --allowedTools "Read Write Edit Bash Glob Grep" --output-format json 2>&1
  $out | Out-File -Encoding UTF8 $claudeLog

  # HARD success check: the note must have been (re)written DURING this run, not merely exist.
  $freshEnough = (Test-Path $note) -and ((Get-Item $note).LastWriteTime -ge $runStart.AddSeconds(-2))
  if (-not $freshEnough) {
    throw "headless generation produced no fresh note (see .jarvis-claude.log) - not sending a stale debrief"
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
  $lateNote = Get-LatenessNote -RunStart $runStart -BootTime $boot
  if ($lateNote) { Add-Content -Encoding UTF8 -Path $note -Value "`n> $lateNote" }

  # Deliver per channel. Each delivery throws on failure so it is caught below (loud FAILED, never a
  # silent miss). Self-only is enforced inside both senders (email recipient lock; Telegram chat-id lock).
  $channel = if ($Channel) { $Channel } else { Get-DebriefChannel }
  if ($channel -eq 'telegram' -or $channel -eq 'both') {
    . (Join-Path $PSScriptRoot 'telegram-bot.ps1') -DotSourceOnly
    Send-DebriefTelegram -NotePath $note
  }
  if ($channel -eq 'email' -or $channel -eq 'both') {
    Send-Debrief -NotePath $note -ToAddress $OwnerEmail -RunStart $runStart -BootTime $boot
  }
  if ($lateNote) { Toast "Debrief ready (late catch-up), Sir." } else { Toast "Debrief ready, Sir." }
  $lateTag = ''; if ($lateNote) { $lateTag = ' [late catch-up]' }
  "$([datetime]::Now.ToString('s')) run ok (note written $((Get-Item $note).LastWriteTime.ToString('t')), via $channel)$lateTag" | Add-Content $log
} catch {
  $err = $_.Exception.Message
  "$([datetime]::Now.ToString('s')) run FAILED: $err" | Add-Content $log
  # Leave a VISIBLE stub so a failed morning can't masquerade as a quiet day. Only if generation
  # produced no note; on a send-only failure the real (unsent) note is kept and the log/toast alarm.
  if (-not (Test-Path $note)) {
    "# Debrief FAILED - $([datetime]::Now.ToString('yyyy-MM-dd HH:mm'))`n`n$err`n`nSee .jarvis.log and .jarvis-claude.log." |
      Set-Content -Encoding UTF8 $note
  }
  Toast "Jarvis debrief failed - check .jarvis.log"
} finally {
  # release ONLY our own lock - a run that skipped because someone else holds it must not delete theirs
  if ($lockTaken) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
}
