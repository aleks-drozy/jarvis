# skill/bin/jarvis-debrief.ps1 — run by Task Scheduler at 08:30.
$ErrorActionPreference = 'Stop'
$vault  = 'C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis'
$today  = Get-Date -Format 'yyyy-MM-dd'
$note   = Join-Path $vault "debriefs\$today.md"
$sender = Join-Path $PSScriptRoot 'send-debrief.ps1'
$log    = Join-Path $vault "debriefs\.jarvis.log"

function Toast($msg) {
  try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText01)
    $null = $t.GetElementsByTagName('text')[0].AppendChild($t.CreateTextNode($msg))
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Jarvis').Show([Windows.UI.Notifications.ToastNotification]::new($t))
  } catch { }  # toast is best-effort
}

try {
  "$([datetime]::Now.ToString('s')) run start" | Add-Content $log
  # generate the debrief headlessly (R2 permission flags)
  & claude -p "/jarvis debrief" --permission-mode acceptEdits `
      --allowedTools "Read Write Edit Bash Glob Grep" --output-format json | Out-Null
  if (-not (Test-Path $note)) { throw "debrief note not produced" }
  & powershell -NoProfile -File $sender -NotePath $note
  Toast "Debrief ready, Sir."
  "$([datetime]::Now.ToString('s')) run ok" | Add-Content $log
} catch {
  $err = $_.Exception.Message
  "$([datetime]::Now.ToString('s')) run FAILED: $err" | Add-Content $log
  if (-not (Test-Path $note)) { "Debrief failed $([datetime]::Now.ToString('t')) - $err" | Set-Content $note }
  Toast "Jarvis debrief failed - check the log."
}
