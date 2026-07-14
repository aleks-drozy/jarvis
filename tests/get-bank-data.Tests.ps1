# tests/get-bank-data.Tests.ps1 - Phase 3 bank feed collector (Enable Banking): offline, no real account.
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

# 2. State-without-accounts must also degrade (not crash trying to read accounts[0]).
$partialState = Join-Path $env:TEMP 'jarvis-test-partial-state.json'
'{"session_id":"abc","accounts":[]}' | Set-Content -Encoding UTF8 $partialState
$dummyCred = Join-Path $env:TEMP 'jarvis-test-dummy-cred.xml'
$sec = ConvertTo-SecureString 'dummy-pem' -AsPlainText -Force
New-Object System.Management.Automation.PSCredential('dummy-app-id', $sec) | Export-Clixml $dummyCred
$raw2 = powershell -NoProfile -File $script -CredPath $dummyCred -StatePath $partialState
Assert ($LASTEXITCODE -eq 0) "empty-accounts state must exit 0"
$j2 = ($raw2 -join "`n") | ConvertFrom-Json
Assert ($j2.configured -eq $false) "empty linked accounts -> configured must be false, not a crash"
Remove-Item $partialState, $dummyCred -Force -ErrorAction SilentlyContinue

. $script -DotSourceOnly

# 3. Base64url encoding: no padding, URL-safe alphabet (RFC 7515 JWS encoding rules).
$b64u = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('any carnal pleasure.'))
Assert (-not ($b64u -match '[+/=]')) "base64url must not contain +, / or = (got: $b64u)"
Assert ($b64u -eq 'YW55IGNhcm5hbCBwbGVhc3VyZS4') "base64url must match the known RFC 4648 test vector"

# 4. JWT structure + REAL cryptographic signature verification, using a disposable local keypair
#    (never touches the network or a real Enable Banking account).
$tmpDir = Join-Path $env:TEMP ('jarvis-jwt-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmpDir | Out-Null
$keyPath = Join-Path $tmpDir 'test-private.key'
$crtPath = Join-Path $tmpDir 'test-cert.pem'
$pubPath = Join-Path $tmpDir 'test-public.pem'
$opensslPath = Get-OpenSslPath
# discard stderr rather than 2>&1: openssl's benign progress lines become terminating
# ErrorRecords under $ErrorActionPreference='Stop' otherwise, even on exit 0. (Note: `openssl rsa
# -pubout` specifically trips this even with 2>$null - avoided below by deriving the public key
# from a self-signed cert instead, the same shape production's setup-bank.ps1 already uses.)
& $opensslPath genrsa -out $keyPath 2048 2>$null | Out-Null
Assert ($LASTEXITCODE -eq 0) "test fixture: openssl genrsa must succeed"
& $opensslPath req -new -x509 -days 1 -key $keyPath -out $crtPath -subj '/CN=jarvis-test' 2>$null | Out-Null
Assert ($LASTEXITCODE -eq 0) "test fixture: openssl req -new -x509 must succeed"
& $opensslPath x509 -pubkey -noout -in $crtPath -out $pubPath 2>$null | Out-Null
Assert ($LASTEXITCODE -eq 0) "test fixture: openssl x509 -pubkey must succeed"

$pem = Get-Content $keyPath -Raw
$jwt = New-EnableBankingJwt -ApplicationId 'test-app-id-1234' -PrivateKeyPem $pem
$parts = $jwt -split '\.'
Assert ($parts.Count -eq 3) "a JWT must have exactly 3 dot-separated segments (got $($parts.Count))"

function ConvertFrom-Base64Url([string]$s) {
  $s = $s.Replace('-','+').Replace('_','/')
  switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}
$header  = ConvertFrom-Base64Url $parts[0] | ConvertFrom-Json
$payload = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json
Assert ($header.alg -eq 'RS256') "JWT header alg must be RS256 (got $($header.alg))"
Assert ($header.kid -eq 'test-app-id-1234') "JWT header kid must be the application id"
Assert ($payload.iss -eq 'enablebanking.com') "JWT payload iss must be enablebanking.com"
Assert ($payload.aud -eq 'api.enablebanking.com') "JWT payload aud must be api.enablebanking.com"
Assert ($payload.exp -gt $payload.iat) "exp must be after iat"
Assert (($payload.exp - $payload.iat) -le 86400) "TTL must not exceed Enable Banking's 24h max"

# Verify the signature actually validates against the public key derived from the same private key -
# proves New-EnableBankingJwt signs what it claims to sign, not just that it produces JWT-shaped text.
$sigBytes = [Convert]::FromBase64String(($parts[2].Replace('-','+').Replace('_','/') + ('=' * ((4 - $parts[2].Length % 4) % 4))))
$sigFile = Join-Path $tmpDir 'sig.bin'; $inFile = Join-Path $tmpDir 'in.txt'
[IO.File]::WriteAllBytes($sigFile, $sigBytes)
[IO.File]::WriteAllText($inFile, "$($parts[0]).$($parts[1])", [Text.Encoding]::ASCII)
& $opensslPath dgst -sha256 -verify $pubPath -signature $sigFile $inFile 2>$null | Out-Null
Assert ($LASTEXITCODE -eq 0) "JWT signature must cryptographically verify against the matching public key"
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# 5. Pure aggregation: Format-BankSummary turns raw Enable Banking shapes into aggregates ONLY
#    (no raw transaction lines, masked IBAN - finance guardrail: amounts and dates only).
$balJson = '{"balances":[{"balance_amount":{"amount":"494.23","currency":"EUR"},"balance_type":"CLBD"}]}'
$txJson  = '{"transactions":[
  {"transaction_amount":{"amount":"-12.50","currency":"EUR"},"booking_date":"2026-07-10"},
  {"transaction_amount":{"amount":"433.00","currency":"EUR"},"booking_date":"2026-07-01"},
  {"transaction_amount":{"amount":"-20.00","currency":"EUR"},"booking_date":"2026-07-03"}]}'
