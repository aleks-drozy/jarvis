# skill/bin/scheduler-status.ps1
# Read-only Task Scheduler state for the desktop app's Live tab. ALWAYS exits 0 with JSON so the
# app degrades to "unknown", never crashes. No writes, no side effects.
param([string]$TaskName = 'Jarvis Morning Debrief', [switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Get-SchedulerStatus {
  param([string]$TaskName)
  try {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $info = $t | Get-ScheduledTaskInfo
    $next = $null
    if ($info.NextRunTime) { $next = $info.NextRunTime.ToString('s') }
    return [pscustomobject]@{
      registered = $true
      enabled    = ($t.State -ne 'Disabled')
      state      = [string]$t.State
      nextRun    = $next
    }
  } catch {
    return [pscustomobject]@{ registered = $false; enabled = $false; state = 'unknown'; nextRun = $null }
  }
}

if ($DotSourceOnly) { return }
Get-SchedulerStatus -TaskName $TaskName | ConvertTo-Json -Compress
