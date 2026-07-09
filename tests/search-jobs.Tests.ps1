# tests/search-jobs.Tests.ps1 - request building + creds guards, no network calls
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\search-jobs.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

# Jooble request: Ireland subdomain, key in path, keywords/location in JSON body
$r = Build-JoobleRequest -What 'graduate software engineer' -Where 'Dublin' -Country 'ie' -ResultsPerPage 10 -ApiKey 'KEYX'
Assert ($r.Uri -eq 'https://ie.jooble.org/api/KEYX') "jooble URI must use ie subdomain + key path (got $($r.Uri))"
$b = $r.Body | ConvertFrom-Json
Assert ($b.keywords -eq 'graduate software engineer') "jooble body keywords"
Assert ($b.location -eq 'Dublin') "jooble body location"

# Adzuna URL: correct country segment, escaped terms, all params present
$u = Build-AdzunaQuery -What 'graduate software engineer' -Where 'London' -Country 'gb' `
  -ResultsPerPage 10 -MaxDaysOld 7 -AppId 'IDX' -AppKey 'KEYX'
Assert ($u -match '^https://api\.adzuna\.com/v1/api/jobs/gb/search/1\?') "adzuna base URL + country"
Assert ($u -match 'what=graduate%20software%20engineer') "what must be URL-escaped"
Assert ($u -match 'app_id=IDX' -and $u -match 'app_key=KEYX') "credentials in query"
Assert ($u -match 'max_days_old=7' -and $u -match 'sort_by=date') "filters present"

# Adzuna must refuse Ireland with a pointer to jooble
$threw = $false
try { Build-AdzunaQuery -What 'x' -Where 'Dublin' -Country 'ie' -ResultsPerPage 5 -MaxDaysOld 7 -AppId 'a' -AppKey 'b' | Out-Null }
catch { $threw = $true; Assert ($_.Exception.Message -match 'jooble') "ie error must point at jooble" }
Assert $threw "Adzuna with ie must throw"

# Creds guard: helpful error when jooble key missing (only if truly absent)
if (-not (Test-Path (Join-Path $HOME '.jarvis\jooble.cred.xml'))) {
  $threw2 = $false
  try { Get-StoredKey -File 'jooble.cred.xml' -Hint 'register free at jooble.org/api/about' | Out-Null }
  catch { $threw2 = $true; Assert ($_.Exception.Message -match 'jooble.org') "error must point at setup" }
  Assert $threw2 "Get-StoredKey must throw when key missing"
}

Write-Host "search-jobs: ALL PASS"
