# skill/bin/setup-bank.ps1
# Phase 3 one-time setup for Enable Banking - RUN BY ALEX in a normal terminal, never headless.
# Jarvis is not permitted to create accounts or perform bank consent (skill Safety rules); this
# script only generates a local keypair, prepares credentials/state, and PRINTS the consent link
# for Alex to open himself. Run this script with no switches to print the ordered checklist.
#
# Usage (in order):
#   setup-bank.ps1 -GenerateKeypair
#     -> writes a private key (kept local, never uploaded) + a public certificate (upload this one)
#   setup-bank.ps1 -StoreCredential -ApplicationId <uuid>
#     -> <uuid> is shown by the Enable Banking control panel after you upload the certificate
#   setup-bank.ps1 -ListBanks [-Country IE]
#   setup-bank.ps1 -NewSession -AspspName "Revolut" -AspspCountry IE
#     -> prints the consent link; open it, approve at your bank
#   setup-bank.ps1 -ExchangeCode -Code <code> -State <state>
#     -> paste these from the (broken-looking, expected) localhost redirect URL's query string
#   setup-bank.ps1 -CheckSession
param(
  [switch]$GenerateKeypair,
  [switch]$StoreCredential, [string]$ApplicationId,
  [switch]$ListBanks, [string]$Country = 'IE',
  [switch]$NewSession, [string]$AspspName, [string]$AspspCountry = 'IE', [int]$ValidDays = 90,
  [string]$RedirectUrl = 'https://localhost/jarvis-bank-consent-done',
  [switch]$ExchangeCode, [string]$Code, [string]$State,
  [switch]$CheckSession,
  [switch]$DotSourceOnly,
  [string]$CredPath    = (Join-Path $HOME '.jarvis\enablebanking.cred.xml'),
  [string]$StatePath   = (Join-Path $HOME '.jarvis\bank.json'),
  [string]$PendingPath = (Join-Path $HOME '.jarvis\bank-pending.json'),
  [string]$KeyDir      = (Join-Path $HOME '.jarvis')
)
$ErrorActionPreference = 'Stop'

# Reuse Get-OpenSslPath/New-EnableBankingJwt/Invoke-EBApi/$ApiBase from the collector. Dot-sourcing
# rebinds its param defaults into this scope, so capture our own paths first and restore after.
$myCred = $CredPath; $myState = $StatePath
. "$PSScriptRoot\get-bank-data.ps1" -DotSourceOnly
$CredPath = $myCred; $StatePath = $myState

function Get-ConsentDate { param([string]$ValidUntil) if (-not $ValidUntil) { return $null }; return ($ValidUntil -replace 'T.*$', '') }
if ($DotSourceOnly) { return }

if (-not (Test-Path $KeyDir)) { New-Item -ItemType Directory -Force $KeyDir | Out-Null }

if ($GenerateKeypair) {
  $openssl = Get-OpenSslPath
  $privPath = Join-Path $KeyDir 'enablebanking-private.key.tmp'   # plaintext only until -StoreCredential DPAPI-wraps it
  $crtPath  = Join-Path $KeyDir 'enablebanking-public.crt'        # public cert - not a secret, safe to keep
  # openssl writes benign progress lines to stderr (e.g. "writing RSA key"); discard rather than
  # 2>&1, which would wrap each into a terminating ErrorRecord under 'Stop' even on exit 0.
  & $openssl genrsa -out $privPath 2048 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "openssl genrsa failed (exit $LASTEXITCODE)" }
  & $openssl req -new -x509 -days 730 -key $privPath -out $crtPath -subj '/C=IE/O=Personal/CN=jarvis-personal-project' 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "openssl req failed (exit $LASTEXITCODE)" }
  Write-Host ''
  Write-Host 'Keypair generated. The PRIVATE key never leaves this machine - only the certificate below gets uploaded.'
  Write-Host "  Certificate to upload: $crtPath"
  Write-Host ''
  Write-Host 'Next: open https://enablebanking.com/ , sign up (free), register a new application,'
  Write-Host 'and upload that certificate. The control panel will show you an Application ID (a UUID).'
  Write-Host 'Then run: setup-bank.ps1 -StoreCredential -ApplicationId <uuid>'
  exit 0
}

if ($StoreCredential) {
  if (-not $ApplicationId) { throw 'need -ApplicationId (the UUID shown by the Enable Banking control panel after certificate upload)' }
  $privPath = Join-Path $KeyDir 'enablebanking-private.key.tmp'
  if (-not (Test-Path $privPath)) { throw "no private key at $privPath - run -GenerateKeypair first" }
  $pem = Get-Content $privPath -Raw
  $sec = ConvertTo-SecureString $pem -AsPlainText -Force
  New-Object System.Management.Automation.PSCredential($ApplicationId, $sec) | Export-Clixml $CredPath
  Write-Host "Stored (DPAPI-encrypted to this Windows user): $CredPath"
  Write-Host 'Secrets never go in the repo or the vault (Safety rule 6).'
  try {
    $jwt = New-EnableBankingJwt -ApplicationId $ApplicationId -PrivateKeyPem $pem
    # country MUST be uppercase - Enable Banking validates against ^[A-Z]{2}$ and 422s on 'ie'
    # (confirmed live 2026-07-14: this bug was masked until the app became active, since the
    # earlier "application not active" 403 fired before parameter validation got a chance to).
    $null = Invoke-EBApi $jwt -Path "/aspsps?country=IE"
    Write-Host 'Auth check: OK. Removing the plaintext key file now that it is DPAPI-stored.'
    Remove-Item $privPath -Force -ErrorAction SilentlyContinue
    Write-Host 'Next: -ListBanks, then -NewSession.'
  } catch {
    Write-Warning "Auth check FAILED: $($_.Exception.Message) - re-check the application id / certificate upload. Plaintext key kept at $privPath for now (retry once fixed)."
  }
  exit 0
}

