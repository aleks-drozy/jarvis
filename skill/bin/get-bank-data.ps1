# skill/bin/get-bank-data.ps1
# Phase 3: read-only open-banking feed via GoCardless Bank Account Data (PSD2 AISP, Irish coverage).
# READ-ONLY BY CONSTRUCTION (Safety rule 1): this product exposes account-information scopes only -
# there is no payment scope to hold, so this script can see balances/transactions and can never move
# money. Output is AGGREGATES ONLY: masked IBAN (last 4), balances, and 30-day in/out/net totals -
# never raw transaction lines (finance guardrail: amounts and dates only; Safety rule 5 spirit).
# Credentials: DPAPI-encrypted PSCredential at ~/.jarvis/gocardless.cred.xml (never repo/vault).
# ALWAYS exits 0 with structured JSON: the finance module must degrade, never kill the debrief.
param(
  [string]$CredPath  = (Join-Path $HOME '.jarvis\gocardless.cred.xml'),
  [string]$StatePath = (Join-Path $HOME '.jarvis\bank.json'),
  [int]$DaysBack = 30,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'
$ApiBase = 'https://bankaccountdata.gocardless.com/api/v2'

function Get-BankToken {
  param($Cred)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $body = @{ secret_id = $Cred.UserName; secret_key = $Cred.GetNetworkCredential().Password } | ConvertTo-Json
  (Invoke-RestMethod -Method Post -Uri "$ApiBase/token/new/" -ContentType 'application/json' -Body $body).access
}

function Invoke-BankApi {
  param($Token, $Path)
  Invoke-RestMethod -Method Get -Uri "$ApiBase$Path" -Headers @{ Authorization = "Bearer $Token" }
}

function Get-MaskedIban {
  param([string]$Iban)
  if (-not $Iban) { return 'n/a' }
  if ($Iban.Length -le 4) { return $Iban }
  return '****' + $Iban.Substring($Iban.Length - 4)
}

function Format-BankSummary {
  # Pure aggregation: raw GoCardless balances/transactions in, aggregates out. No raw tx lines.
  # Input: array of @{ Name; Iban; Balances; Transactions } (parsed API JSON objects).
  param($AccountsData)
  $accounts = @(); $totIn = [decimal]0; $totOut = [decimal]0; $totCount = 0
  foreach ($a in @($AccountsData)) {
    if ($null -eq $a) { continue }
    # pick the most useful balance type available
    $bal = $null
    foreach ($pref in @('interimAvailable','expected','closingBooked')) {
      foreach ($b in @($a.Balances.balances)) {
        if ($null -ne $b -and $b.balanceType -eq $pref) { $bal = $b; break }
      }
      if ($bal) { break }
    }
    if (-not $bal) { $all = @($a.Balances.balances); if ($all.Count -gt 0) { $bal = $all[0] } }
    $in = [decimal]0; $out = [decimal]0; $n = 0
    foreach ($t in @($a.Transactions.transactions.booked)) {   # @() wrap: single-element scar
      if ($null -eq $t) { continue }
      $amt = [decimal]$t.transactionAmount.amount
      $n++
      if ($amt -ge 0) { $in += $amt } else { $out += [math]::Abs($amt) }
    }
    $totIn += $in; $totOut += $out; $totCount += $n
    $balAmount = $null; $balCurrency = $null; $balType = 'unavailable'
    if ($bal) { $balAmount = [decimal]$bal.balanceAmount.amount; $balCurrency = $bal.balanceAmount.currency; $balType = $bal.balanceType }
    $accounts += [pscustomobject]@{
      name = $a.Name
      iban = Get-MaskedIban $a.Iban
      currency = $balCurrency
      balance = $balAmount
      balanceType = $balType
      last30d = [pscustomobject]@{ txCount = $n; moneyIn = $in; moneyOut = $out; net = ($in - $out) }
    }
  }
  return [pscustomobject]@{
    accounts = $accounts
    totals = [pscustomobject]@{ txCount = $totCount; moneyIn = $totIn; moneyOut = $totOut; net = ($totIn - $totOut) }
  }
}

if ($DotSourceOnly) { return }

try {
  if (-not (Test-Path $CredPath)) {
    [pscustomobject]@{ configured = $false; reason = "no credential at $CredPath"
      setup = 'run skill/bin/setup-bank.ps1 -StoreCredential (checklist: vault 12-jarvis/PHASE3-BANK.md)' } | ConvertTo-Json -Depth 4
    exit 0
  }
  if (-not (Test-Path $StatePath)) {
    [pscustomobject]@{ configured = $false; reason = "no requisition state at $StatePath"
      setup = 'run skill/bin/setup-bank.ps1 -NewRequisition (checklist: vault 12-jarvis/PHASE3-BANK.md)' } | ConvertTo-Json -Depth 4
    exit 0
  }
  $state = Get-Content $StatePath -Raw | ConvertFrom-Json
  if (-not $state.requisition_id) {
    [pscustomobject]@{ configured = $false; reason = 'state file has no requisition_id'
      setup = 'run skill/bin/setup-bank.ps1 -NewRequisition' } | ConvertTo-Json -Depth 4
    exit 0
  }
  $cred = Import-Clixml $CredPath
  $tok = Get-BankToken $cred
  $req = Invoke-BankApi $tok "/requisitions/$($state.requisition_id)/"
  if (@($req.accounts).Count -eq 0) {
    [pscustomobject]@{ configured = $true; error = "no linked accounts (requisition status: $($req.status))"
      hint = 'consent incomplete or expired - run setup-bank.ps1 -NewRequisition and approve at the bank' } | ConvertTo-Json -Depth 4
    exit 0
  }
  $from = (Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-dd')
  $data = @()
  foreach ($accId in @($req.accounts)) {
    $det = Invoke-BankApi $tok "/accounts/$accId/details/"
    $bal = Invoke-BankApi $tok "/accounts/$accId/balances/"
    $tx  = Invoke-BankApi $tok "/accounts/$accId/transactions/?date_from=$from"
    $nm = $det.account.name
    if (-not $nm) { $nm = $det.account.product }
    if (-not $nm) { $nm = $det.account.ownerName }
    if (-not $nm) { $nm = 'account' }
    $data += @{ Name = $nm; Iban = $det.account.iban; Balances = $bal; Transactions = $tx }
  }
  $sum = Format-BankSummary $data
  [pscustomobject]@{
    configured = $true
    asOf = (Get-Date).ToString('s')
    daysBack = $DaysBack
    accounts = $sum.accounts
    totals = $sum.totals
  } | ConvertTo-Json -Depth 6
} catch {
  $msg = $_.Exception.Message
  $hint = 'transient API/network failure - module degrades this run, retries tomorrow'
  if ($msg -match '401|403|Unauthorized|Forbidden') {
    $hint = 'token or consent invalid/expired (consents last ~90 days) - run setup-bank.ps1 -NewRequisition'
  }
  # exit 0 on purpose: a broken bank feed must degrade the finance module, not kill the debrief
  [pscustomobject]@{ configured = $true; error = $msg; hint = $hint } | ConvertTo-Json -Depth 4
  exit 0
}
