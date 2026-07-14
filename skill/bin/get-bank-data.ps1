# skill/bin/get-bank-data.ps1
# Phase 3: read-only open-banking feed via Enable Banking (PSD2 AIS, Irish coverage incl. Revolut/
# AIB/Bank of Ireland/PTSB). Swapped from GoCardless Bank Account Data 2026-07 - GoCardless closed
# Bank Account Data to new signups mid-2025 and is winding it down (confirmed live, not a retry-later
# outage). See PHASE3-BANK.md and DECISIONS.md for the switch.
#
# READ-ONLY BY CONSTRUCTION (Safety rule 1): this script calls ONLY the AIS (account information)
# side of the Enable Banking API - /aspsps, /sessions, /accounts/*/balances, /accounts/*/transactions.
# It NEVER calls /payments (a payment-initiation endpoint exists on this API and is deliberately never
# referenced anywhere in this codebase). Output is AGGREGATES ONLY: masked IBAN (last 4), balances,
# and 30-day in/out/net totals - never raw transaction lines (finance guardrail; Safety rule 5 spirit).
#
# Auth: RS256-signed JWT, "kid" = the application id issued by Enable Banking's control panel,
# signed with a locally-generated RSA private key that is NEVER uploaded anywhere (only the public
# certificate is). Windows PowerShell 5.1 / .NET Framework has no built-in PEM-signing API, so
# signing shells out to openssl.exe (ships with Git for Windows - already on this machine). The
# private key is stored DPAPI-encrypted at rest (~/.jarvis/enablebanking.cred.xml) and is only ever
# written to a temp file for the instant openssl needs it, deleted immediately after (try/finally).
#
# ALWAYS exits 0 with structured JSON: the finance module must degrade, never kill the debrief.
param(
  [string]$CredPath  = (Join-Path $HOME '.jarvis\enablebanking.cred.xml'),
  [string]$StatePath = (Join-Path $HOME '.jarvis\bank.json'),
  [string]$HeartbeatPath = (Join-Path $HOME '.jarvis\bank-heartbeat.json'),
  [int]$DaysBack = 30,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'
$ApiBase = 'https://api.enablebanking.com'

function Get-OpenSslPath {
  $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in @(
    "$env:ProgramFiles\Git\usr\bin\openssl.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
    "$env:ProgramFiles\Git\mingw64\bin\openssl.exe"
  )) { if (Test-Path $p) { return $p } }
  throw 'openssl.exe not found (checked PATH and Git for Windows locations) - Enable Banking auth needs it to RS256-sign requests. Install Git for Windows (ships openssl) or add openssl to PATH.'
}

function ConvertTo-Base64Url {
  param([byte[]]$Bytes)
  [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-EnableBankingJwt {
  # RS256 JWT: header.payload signed with the application's RSA private key. "kid" is the
  # application id from the control panel (NOT a cert fingerprint - confirmed from EB API docs).
  param([string]$ApplicationId, [string]$PrivateKeyPem)
  $openssl = Get-OpenSslPath
  # NOT `Get-Date -UFormat %s`: in Windows PowerShell 5.1 it computes epoch seconds from local
  # wall-clock time WITHOUT correcting for the UTC offset, so on any machine not at UTC+0 every
  # JWT's iat/exp is skewed by exactly the local offset (1 hour on this BST machine) - Enable
  # Banking correctly rejects the result as "JWT can not be issued in the future" (401). Confirmed
  # by direct comparison 2026-07-14: UFormat gave 1784045929 vs the true 1784042329, a 3600s gap
  # matching the +01:00 offset exactly. DateTimeOffset.ToUnixTimeSeconds() is unambiguous UTC.
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $header  = @{ typ = 'JWT'; alg = 'RS256'; kid = $ApplicationId } | ConvertTo-Json -Compress
  $payload = @{ iss = 'enablebanking.com'; aud = 'api.enablebanking.com'; iat = $now; exp = ($now + 3600) } | ConvertTo-Json -Compress
  $h64 = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))
  $p64 = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload))
  $signingInput = "$h64.$p64"

  $keyFile = [IO.Path]::GetTempFileName(); $inFile = [IO.Path]::GetTempFileName(); $sigFile = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($keyFile, $PrivateKeyPem)
    [IO.File]::WriteAllText($inFile, $signingInput, [Text.Encoding]::ASCII)
    # openssl writes benign progress lines to stderr; 2>&1 would wrap each into a terminating
    # PowerShell ErrorRecord under $ErrorActionPreference='Stop' even on exit 0, so discard stderr
    # and rely on $LASTEXITCODE for real failures instead.
    & $openssl dgst -sha256 -sign $keyFile -out $sigFile $inFile 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl signing failed (exit $LASTEXITCODE) - private key may be malformed" }
    $sigBytes = [IO.File]::ReadAllBytes($sigFile)
    $s64 = ConvertTo-Base64Url $sigBytes
    return "$signingInput.$s64"
  } finally {
    foreach ($f in @($keyFile, $inFile, $sigFile)) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
  }
}

function Invoke-EBApi {
  param($Jwt, [string]$Method = 'Get', [string]$Path, $BodyObj = $null)
  $params = @{ Method = $Method; Uri = "$ApiBase$Path"; Headers = @{ Authorization = "Bearer $Jwt" } }
  if ($BodyObj) { $params.ContentType = 'application/json'; $params.Body = ($BodyObj | ConvertTo-Json -Depth 8) }
  Invoke-RestMethod @params
}

