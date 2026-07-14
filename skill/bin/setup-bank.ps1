# skill/bin/setup-bank.ps1
# Phase 3 one-time setup - RUN BY ALEX in a normal terminal, never by headless Jarvis.
# Jarvis is not permitted to create accounts or perform bank consent (skill Safety rules);
# this script only prepares credentials/state and PRINTS the consent link for Alex to open.
# Full checklist: vault 12-jarvis/PHASE3-BANK.md.
#
# Usage:
#   setup-bank.ps1 -StoreCredential -SecretId <id> -SecretKey <key>   # from GoCardless BAD portal
#   setup-bank.ps1 -ListBanks [-Country ie]                           # find your institution id
#   setup-bank.ps1 -NewRequisition -InstitutionId <id>                # prints the consent link
#   setup-bank.ps1 -CheckRequisition                                  # confirm accounts linked
param(
  [switch]$StoreCredential, [string]$SecretId, [string]$SecretKey,
  [switch]$ListBanks, [string]$Country = 'ie',
  [switch]$NewRequisition, [string]$InstitutionId,
  [string]$RedirectUrl = 'https://localhost/jarvis-bank-consent-done',
  [switch]$CheckRequisition,
  [string]$CredPath  = (Join-Path $HOME '.jarvis\gocardless.cred.xml'),
  [string]$StatePath = (Join-Path $HOME '.jarvis\bank.json')
)
$ErrorActionPreference = 'Stop'

# Reuse Get-BankToken/Invoke-BankApi/$ApiBase from the collector. Dot-sourcing rebinds its param
# defaults into this scope, so capture our own paths first and restore them after.
$myCred = $CredPath; $myState = $StatePath
. "$PSScriptRoot\get-bank-data.ps1" -DotSourceOnly
$CredPath = $myCred; $StatePath = $myState

function Invoke-BankApiPost {
  param($Token, $Path, $BodyObj)
  Invoke-RestMethod -Method Post -Uri "$ApiBase$Path" -Headers @{ Authorization = "Bearer $Token" } `
    -ContentType 'application/json' -Body ($BodyObj | ConvertTo-Json)
}

if ($StoreCredential) {
  if (-not $SecretId -or -not $SecretKey) {
    throw 'need -SecretId and -SecretKey (GoCardless Bank Account Data portal -> Developers -> User secrets)'
  }
  $dir = Split-Path $CredPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $sec = ConvertTo-SecureString $SecretKey -AsPlainText -Force
  New-Object System.Management.Automation.PSCredential($SecretId, $sec) | Export-Clixml $CredPath
  Write-Host "Stored (DPAPI-encrypted to this Windows user): $CredPath"
  Write-Host 'Secrets never go in the repo or the vault (Safety rule 6).'
  try {
    $null = Get-BankToken (Import-Clixml $CredPath)
    Write-Host 'Token check: OK. Next: -ListBanks, then -NewRequisition.'
  } catch {
    Write-Warning "Token check FAILED: $($_.Exception.Message) - re-check the secret id/key."
  }
  exit 0
}

if ($ListBanks) {
  $tok = Get-BankToken (Import-Clixml $CredPath)
  $inst = Invoke-BankApi $tok "/institutions/?country=$Country"
  $inst | Sort-Object name | Format-Table id, name -AutoSize
  Write-Host 'Pick your bank id (Revolut / AIB / Bank of Ireland / PTSB), then run -NewRequisition -InstitutionId <id>.'
  exit 0
}

if ($NewRequisition) {
  if (-not $InstitutionId) { throw 'need -InstitutionId (find it with -ListBanks)' }
  $tok = Get-BankToken (Import-Clixml $CredPath)
  $ref = 'jarvis-' + (Get-Date -Format 'yyyyMMddHHmmss')
  $req = Invoke-BankApiPost $tok '/requisitions/' @{ redirect = $RedirectUrl; institution_id = $InstitutionId; reference = $ref }
  @{ requisition_id = $req.id; institution_id = $InstitutionId; created = (Get-Date).ToString('s') } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $StatePath
  Write-Host ''
  Write-Host 'OPEN THIS LINK IN YOUR BROWSER and approve READ-ONLY access at your bank:'
  Write-Host ('  ' + $req.link)
  Write-Host 'The final redirect page may show a browser error - that is expected (localhost).'
  Write-Host 'When done, run: setup-bank.ps1 -CheckRequisition'
  exit 0
}

if ($CheckRequisition) {
  if (-not (Test-Path $StatePath)) { throw "no state at $StatePath - run -NewRequisition first" }
  $state = Get-Content $StatePath -Raw | ConvertFrom-Json
  $tok = Get-BankToken (Import-Clixml $CredPath)
  $req = Invoke-BankApi $tok "/requisitions/$($state.requisition_id)/"
  Write-Host ("Status: {0}   Linked accounts: {1}" -f $req.status, @($req.accounts).Count)
  if (@($req.accounts).Count -gt 0) {
    Write-Host 'Linked. Test the feed:   powershell -NoProfile -File skill\bin\get-bank-data.ps1'
    Write-Host 'Then flip CONFIG.md:     modules: finance_bank: on'
  } else {
    Write-Host 'No accounts linked yet - finish the consent link from -NewRequisition (status LN = linked).'
  }
  exit 0
}

Write-Host 'Phase 3 bank feed setup (see vault 12-jarvis/PHASE3-BANK.md for the checklist):'
Write-Host '  1. setup-bank.ps1 -StoreCredential -SecretId <id> -SecretKey <key>'
Write-Host '  2. setup-bank.ps1 -ListBanks'
Write-Host '  3. setup-bank.ps1 -NewRequisition -InstitutionId <id>   (open the printed link, approve)'
Write-Host '  4. setup-bank.ps1 -CheckRequisition'
Write-Host '  5. flip CONFIG.md modules: finance_bank: on'
