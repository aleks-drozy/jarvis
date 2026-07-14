# tests/get-bank-data.Tests.ps1 - Phase 3 bank feed collector: offline behavior only, no network.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$script = "$PSScriptRoot\..\skill\bin\get-bank-data.ps1"
Assert (Test-Path $script) "get-bank-data.ps1 must exist"

# 1. Degradation path: no credential file -> structured configured:false JSON, exit 0.
#    The debrief must never die because the bank feed is unconfigured (module isolation, design 8).
#    Run in a child process because the script uses `exit`.
$bogusCred  = Join-Path $env:TEMP 'jarvis-test-no-such-cred.xml'
$bogusState = Join-Path $env:TEMP 'jarvis-test-no-such-state.json'
if (Test-Path $bogusCred)  { Remove-Item $bogusCred -Force }
if (Test-Path $bogusState) { Remove-Item $bogusState -Force }
$raw = powershell -NoProfile -File $script -CredPath $bogusCred -StatePath $bogusState
Assert ($LASTEXITCODE -eq 0) "unconfigured run must exit 0 (module degrades, debrief survives)"
$j = ($raw -join "`n") | ConvertFrom-Json
Assert ($j.configured -eq $false) "no credential -> configured must be false"
Assert ($j.setup -match 'setup-bank') "unconfigured output must point at the setup script"

# 2. Pure aggregation: Format-BankSummary turns raw GoCardless shapes into aggregates ONLY
#    (no raw transaction lines, masked IBAN - finance guardrail: amounts and dates only).
. $script -DotSourceOnly
$balJson = '{"balances":[{"balanceAmount":{"amount":"494.23","currency":"EUR"},"balanceType":"interimAvailable"}]}'
$txJson  = '{"transactions":{"booked":[
  {"transactionAmount":{"amount":"-12.50","currency":"EUR"},"bookingDate":"2026-07-10"},
  {"transactionAmount":{"amount":"433.00","currency":"EUR"},"bookingDate":"2026-07-01"},
  {"transactionAmount":{"amount":"-20.00","currency":"EUR"},"bookingDate":"2026-07-03"}]}}'
$fake = @(@{ Name='Revolut'; Iban='IE29AIBK93115212345678'; Balances=($balJson|ConvertFrom-Json); Transactions=($txJson|ConvertFrom-Json) })
$s = Format-BankSummary $fake
Assert ($s.accounts.Count -eq 1) "one account in, one account out"
Assert ($s.accounts[0].balance -eq [decimal]494.23) "balance must be parsed as decimal"
Assert ($s.accounts[0].iban -eq '****5678') "IBAN must be masked to last 4"
Assert ($s.accounts[0].last30d.txCount -eq 3) "tx count aggregates all booked"
Assert ($s.accounts[0].last30d.moneyIn -eq [decimal]433.00) "money in sums positive amounts"
Assert ($s.accounts[0].last30d.moneyOut -eq [decimal]32.50) "money out sums abs(negative amounts)"
Assert ($s.totals.net -eq [decimal]400.50) "net = in - out"
$flat = $s | ConvertTo-Json -Depth 6
Assert (-not ($flat -match 'bookingDate')) "output must contain aggregates only - no raw transaction lines"
Assert (-not ($flat -match '93115212345678')) "output must never contain the full IBAN"

# 3. The ConvertFrom-Json single-element scar (README battle scar): ONE booked transaction
#    must still count as 1, not unwrap into property soup.
$txOne = '{"transactions":{"booked":[{"transactionAmount":{"amount":"-5.00","currency":"EUR"},"bookingDate":"2026-07-11"}]}}'
$fake1 = @(@{ Name='AIB'; Iban='IE00XXXX1111'; Balances=($balJson|ConvertFrom-Json); Transactions=($txOne|ConvertFrom-Json) })
$s1 = Format-BankSummary $fake1
Assert ($s1.accounts[0].last30d.txCount -eq 1) "single-transaction account must count exactly 1 (array-unwrap scar)"
Assert ($s1.totals.moneyOut -eq [decimal]5.00) "single-transaction sum must be correct"

# 4. Repo battle scar: new .ps1 files must be pure ASCII.
foreach ($f in @("$PSScriptRoot\..\skill\bin\get-bank-data.ps1", "$PSScriptRoot\..\skill\bin\setup-bank.ps1")) {
  Assert (Test-Path $f) "$f must exist"
  $bytes = [IO.File]::ReadAllBytes($f)
  $bad = 0; for ($i=0; $i -lt $bytes.Length; $i++){ if ($bytes[$i] -gt 127){ $bad++ } }
  Assert ($bad -eq 0) "$(Split-Path $f -Leaf) must be pure ASCII (found $bad non-ASCII bytes)"
}

Write-Host "get-bank-data: ALL PASS"
