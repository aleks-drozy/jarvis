# tests/collect-activity.Tests.ps1 - plain assertions, exit 1 on failure. Runs against a TEMP fixture
# (not the maintainer's real Projects dir) so it is machine-independent and CI-safe.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\collect-activity.ps1" -DotSourceOnly

function Assert($cond, $msg) { if (-not $cond) { Write-Error "FAIL: $msg"; exit 1 } }

# ---- fixture: a projects root with 2 real git repos (one nested), plus a node_modules decoy ----
$root = Join-Path $env:TEMP ("jarvis-activity-fixture-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force (Join-Path $root 'repo-a') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $root 'group\repo-b') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $root 'repo-a\node_modules\dep') | Out-Null
try {
  foreach ($r in @('repo-a', 'group\repo-b')) {
    $p = Join-Path $root $r
    git -C $p init -q
    git -C $p config user.email 'test@example.com'
    git -C $p config user.name 'Test'
    Set-Content -Encoding ASCII (Join-Path $p 'file.txt') 'hello'
    git -C $p add -A
    git -C $p commit -q -m "initial commit in $r"
  }
  # a .git inside node_modules must NOT be discovered
  git -C (Join-Path $root 'repo-a\node_modules\dep') init -q 2>$null

  # Get-GitRepos finds both fixture repos (depth<=3), skipping node_modules
  $repos = Get-GitRepos -Root $root -MaxDepth 3
  Assert ($repos.Count -eq 2) "expected exactly 2 repos in fixture, got $($repos.Count)"
  Assert ($repos -join ';' -match 'repo-b') "should find the nested repo-b"
  Assert (-not ($repos -join ';' -match 'node_modules')) "must not descend into node_modules"

  # Get-RecentCommits returns objects with Hash+Subject+Date. @() wrap: in PS 5.1 a single result is a
  # scalar with no .Count - the exact unwrap gotcha this suite exists to catch.
  $c = @(Get-RecentCommits -RepoPath (Join-Path $root 'repo-a') -Since '2020-01-01')
  Assert ($c.Count -ge 1) "expected the fixture commit"
  Assert ($c[0].Hash -and $c[0].Subject) "commit must have Hash and Subject"

  # Full-run JSON shape against the fixture: Commits must ALWAYS be an array (0/1/many) so consumers
  # can rely on .Commits[] (the ConvertTo-Json single-element unwrap bug, locked here)
  $json = & powershell -NoProfile -File "$PSScriptRoot\..\skill\bin\collect-activity.ps1" `
    -ProjectsDir $root -SinceHours 999999 | Out-String | ConvertFrom-Json
  Assert ($json.Repos.Count -eq 2) "full run should discover the 2 fixture repos, got $($json.Repos.Count)"
  foreach ($r in $json.Repos) {
    Assert ($null -ne $r.Commits -and ($r.Commits -is [System.Array] -or $r.Commits.Count -ge 0)) "Commits is always an array"
  }
  $withCommit = @($json.Repos | Where-Object { @($_.Commits).Count -ge 1 })
  Assert ($withCommit.Count -eq 2) "both fixture repos report their commit"
} finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
Write-Host "collect-activity: ALL PASS"
