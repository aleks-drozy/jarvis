# skill/bin/search-jobs.ps1
# Searches the Adzuna job API (legal aggregator, free tier) and emits compact JSON.
# Usage:   powershell -File search-jobs.ps1 -What "software engineer" -Where "Dublin"
# Setup:   store free keys from https://developer.adzuna.com once:
#            $id  = Read-Host 'Adzuna app_id'
#            $key = Read-Host 'Adzuna app_key' -AsSecureString
#            New-Object System.Management.Automation.PSCredential($id, $key) |
#              Export-Clixml $HOME\.jarvis\adzuna.cred.xml
param(
  [string]$What = 'software engineer',
  [string]$Where = 'Dublin',
  [string]$Country = 'ie',
  [int]$ResultsPerPage = 10,
  [int]$MaxDaysOld = 7,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'

function Get-AdzunaCreds {
  $f = Join-Path $HOME '.jarvis\adzuna.cred.xml'
  if (-not (Test-Path $f)) {
    throw "No Adzuna keys at $f - register free at developer.adzuna.com, then run the setup block in this script's header."
  }
  $c = Import-Clixml $f
  return @{ AppId = $c.UserName; AppKey = $c.GetNetworkCredential().Password }
}

function Build-AdzunaQuery {
  param([string]$What, [string]$Where, [string]$Country, [int]$ResultsPerPage, [int]$MaxDaysOld,
        [string]$AppId, [string]$AppKey)
  $base = "https://api.adzuna.com/v1/api/jobs/$Country/search/1"
  $q = @(
    "app_id=$AppId",
    "app_key=$AppKey",
    "what=$([uri]::EscapeDataString($What))",
    "where=$([uri]::EscapeDataString($Where))",
    "results_per_page=$ResultsPerPage",
    "max_days_old=$MaxDaysOld",
    "sort_by=date",
    "content-type=application/json"
  ) -join '&'
  return "$base`?$q"
}

function Search-Jobs {
  param([string]$What, [string]$Where, [string]$Country, [int]$ResultsPerPage, [int]$MaxDaysOld)
  $creds = Get-AdzunaCreds
  $url = Build-AdzunaQuery -What $What -Where $Where -Country $Country `
    -ResultsPerPage $ResultsPerPage -MaxDaysOld $MaxDaysOld -AppId $creds.AppId -AppKey $creds.AppKey
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
  $jobs = @($resp.results | ForEach-Object {
    [pscustomobject]@{
      Title    = $_.title -replace '<[^>]+>', ''
      Company  = $_.company.display_name
      Location = $_.location.display_name
      SalaryMin = $_.salary_min
      SalaryMax = $_.salary_max
      Posted   = $_.created
      Url      = $_.redirect_url
      Snippet  = (($_.description -replace '<[^>]+>', '') -replace '\s+', ' ').Substring(0, [Math]::Min(220, ($_.description -replace '<[^>]+>', '').Length))
    }
  })
  return [pscustomobject]@{
    Query = $What; Where = $Where; Country = $Country; TotalAvailable = $resp.count; Jobs = $jobs
  }
}

if ($DotSourceOnly) { return }
Search-Jobs -What $What -Where $Where -Country $Country `
  -ResultsPerPage $ResultsPerPage -MaxDaysOld $MaxDaysOld | ConvertTo-Json -Depth 5