if ($ListBanks) {
  $cred = Import-Clixml $CredPath
  $jwt = New-EnableBankingJwt -ApplicationId $cred.UserName -PrivateKeyPem $cred.GetNetworkCredential().Password
  $resp = Invoke-EBApi $jwt -Path "/aspsps?country=$Country&psu_type=personal"
  @($resp.aspsps) | Sort-Object name | Select-Object name, country | Format-Table -AutoSize
  Write-Host 'Pick your bank name exactly as shown (Revolut / AIB / Bank of Ireland / Permanent TSB),'
  Write-Host 'then run -NewSession -AspspName "<name>" -AspspCountry <cc>.'
  exit 0
}

if ($NewSession) {
  if (-not $AspspName) { throw 'need -AspspName (find the exact name with -ListBanks)' }
  $cred = Import-Clixml $CredPath
  $jwt = New-EnableBankingJwt -ApplicationId $cred.UserName -PrivateKeyPem $cred.GetNetworkCredential().Password
  $state = 'jarvis-' + [Guid]::NewGuid().ToString('N').Substring(0, 16)
  $validUntil = (Get-Date).AddDays($ValidDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $body = @{
    aspsp = @{ name = $AspspName; country = $AspspCountry }
    access = @{ valid_until = $validUntil }
    redirect_url = $RedirectUrl
    state = $state
    psu_type = 'personal'
  }
  $resp = Invoke-EBApi $jwt -Method 'Post' -Path '/auth' -BodyObj $body
  @{ state = $state; aspsp_name = $AspspName; aspsp_country = $AspspCountry; valid_until = $validUntil; created = (Get-Date).ToString('s') } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $PendingPath
  Write-Host ''
  Write-Host 'OPEN THIS LINK IN YOUR BROWSER and approve READ-ONLY access at your bank:'
  Write-Host ('  ' + $resp.url)
  Write-Host ''
  Write-Host 'The final redirect will look like a broken page (localhost) - that is expected.'
  Write-Host 'Copy the "code" and "state" query parameters from that address bar, then run:'
  Write-Host '  setup-bank.ps1 -ExchangeCode -Code <code> -State <state>'
  exit 0
}

if ($ExchangeCode) {
  if (-not $Code -or -not $State) { throw 'need -Code and -State (copied from the redirect URL after approving at your bank)' }
  if (-not (Test-Path $PendingPath)) { throw "no pending session at $PendingPath - run -NewSession first" }
  $pending = Get-Content $PendingPath -Raw | ConvertFrom-Json
  if ($pending.state -ne $State) { throw "state mismatch - this code does not match the last -NewSession run (expected $($pending.state))" }
  $cred = Import-Clixml $CredPath
  $jwt = New-EnableBankingJwt -ApplicationId $cred.UserName -PrivateKeyPem $cred.GetNetworkCredential().Password
  $resp = Invoke-EBApi $jwt -Method 'Post' -Path '/sessions' -BodyObj @{ code = $Code }
  $accounts = @($resp.accounts) | ForEach-Object { @{ uid = $_.uid; name = $_.name; currency = $_.currency; account_id = $_.account_id } }
  $consentExpires = Get-ConsentDate -ValidUntil $pending.valid_until
  @{ session_id = $resp.session_id; accounts = $accounts; consent_expires = $consentExpires; linked = (Get-Date).ToString('s') } |
    ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $StatePath
  Remove-Item $PendingPath -Force -ErrorAction SilentlyContinue
  Write-Host ("Linked. Accounts: {0}" -f $accounts.Count)
  Write-Host 'Test the feed:   powershell -NoProfile -File skill\bin\get-bank-data.ps1'
  Write-Host 'Then flip CONFIG.md:     modules: finance_bank: on'
  exit 0
}

if ($CheckSession) {
  if (-not (Test-Path $StatePath)) { throw "no session at $StatePath - run -NewSession then -ExchangeCode first" }
  $state = Get-Content $StatePath -Raw | ConvertFrom-Json
  Write-Host ("Linked accounts: {0} (session {1}, linked {2})" -f @($state.accounts).Count, $state.session_id, $state.linked)
  exit 0
}

Write-Host 'Phase 3 bank feed setup for Enable Banking - the full checklist, in order:'
Write-Host '  1. setup-bank.ps1 -GenerateKeypair'
Write-Host '  2. Sign up at enablebanking.com, register an application, upload the printed certificate'
Write-Host '  3. setup-bank.ps1 -StoreCredential -ApplicationId <uuid>'
Write-Host '  4. setup-bank.ps1 -ListBanks'
Write-Host '  5. setup-bank.ps1 -NewSession -AspspName "<name>" -AspspCountry <cc>   (open the printed link, approve)'
Write-Host '  6. setup-bank.ps1 -ExchangeCode -Code <code> -State <state>            (from the redirect URL)'
Write-Host '  7. flip CONFIG.md modules: finance_bank: on'
