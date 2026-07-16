# skill/bin/collect-activity.ps1
# Emits JSON of recent project activity for the Jarvis debrief (module 3).
# Usage:  powershell -File collect-activity.ps1 [-ProjectsDir <path>] -SinceHours 24
#         (default ProjectsDir comes from ~/.jarvis/config.json 'projects_root')
#         powershell -File collect-activity.ps1 -DotSourceOnly   (loads functions only, for tests)
param(
  [string]$ProjectsDir = '',
  [string]$TranscriptsDir = "$HOME/.claude/projects",
  [int]$SinceHours = 24,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'
if (-not $ProjectsDir) {
  . "$PSScriptRoot\get-jarvis-config.ps1"
  $ProjectsDir = (Get-JarvisConfig).projects_root
}

function Get-GitRepos {
  param([string]$Root, [int]$MaxDepth = 3)
  $script:found = @()
  function _walk($dir, $depth) {
    if ($depth -gt $MaxDepth) { return }
    foreach ($sub in Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue) {
      if ($sub.Name -eq 'node_modules') { continue }
      if ($sub.Name -eq '.git') { $script:found += (Split-Path $sub.FullName -Parent); continue }
      _walk $sub.FullName ($depth + 1)
    }
  }
  _walk $Root 0
  return ($script:found | Sort-Object -Unique)
}

function Get-RecentCommits {
  param([string]$RepoPath, [string]$Since)
  $fmt = '%H%x1f%cI%x1f%s'
  $out = git -C $RepoPath log --since="$Since" --pretty=format:$fmt 2>$null
  if (-not $out) { return @() }
  $us = [char]0x1f
  return @($out -split "`n" | Where-Object { $_ } | ForEach-Object {
    $p = $_ -split $us
    [pscustomobject]@{ Hash = $p[0].Substring(0,[Math]::Min(8,$p[0].Length)); Date = $p[1]; Subject = $p[2] }
  })
}

function Get-RecentTranscripts {
  param([string]$Dir, [int]$SinceHours = 24)
  if (-not (Test-Path $Dir)) { return @() }
  $cut = (Get-Date).AddHours(-$SinceHours)
  return @(Get-ChildItem -Path $Dir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $cut } |
    ForEach-Object { [pscustomobject]@{ Workspace = Split-Path $_.DirectoryName -Leaf; File = $_.Name; Modified = $_.LastWriteTime.ToString('s') } })
}

if ($DotSourceOnly) { return }

# ISO datetime (hour precision) so the git window matches the transcript window exactly
$since = (Get-Date).AddHours(-$SinceHours).ToString('s')
$repos = Get-GitRepos -Root $ProjectsDir -MaxDepth 3
$activity = foreach ($r in $repos) {
  $commits = Get-RecentCommits -RepoPath $r -Since $since
  # @() keeps Commits a JSON array for 0/1/many so consumers can rely on .Commits[]
  [pscustomobject]@{ Repo = (Split-Path $r -Leaf); Path = $r; Commits = @($commits) }
}
[pscustomobject]@{
  GeneratedAt = (Get-Date).ToString('s')
  SinceHours  = $SinceHours
  Repos       = @($activity)
  Transcripts = @(Get-RecentTranscripts -Dir $TranscriptsDir -SinceHours $SinceHours)
} | ConvertTo-Json -Depth 6