function Get-MaskedIban {
  param([string]$Iban)
  if (-not $Iban) { return 'n/a' }
  if ($Iban.Length -le 4) { return $Iban }
  return '****' + $Iban.Substring($Iban.Length - 4)
}

function Format-BankSummary {
  # Pure aggregation: raw Enable Banking balances/transactions in, aggregates out. No raw tx lines.
  # Input: array of @{ Name; Iban; Currency; Balances; Transactions } (parsed API JSON objects).
  # Enable Banking shape differs from the old GoCardless one: snake_case fields, transactions is a
  # flat array (not nested under .booked), balance_type uses ISO 20022 codes (CLBD/XPCD/ITAV/...).
  param($AccountsData)
  $accounts = @(); $totIn = [decimal]0; $totOut = [decimal]0; $totCount = 0
  foreach ($a in @($AccountsData)) {
    if ($null -eq $a) { continue }
    $bal = $null
    foreach ($pref in @('CLBD','ITAV','XPCD')) {
      foreach ($b in @($a.Balances.balances)) {
        if ($null -ne $b -and $b.balance_type -eq $pref) { $bal = $b; break }
      }
      if ($bal) { break }
    }
    if (-not $bal) { $all = @($a.Balances.balances); if ($all.Count -gt 0) { $bal = $all[0] } }
    $in = [decimal]0; $out = [decimal]0; $n = 0
    foreach ($t in @($a.Transactions.transactions)) {   # @() wrap: PowerShell's single-element-array scar
      if ($null -eq $t) { continue }
      $amt = [decimal]$t.transaction_amount.amount
      $n++
      if ($amt -ge 0) { $in += $amt } else { $out += [math]::Abs($amt) }
    }
    $totIn += $in; $totOut += $out; $totCount += $n
    $balAmount = $null; $balCurrency = $a.Currency; $balType = 'unavailable'
    if ($bal) { $balAmount = [decimal]$bal.balance_amount.amount; $balCurrency = $bal.balance_amount.currency; $balType = $bal.balance_type }
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

function Write-BankHeartbeat {
  # Best-effort: a heartbeat write must NEVER affect the feed's stdout JSON or exit-0 contract.
  param([string]$Path, [bool]$Ok, [string]$ErrorMsg, [int]$AccountCount, [string]$ConsentExpires)
  try {
    [pscustomobject]@{
      asOf = (Get-Date).ToString('s'); ok = $Ok; error = $ErrorMsg
      accountCount = $AccountCount; consentExpires = $ConsentExpires
    } | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 $Path
  } catch { }
}

if ($DotSourceOnly) { return }

try {
  if (-not (Test-Path $CredPath)) {
    [pscustomobject]@{ configured = $false; reason = "no credential at $CredPath"
      setup = 'run skill/bin/setup-bank.ps1 -GenerateKeypair (checklist: vault 12-jarvis/PHASE3-BANK.md)' } | ConvertTo-Json -Depth 4
    exit 0
  }
  if (-not (Test-Path $StatePath)) {
    [pscustomobject]@{ configured = $false; reason = "no session state at $StatePath"
      setup = 'run skill/bin/setup-bank.ps1 -NewSession (checklist: vault 12-jarvis/PHASE3-BANK.md)' } | ConvertTo-Json -Depth 4
    exit 0
  }
  $state = Get-Content $StatePath -Raw | ConvertFrom-Json
  if (-not $state.session_id -or @($state.accounts).Count -eq 0) {
    [pscustomobject]@{ configured = $false; reason = 'state file has no session_id / linked accounts'
      setup = 'run skill/bin/setup-bank.ps1 -NewSession' } | ConvertTo-Json -Depth 4
    exit 0
  }
  $cred = Import-Clixml $CredPath   # UserName = application id, Password = RSA private key PEM
  $appId = $cred.UserName
  $pem = $cred.GetNetworkCredential().Password
  $jwt = New-EnableBankingJwt -ApplicationId $appId -PrivateKeyPem $pem

  $from = (Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-dd')
  $data = @()
  foreach ($acc in @($state.accounts)) {
    $bal = Invoke-EBApi $jwt -Path "/accounts/$($acc.uid)/balances"
    $tx  = Invoke-EBApi $jwt -Path "/accounts/$($acc.uid)/transactions?date_from=$from"
    $nm = $acc.name; if (-not $nm) { $nm = 'account' }
    $iban = $acc.account_id.iban
    $data += @{ Name = $nm; Iban = $iban; Currency = $acc.currency; Balances = $bal; Transactions = $tx }
  }
  $sum = Format-BankSummary $data
  Write-BankHeartbeat -Path $HeartbeatPath -Ok $true -ErrorMsg $null -AccountCount (@($sum.accounts).Count) -ConsentExpires $state.consent_expires
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
    $hint = 'JWT/consent invalid or expired (PSD2 consents last ~90 days) - run setup-bank.ps1 -NewSession'
  }
  # $state may not be bound if the failure happened before the state file was read; keep the
  # consent countdown alive on error paths too (it is most needed right when 401s start).
  $ce = $null; try { if ($state -and $state.consent_expires) { $ce = $state.consent_expires } } catch {}
  Write-BankHeartbeat -Path $HeartbeatPath -Ok $false -ErrorMsg $msg -AccountCount 0 -ConsentExpires $ce
  # exit 0 on purpose: a broken bank feed must degrade the finance module, not kill the debrief
  [pscustomobject]@{ configured = $true; error = $msg; hint = $hint } | ConvertTo-Json -Depth 4
  exit 0
}
