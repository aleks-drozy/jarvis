# tests/claude-log-retention.Tests.ps1 - F6: the claude diagnostic log used to be a single
# ".jarvis-claude.log" overwritten every run via Out-File, which once destroyed the only evidence
# of a prior day's failure. jarvis-debrief.ps1 now (a) names the log per-date and (b) appends with a
# per-run separator via Write-ClaudeLog, so a SECOND run on the same day (an on-demand /debrief
# after the scheduled one) cannot clobber the first run's diagnostics either. Clear-OldClaudeLogs
# bounds unbounded growth with a retention window.
#
# Extraction pattern matches tests/debrief-heartbeat.Tests.ps1: jarvis-debrief.ps1 runs a full
# debrief the moment it is dot-sourced, so the functions under test are lifted out by source
# extraction and defined in an isolated scope.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$debriefSrc = Get-Content "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw

foreach ($fn in @('Write-ClaudeLog','Clear-OldClaudeLogs')) {
  $m = [regex]::Match($debriefSrc, "(?ms)^function $fn \{.*?\n\}")
  Assert $m.Success "could not extract $fn from jarvis-debrief.ps1"
  . ([scriptblock]::Create($m.Value))
}

# 0) The log path itself must be per-date, not the old single shared filename - a static guard so
# this cannot silently regress back to the old overwrite-every-run shape.
Assert ($debriefSrc -match '\$claudeLog\s*=\s*Join-Path \$vault "debriefs\\\.jarvis-claude-\$today\.log"') `
  "jarvis-debrief.ps1 must build a per-date claude log path (debriefs\.jarvis-claude-<date>.log)"
Assert (-not ($debriefSrc -match 'Out-File[^\n]*\$claudeLog')) `
  "jarvis-debrief.ps1 must no longer Out-File (overwrite) the claude log"

$dir = Join-Path $env:TEMP ('jarvis-claude-log-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'debriefs') | Out-Null
try {
  $logPath = Join-Path $dir 'debriefs\.jarvis-claude-2026-07-28.log'

  # 1) Two runs on the SAME day (same file) must NOT destroy each other's content.
  Write-ClaudeLog -LogPath $logPath -RunStamp '2026-07-28T08:30:00' -Output 'first run output, run A'
  $afterFirst = Get-Content $logPath -Raw
  Assert ($afterFirst -match 'first run output, run A') "first run's content must be present after the first write"

  Write-ClaudeLog -LogPath $logPath -RunStamp '2026-07-28T10:40:00' -Output 'second run output, run B'
  $afterSecond = Get-Content $logPath -Raw
  Assert ($afterSecond -match 'first run output, run A') "a SECOND same-day run must not destroy the first run's content"
  Assert ($afterSecond -match 'second run output, run B') "a SECOND same-day run's own content must also be present"
  Assert ($afterSecond -match '2026-07-28T08:30:00') "each run must be identifiable by its own run stamp"
  Assert ($afterSecond -match '2026-07-28T10:40:00') "each run must be identifiable by its own run stamp"

  # 2) Retention: an old per-date log file (older than the retention window) must be removed;
  # a recent one must survive.
  $oldLog   = Join-Path $dir 'debriefs\.jarvis-claude-2020-01-01.log'
  $recentLog= Join-Path $dir 'debriefs\.jarvis-claude-2026-07-27.log'
  Set-Content -Encoding UTF8 $oldLog 'ancient diagnostic'
  Set-Content -Encoding UTF8 $recentLog 'yesterday diagnostic'
  (Get-Item $oldLog).LastWriteTime = (Get-Date).AddDays(-30)
  (Get-Item $recentLog).LastWriteTime = (Get-Date).AddDays(-1)

  Clear-OldClaudeLogs -VaultPath $dir -RetentionDays 14

  Assert (-not (Test-Path $oldLog)) "a claude log older than the retention window must be cleaned up"
  Assert (Test-Path $recentLog) "a claude log within the retention window must survive cleanup"
  Assert (Test-Path $logPath) "the just-written current-day log must survive cleanup"

  Write-Host "claude-log-retention: ALL PASS"
} finally {
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