$fake = @(@{ Name='Revolut'; Iban='IE29AIBK93115212345678'; Currency='EUR'; Balances=($balJson|ConvertFrom-Json); Transactions=($txJson|ConvertFrom-Json) })
$s = Format-BankSummary $fake
Assert ($s.accounts.Count -eq 1) "one account in, one account out"
Assert ($s.accounts[0].balance -eq [decimal]494.23) "balance must be parsed as decimal"
Assert ($s.accounts[0].balanceType -eq 'CLBD') "preferred ISO 20022 balance type must be selected"
Assert ($s.accounts[0].iban -eq '****5678') "IBAN must be masked to last 4"
Assert ($s.accounts[0].last30d.txCount -eq 3) "tx count aggregates all transactions"
Assert ($s.accounts[0].last30d.moneyIn -eq [decimal]433.00) "money in sums positive amounts"
Assert ($s.accounts[0].last30d.moneyOut -eq [decimal]32.50) "money out sums abs(negative amounts)"
Assert ($s.totals.net -eq [decimal]400.50) "net = in - out"
$flat = $s | ConvertTo-Json -Depth 6
Assert (-not ($flat -match 'booking_date')) "output must contain aggregates only - no raw transaction lines"
Assert (-not ($flat -match '93115212345678')) "output must never contain the full IBAN"

# 6. The ConvertFrom-Json single-element scar (README battle scar): ONE transaction
#    must still count as 1, not unwrap into property soup. General PowerShell behavior,
#    not vendor-specific - still bites Enable Banking's flat array shape.
$txOne = '{"transactions":[{"transaction_amount":{"amount":"-5.00","currency":"EUR"},"booking_date":"2026-07-11"}]}'
$fake1 = @(@{ Name='AIB'; Iban='IE00XXXX1111'; Currency='EUR'; Balances=($balJson|ConvertFrom-Json); Transactions=($txOne|ConvertFrom-Json) })
$s1 = Format-BankSummary $fake1
Assert ($s1.accounts[0].last30d.txCount -eq 1) "single-transaction account must count exactly 1 (array-unwrap scar)"
Assert ($s1.totals.moneyOut -eq [decimal]5.00) "single-transaction sum must be correct"

# 7. This codebase must NEVER call the payment-initiation side of this API in actual code (Safety
#    rule 1: Jarvis never initiates transfers/payments). Comments are allowed to explain the
#    guarantee (as this file's own header does) - only executable lines are checked.
foreach ($f in @("$PSScriptRoot\..\skill\bin\get-bank-data.ps1", "$PSScriptRoot\..\skill\bin\setup-bank.ps1")) {
  $codeLines = (Get-Content $f) | Where-Object { $_.Trim() -notmatch '^#' } | ForEach-Object { $_ -replace '#.*$', '' }
  Assert (-not (($codeLines -join "`n") -match '/payments')) "$(Split-Path $f -Leaf) must never call the /payments endpoint in code (read-only guarantee)"
}

# 8. Repo battle scar: new .ps1 files must be pure ASCII.
foreach ($f in @("$PSScriptRoot\..\skill\bin\get-bank-data.ps1", "$PSScriptRoot\..\skill\bin\setup-bank.ps1")) {
  Assert (Test-Path $f) "$f must exist"
  $bytes = [IO.File]::ReadAllBytes($f)
  $bad = 0; for ($i=0; $i -lt $bytes.Length; $i++){ if ($bytes[$i] -gt 127){ $bad++ } }
  Assert ($bad -eq 0) "$(Split-Path $f -Leaf) must be pure ASCII (found $bad non-ASCII bytes)"
}

Write-Host "get-bank-data: ALL PASS"
