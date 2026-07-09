# skill/bin/search-jobs.ps1
# Searches job APIs (legal aggregators, free tiers) and emits compact JSON.
#   - Jooble  (default; covers Ireland via ie.jooble.org)  key: ~/.jarvis/jooble.cred.xml
#   - Adzuna  (fallback; 19 countries, NOT Ireland)        key: ~/.jarvis/adzuna.cred.xml
# Usage:   powershell -File search-jobs.ps1 -What "software engineer" -Where "Dublin"
#          powershell -File search-jobs.ps1 -Provider adzuna -Country gb -Where "London" -What "..."
# Setup (Jooble, one minute): register at https://jooble.org/api/about, then:
#            $key = Read-Host 'Jooble API key' -AsSecureString
#            New-Object System.Management.Automation.PSCredential('jooble', $key) |
#              Export-Clixml $HOME\.jarvis\jooble.cred.xml
param(
  [string]$What = 'software engineer',
  [string]$Where = 'Dublin',
  [ValidateSet('jooble','adzuna')][string]$Provider = 'jooble',
  [string]$Country = 'ie',      # jooble: subdomain (ie, gb, ...); adzuna: country code (NOT ie)
  [int]$ResultsPerPage = 10,
  [int]$MaxDaysOld = 7,         # adzuna only; jooble sorts by relevance/date itself
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'

function Get-StoredKey {
  param([string]$File, [string]$Hint)
  $f = Join-Path $HOME ".jarvis\$File"
  if (-not (Test-Path $f)) { throw "No key at $f - $Hint" }
  return (Import-Clixml $f)
}

# ---------------- Jooble ----------------
# NOTE (verified live): only the MAIN domain accepts API calls (regional subdomains return 403),
# and a bare city like "Dublin" matches Dublin, California - so the country name is appended
# to the location to scope results correctly.
$JoobleCountryNames = @{ ie = 'Ireland'; gb = 'United Kingdom'; us = 'United States'; de = 'Germany'; fr = 'France'; nl = 'Netherlands'; es = 'Spain' }

function Build-JoobleRequest {
  param([string]$What, [string]$Where, [string]$Country, [int]$ResultsPerPage, [string]$ApiKey)
  $loc = $Where
  $cname = $JoobleCountryNames[$Country]
  if ($cname -and $loc -notmatch [regex]::Escape($cname)) { $loc = "$loc, $cname" }
  return @{
    Uri  = "https://jooble.org/api/$ApiKey"
    Body = (@{ keywords = $What; location = $loc; page = '1' } | ConvertTo-Json)
  }
}

function Search-JoobleJobs {
  param([string]$What, [string]$Where, [string]$Country, [int]$ResultsPerPage)
  $cred = Get-StoredKey -File 'jooble.cred.xml' -Hint 'register free at jooble.org/api/about, then run the setup block in this script header.'
  $key = $cred.GetNetworkCredential().Password
  $req = Build-JoobleRequest -What $What -Where $Where -Country $Country -ResultsPerPage $ResultsPerPage -ApiKey $key
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $resp = Invoke-RestMethod -Uri $req.Uri -Method Post -Body $req.Body -ContentType 'application/json' -TimeoutSec 30
  $jobs = @($resp.jobs | Select-Object -First $ResultsPerPage | ForEach-Object {
    $desc = ($_.snippet -replace '<[^>]+>', '') -replace '\s+', ' '
    [pscustomobject]@{
      Title    = ($_.title -replace '<[^>]+>', '')
      Company  = $_.company
      Location = $_.location
      Salary   = $_.salary
      Posted   = $_.updated
      Url      = $_.link
      Snippet  = $desc.Substring(0, [Math]::Min(220, $desc.Length))
    }
  })
  return [pscustomobject]@{ Provider='jooble'; Query=$What; Where=$Where; Country=$Country
    TotalAvailable = $resp.totalCount; Jobs = $jobs }
}

# ---------------- Adzuna ----------------
function Get-AdzunaCreds {
  $c = Get-StoredKey -File 'adzuna.cred.xml' -Hint 'register free at developer.adzuna.com, then store app_id/app_key per the header of this script (v1 block).'
  return @{ AppId = $c.UserName; AppKey = $c.GetNetworkCredential().Password }
}

function Build-AdzunaQuery {
  param([string]$What, [string]$Where, [string]$Country, [int]$ResultsPerPage, [int]$MaxDaysOld,
        [string]$AppId, [string]$AppKey)
  if ($Country -eq 'ie') { throw "Adzuna does not support Ireland (ie) - use -Provider jooble for Irish searches." }
  $base = "https://api.adzuna.com/v1/api/jobs/$Country/search/1"
  $q = @(
    "app_id=$AppId", "app_key=$AppKey",
    "what=$([uri]::EscapeDataString($What))",
    "where=$([uri]::EscapeDataString($Where))",
    "results_per_page=$ResultsPerPage", "max_days_old=$MaxDaysOld",
    "sort_by=date", "content-type=application/json"
  ) -join '&'
  return "$base`?$q"
}

function Search-AdzunaJobs {
  param([string]$What, [string]$Where, [string]$Country, [int]$ResultsPerPage, [int]$MaxDaysOld)
  $creds = Get-AdzunaCreds
  $url = Build-AdzunaQuery -What $What -Where $Where -Country $Country `
    -ResultsPerPage $ResultsPerPage -MaxDaysOld $MaxDaysOld -AppId $creds.AppId -AppKey $creds.AppKey
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
  $jobs = @($resp.results | ForEach-Object {
    $desc = ($_.description -replace '<[^>]+>', '') -replace '\s+', ' '
    [pscustomobject]@{
      Title    = ($_.title -replace '<[^>]+>', '')
      Company  = $_.company.display_name
      Location = $_.location.display_name
      Salary   = if ($_.salary_min) { "$([int]$_.salary_min)-$([int]$_.salary_max)" } else { '' }
      Posted   = $_.created
      Url      = $_.redirect_url
      Snippet  = $desc.Substring(0, [Math]::Min(220, $desc.Length))
    }
  })
  return [pscustomobject]@{ Provider='adzuna'; Query=$What; Where=$Where; Country=$Country
    TotalAvailable = $resp.count; Jobs = $jobs }
}

if ($DotSourceOnly) { return }

$result = switch ($Provider) {
  'jooble' { Search-JoobleJobs -What $What -Where $Where -Country $Country -ResultsPerPage $ResultsPerPage }
  'adzuna' { Search-AdzunaJobs -What $What -Where $Where -Country $Country -ResultsPerPage $ResultsPerPage -MaxDaysOld $MaxDaysOld }
}
$result | ConvertTo-Json -Depth 5
