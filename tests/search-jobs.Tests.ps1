# tests/search-jobs.Tests.ps1 - URL building + creds guard, no network calls
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\search-jobs.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

# URL builder: correct country segment, escaped terms, all params present
$u = Build-AdzunaQuery -What 'graduate software engineer' -Where 'Dublin' -Country 'ie' `
  -ResultsPerPage 10 -MaxDaysOld 7 -AppId 'IDX' -AppKey 'KEYX'
Assert ($u -match '^https://api\.adzuna\.com/v1/api/jobs/ie/search/1\?') "base URL + country segment"
Assert ($u -match 'what=graduate%20software%20engineer') "what param must be URL-escaped"
Assert ($u -match 'where=Dublin') "where param present"
Assert ($u -match 'app_id=IDX' -and $u -match 'app_key=KEYX') "credentials in query"
Assert ($u -match 'max_days_old=7' -and $u -match 'results_per_page=10') "filters present"
Assert ($u -match 'sort_by=date') "sorted by date"

# Creds guard: helpful error when keys are not set up (only if the file truly doesn't exist)
if (-not (Test-Path (Join-Path $HOME '.jarvis\adzuna.cred.xml'))) {
  $threw = $false
  try { Get-AdzunaCreds | Out-Null } catch { $threw = $true; Assert ($_.Exception.Message -match 'developer.adzuna.com') "error must point at setup" }
  Assert $threw "Get-AdzunaCreds must throw when keys are missing"
}

Write-Host "search-jobs: ALL PASS"
