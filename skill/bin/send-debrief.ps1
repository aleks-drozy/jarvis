# skill/bin/send-debrief.ps1
# Sends today's debrief note to Alex via Gmail SMTP (app password from a DPAPI-encrypted PSCredential).
# Recipient defaults to Alex's own address and must stay self-only — Safety rule 2.
param(
  [string]$NotePath,
  [string]$ToAddress = 'aleksandrs.drozdovs2005@gmail.com',
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'

function Build-DebriefMail {
  param([string]$NotePath, [string]$ToAddress)
  $body = Get-Content -LiteralPath $NotePath -Raw
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
  param([string]$NotePath, [string]$ToAddress)
  $mail = Build-DebriefMail -NotePath $NotePath -ToAddress $ToAddress
  $cred = Get-AppPassword
  Send-MailMessage -From $cred.UserName -To $mail.To -Subject $mail.Subject -Body $mail.Body `
    -SmtpServer 'smtp.gmail.com' -Port 587 -UseSsl -Credential $cred
}

if ($DotSourceOnly) { return }
if (-not $NotePath) { throw "-NotePath required" }
Send-Debrief -NotePath $NotePath -ToAddress $ToAddress
Write-Host "Debrief emailed to $ToAddress"
