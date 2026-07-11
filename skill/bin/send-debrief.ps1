# skill/bin/send-debrief.ps1
# Sends today's debrief note to Alex via Gmail SMTP (app password from a DPAPI-encrypted PSCredential).
# Recipient is LOCKED to Alex's own address — Safety rule 2 (self-only), enforced in code below.
param(
  [string]$NotePath,
  [string]$ToAddress,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'
$OwnerEmail = 'aleksandrs.drozdovs2005@gmail.com'   # Safety rule 2: the ONLY permitted recipient

function Build-DebriefMail {
  param([string]$NotePath, [string]$ToAddress)
  $body = Get-Content -LiteralPath $NotePath -Raw -Encoding UTF8
  # strip the YAML frontmatter block so the email opens at the greeting, not "--- project: ..."
  $body = [regex]::Replace($body, '(?s)\A\s*---\r?\n.*?\r?\n---\r?\n', '').TrimStart()
  $date = [IO.Path]::GetFileNameWithoutExtension($NotePath)
  return @{ To = $ToAddress; Subject = "[JARVIS] Morning debrief - $date"; Body = $body }
}

function Get-AppPassword {
  # PSCredential (username = Gmail address, password = app password), DPAPI-encrypted to this Windows user.
  $credFile = Join-Path $HOME '.jarvis\gmail.cred.xml'
  if (-not (Test-Path $credFile)) { throw "Missing $credFile - run the Gmail app-password setup (Task B2 Step 1)." }
  return (Import-Clixml $credFile)
}

function Send-Debrief {
  param([string]$NotePath, [string]$ToAddress = $OwnerEmail)
  # Safety rule 2 (self-only): refuse ANY recipient other than the owner, BEFORE reading the
  # credential or touching the network. A prompt-injected Jarvis must not be able to exfiltrate.
  if ($ToAddress -ne $OwnerEmail) {
    throw "Safety rule 2 (self-only): refusing to email '$ToAddress' - recipient is locked to $OwnerEmail."
  }
  $mail = Build-DebriefMail -NotePath $NotePath -ToAddress $ToAddress
  $cred = Get-AppPassword
  Send-MailMessage -From $cred.UserName -To $mail.To -Subject $mail.Subject -Body $mail.Body `
    -SmtpServer 'smtp.gmail.com' -Port 587 -UseSsl -Credential $cred -Encoding ([System.Text.Encoding]::UTF8)
}

if ($DotSourceOnly) { return }
if (-not $NotePath) { throw "-NotePath required" }
if (-not $ToAddress) { $ToAddress = $OwnerEmail }   # single source of truth for the recipient
Send-Debrief -NotePath $NotePath -ToAddress $ToAddress
Write-Host "Debrief emailed to $ToAddress"
