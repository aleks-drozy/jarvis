# skill/bin/get-picovoice-key.ps1
# Reads (or stores) the Picovoice AccessKey for the "Jarvis" wake word. The key is DPAPI-encrypted at
# ~/.jarvis/picovoice.cred.xml, never in the repo or vault (Safety rule 6). A free personal AccessKey
# comes from console.picovoice.ai. ASCII only (PS 5.1 reads .ps1 as ANSI).
#
#   Store:  powershell -File get-picovoice-key.ps1 -StoreCredential      (paste the key when prompted)
#   Read :  powershell -File get-picovoice-key.ps1                       -> { "accessKey": "..." }
# The desktop app calls the read form (only when CONFIG wake_word: on) to arm the wake word.
param(
  [switch]$StoreCredential, [string]$Key,
  [switch]$DotSourceOnly,
  [string]$CredPath = (Join-Path $HOME '.jarvis\picovoice.cred.xml')
)
$ErrorActionPreference = 'Stop'
if ($DotSourceOnly) { return }

if ($StoreCredential) {
  if (-not $Key) {
    $sec = Read-Host -AsSecureString 'Paste your Picovoice AccessKey'
    $Key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  }
  $dir = Split-Path $CredPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $sec = ConvertTo-SecureString $Key -AsPlainText -Force
  New-Object System.Management.Automation.PSCredential('picovoice', $sec) | Export-Clixml $CredPath
  Write-Host "Stored (DPAPI-encrypted to this Windows user): $CredPath"
  Write-Host 'Next: vendor the Porcupine web files (see the repo README "Optional integrations" section) and set CONFIG wake_word: on.'
  exit 0
}

if (-not (Test-Path $CredPath)) { '{}'; exit 0 }   # no key yet -> app reads no accessKey, stays off
$cred = Import-Clixml $CredPath
@{ accessKey = $cred.GetNetworkCredential().Password } | ConvertTo-Json -Compress
