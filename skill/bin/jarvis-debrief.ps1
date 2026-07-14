# skill/bin/jarvis-debrief.ps1 - run by Task Scheduler at 08:30 (or manually from a NORMAL terminal).
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

try {
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
  # "run ok" with a success toast — a silent miss of the actual deliverable. (Safety: the sender's
  # own Safety-rule-2 guard locks the recipient to the owner.)
  . $sender -DotSourceOnly
  # Honesty stamp (design 8): a late catch-up names itself and its cause in the note, the email
  # subject, and the log - it must never masquerade as an on-time morning. Boot time after 08:30
  # proves the machine was powered off (shutdown defeats the wake timer - witnessed 2026-07-14).
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  $lateNote = Get-LatenessNote -RunStart $runStart -BootTime $boot
  if ($lateNote) { Add-Content -Encoding UTF8 -Path $note -Value "`n> $lateNote" }
  Send-Debrief -NotePath $note -ToAddress $OwnerEmail -RunStart $runStart -BootTime $boot
  if ($lateNote) { Toast "Debrief ready (late catch-up), Sir." } else { Toast "Debrief ready, Sir." }
  $lateTag = ''; if ($lateNote) { $lateTag = ' [late catch-up]' }
  "$([datetime]::Now.ToString('s')) run ok (note written $((Get-Item $note).LastWriteTime.ToString('t')))$lateTag" | Add-Content $log
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
}
