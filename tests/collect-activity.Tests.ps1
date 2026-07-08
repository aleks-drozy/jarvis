# tests/collect-activity.Tests.ps1 — plain assertions, exit 1 on failure
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\collect-activity.ps1" -DotSourceOnly

function Assert($cond, $msg) { if (-not $cond) { Write-Error "FAIL: $msg"; exit 1 } }

# Get-GitRepos finds nested repos under Projects (depth<=3), skipping node_modules
$repos = Get-GitRepos -Root 'C:/Users/Alex/Projects' -MaxDepth 3
Assert ($repos.Count -ge 3) "expected >=3 repos under Projects, got $($repos.Count)"
Assert ($repos -join ';' -match 'personal-performance-os') "should find personal-performance-os repo"
Assert (-not ($repos -join ';' -match 'node_modules')) "must not descend into node_modules"

# Get-RecentCommits returns objects with Hash+Subject+Date for a known repo since a wide date
$c = Get-RecentCommits -RepoPath (@($repos | Where-Object { $_ -match 'personal-performance-os' })[0]) -Since '2020-01-01'
Assert ($c.Count -ge 1) "expected commits in personal-performance-os"
Assert ($c[0].Hash -and $c[0].Subject) "commit must have Hash and Subject"

# Full-run JSON shape: Commits must ALWAYS be an array (0/1/many) so consumers can rely on .Commits[]
$json = & powershell -NoProfile -File "$PSScriptRoot\..\skill\bin\collect-activity.ps1" -SinceHours 999999 | Out-String | ConvertFrom-Json
Assert ($json.Repos.Count -ge 1) "full run should discover repos"
foreach ($repo in $json.Repos) {
  Assert ($repo.Commits -is [array]) "Commits must be an array for $($repo.Repo) (got $($repo.Commits.GetType().Name))"
}
Assert ($json.Transcripts -is [array]) "Transcripts must be an array"

Write-Host "collect-activity: ALL PASS"
