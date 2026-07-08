# skill/bin/jarvis-debrief.ps1 — run by Task Scheduler at 08:30 (or manually from a NORMAL terminal).
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
    throw "headless generation produced no fresh note (see .jarvis-claude.log) — not sending a stale debrief"
  }

  & powershell -NoProfile -File $sender -NotePath $note
  Toast "Debrief ready, Sir."
  "$([datetime]::Now.ToString('s')) run ok (note written $((Get-Item $note).LastWriteTime.ToString('t')))" | Add-Content $log
} catch {
  $err = $_.Exception.Message
  "$([datetime]::Now.ToString('s')) run FAILED: $err" | Add-Content $log
  Toast "Jarvis debrief failed - check .jarvis.log"
}
