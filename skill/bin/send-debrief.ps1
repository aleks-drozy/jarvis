# skill/bin/send-debrief.ps1
# Sends today's debrief note to Alex via Gmail SMTP (app password from a DPAPI-encrypted PSCredential).
# Recipient is LOCKED to Alex's own address - Safety rule 2 (self-only), enforced in code below.
param(
  [string]$NotePath,
  [string]$ToAddress,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'
$OwnerEmail = 'aleksandrs.drozdovs2005@gmail.com'   # Safety rule 2: the ONLY permitted recipient

function Get-LatenessNote {
  # Design 8 honesty stamp: null when the run started on schedule (within grace); otherwise a
  # one-line factual stamp naming the actual time AND the cause. BootTime after the scheduled
  # moment proves the machine was powered off at 08:30 (a shutdown defeats the wake timer -
  # witnessed 2026-07-14); otherwise it was asleep/logged off and caught up at logon.
  #
  # -OnDemand: this run was explicitly requested (Telegram /debrief, the tray's "Debrief now"), so it is
  # NOT the 08:30 run and must not be judged against it. Stamping a briefing Alex asked for at 10:40 as
  # a "late catch-up ... the machine was powered off at 08:30" puts a false claim in his own notes.
  # The default deliberately stays "judge it": if a caller forgets the flag the worst case is a spurious
  # stamp (harmless noise), whereas defaulting the other way would silently drop the honesty stamp - and
  # that stamp exists precisely so a missed morning cannot masquerade as a quiet one.
  param([datetime]$RunStart, [datetime]$BootTime = [datetime]::MinValue,
        [string]$ScheduledAt = '08:30', [int]$GraceMinutes = 10, [switch]$OnDemand)
  if ($OnDemand) { return $null }
  $sched = [datetime]::ParseExact($RunStart.ToString('yyyy-MM-dd') + ' ' + $ScheduledAt,
    'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
  if ($RunStart -le $sched.AddMinutes($GraceMinutes)) { return $null }
  $hhmm = $RunStart.ToString('HH:mm')
  if ($BootTime -gt $sched) {
    return "Generated late at $hhmm - the machine was powered off at $ScheduledAt (a shutdown defeats the wake timer; sleep it instead, Sir). Catch-up run."
  }
  return "Generated late at $hhmm - the machine was asleep or logged off at $ScheduledAt and the wake timer did not fire. Catch-up or manual re-run."
}

function Build-DebriefMail {
  param([string]$NotePath, [string]$ToAddress,
        [datetime]$RunStart = [datetime]::MinValue, [datetime]$BootTime = [datetime]::MinValue,
        [switch]$OnDemand)
  $body = Get-Content -LiteralPath $NotePath -Raw -Encoding UTF8
  # strip the YAML frontmatter block so the email opens at the greeting, not "--- project: ..."
  $body = [regex]::Replace($body, '(?s)\A\s*---\r?\n.*?\r?\n---\r?\n', '').TrimStart()
  $date = [IO.Path]::GetFileNameWithoutExtension($NotePath)
  $subject = "[JARVIS] Morning debrief - $date"
  # Late catch-up is flagged in the subject so a missed 08:30 is loud in the inbox, not invisible.
  if ($RunStart -ne [datetime]::MinValue) {
    if (Get-LatenessNote -RunStart $RunStart -BootTime $BootTime -OnDemand:$OnDemand) {
      $subject = $subject + ' (late ' + $RunStart.ToString('HH:mm') + ')'
    }
  }
  return @{ To = $ToAddress; Subject = $subject; Body = $body }
}

function Get-AppPassword {
  # PSCredential (username = Gmail address, password = app password), DPAPI-encrypted to this Windows user.
  $credFile = Join-Path $HOME '.jarvis\gmail.cred.xml'
  if (-not (Test-Path $credFile)) { throw "Missing $credFile - run the Gmail app-password setup (Task B2 Step 1)." }
  return (Import-Clixml $credFile)
}

function Send-Debrief {
  param([string]$NotePath, [string]$ToAddress = $OwnerEmail,
        [datetime]$RunStart = [datetime]::MinValue, [datetime]$BootTime = [datetime]::MinValue,
        [switch]$OnDemand)
  # Safety rule 2 (self-only): refuse ANY recipient other than the owner, BEFORE reading the
  # credential or touching the network. A prompt-injected Jarvis must not be able to exfiltrate.
  if ($ToAddress -ne $OwnerEmail) {
    throw "Safety rule 2 (self-only): refusing to email '$ToAddress' - recipient is locked to $OwnerEmail."
  }
  $mail = Build-DebriefMail -NotePath $NotePath -ToAddress $ToAddress -RunStart $RunStart -BootTime $BootTime -OnDemand:$OnDemand
  $cred = Get-AppPassword
  Send-MailMessage -From $cred.UserName -To $mail.To -Subject $mail.Subject -Body $mail.Body `
    -SmtpServer 'smtp.gmail.com' -Port 587 -UseSsl -Credential $cred -Encoding ([System.Text.Encoding]::UTF8)
}

if ($DotSourceOnly) { return }
if (-not $NotePath) { throw "-NotePath required" }
if (-not $ToAddress) { $ToAddress = $OwnerEmail }   # single source of truth for the recipient
Send-Debrief -NotePath $NotePath -ToAddress $ToAddress
Write-Host "Debrief emailed to $ToAddress"
