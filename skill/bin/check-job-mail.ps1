# skill/bin/check-job-mail.ps1
# Reads recent Gmail INBOX headers via IMAP (app password from ~/.jarvis/gmail.cred.xml) and
# reports job-alert emails (LinkedIn, Indeed, gradireland, ...). SENDER + SUBJECT + DATE ONLY,
# never bodies (Jarvis Safety rule 5). Works headless: no claude.ai connector involved.
# Usage: powershell -File check-job-mail.ps1 [-SinceHours 24] [-SenderFilter 'linkedin|indeed|gradireland']
param(
  [int]$SinceHours = 24,
  [string]$SenderFilter = 'linkedin|indeed|gradireland|glassdoor|jobs\.ie|irishjobs|mastercard|workday|myworkday',
  [int]$MaxMessages = 40,
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'

function Read-ImapUntil {
  param([IO.StreamReader]$Reader, [string]$Tag, [int]$TimeoutSec = 20)
  $lines = New-Object System.Collections.Generic.List[string]
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $line = $Reader.ReadLine()
    if ($null -eq $line) { break }
    $lines.Add($line)
    if ($line -match "^$([regex]::Escape($Tag)) (OK|NO|BAD)") { return ,$lines }
  }
  throw "IMAP timeout/EOF waiting for tag $Tag"
}

function Invoke-ImapCommand {
  param([IO.StreamWriter]$Writer, [IO.StreamReader]$Reader, [string]$Tag, [string]$Command)
  $Writer.WriteLine("$Tag $Command"); $Writer.Flush()
  return Read-ImapUntil -Reader $Reader -Tag $Tag
}

function Decode-MimeHeader {
  # decodes RFC 2047 encoded-words: =?UTF-8?Q?...?= and =?UTF-8?B?...?=
  param([string]$Text)
  if (-not $Text) { return $Text }
  $out = [regex]::Replace($Text, '=\?([^?]+)\?([QqBb])\?([^?]*)\?=', {
    param($m)
    $charset = $m.Groups[1].Value; $enc = $m.Groups[2].Value.ToUpper(); $payload = $m.Groups[3].Value
    try {
      $encoding = [Text.Encoding]::GetEncoding($charset)
      if ($enc -eq 'B') { return $encoding.GetString([Convert]::FromBase64String($payload)) }
      $payload = $payload -replace '_', ' '
      $bytes = New-Object System.Collections.Generic.List[byte]
      for ($i = 0; $i -lt $payload.Length; $i++) {
        if ($payload[$i] -eq '=' -and $i + 2 -lt $payload.Length) {
          $bytes.Add([Convert]::ToByte($payload.Substring($i + 1, 2), 16)); $i += 2
        } else { $bytes.Add([byte][char]$payload[$i]) }
      }
      return $encoding.GetString($bytes.ToArray())
    } catch { return $m.Value }
  })
  return $out
}

function Get-JobMail {
  param([int]$SinceHours, [string]$SenderFilter, [int]$MaxMessages)
  $credFile = Join-Path $HOME '.jarvis\gmail.cred.xml'
  if (-not (Test-Path $credFile)) { throw "Missing $credFile - run the Gmail app-password setup." }
  $cred = Import-Clixml $credFile
  $user = $cred.UserName
  $pass = $cred.GetNetworkCredential().Password

  $tcp = New-Object Net.Sockets.TcpClient('imap.gmail.com', 993)
  try {
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false)
    $ssl.AuthenticateAsClient('imap.gmail.com')
    $reader = New-Object IO.StreamReader($ssl, [Text.Encoding]::ASCII)
    $writer = New-Object IO.StreamWriter($ssl, [Text.Encoding]::ASCII)
    $null = $reader.ReadLine()   # greeting

    $login = Invoke-ImapCommand $writer $reader 'a1' ("LOGIN `"$user`" `"$pass`"")
    if ($login[-1] -notmatch '^a1 OK') {
      # retry once with spaces stripped (app passwords are shown in spaced groups)
      $login2 = Invoke-ImapCommand $writer $reader 'a1b' ("LOGIN `"$user`" `"$($pass -replace ' ','')`"")
      if ($login2[-1] -notmatch '^a1b OK') { throw "IMAP login failed (check app password)" }
    }

    $null = Invoke-ImapCommand $writer $reader 'a2' 'EXAMINE INBOX'   # read-only select

    $since = (Get-Date).AddHours(-$SinceHours).ToString('dd-MMM-yyyy', [Globalization.CultureInfo]::InvariantCulture)
    $search = Invoke-ImapCommand $writer $reader 'a3' ("SEARCH SINCE $since")
    $idLine = ($search | Where-Object { $_ -match '^\* SEARCH' } | Select-Object -First 1)
    $ids = @()
    if ($idLine) { $ids = @(($idLine -replace '^\* SEARCH\s*', '') -split '\s+' | Where-Object { $_ -match '^\d+$' }) }
    if ($ids.Count -gt $MaxMessages) { $ids = $ids[-$MaxMessages..-1] }

    $mails = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
      $fetch = Invoke-ImapCommand $writer $reader "a4$id" ("FETCH $id (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
      $from = ''; $subj = ''; $date = ''
      foreach ($l in $fetch) {
        if ($l -match '^(?i)From:\s*(.+)$')    { $from = $Matches[1].Trim() }
        elseif ($l -match '^(?i)Subject:\s*(.+)$') { $subj = $Matches[1].Trim() }
        elseif ($l -match '^(?i)Date:\s*(.+)$')    { $date = $Matches[1].Trim() }
      }
      if ($from) { $mails.Add([pscustomobject]@{ From = (Decode-MimeHeader $from); Subject = (Decode-MimeHeader $subj); Date = $date }) }
    }
    $null = Invoke-ImapCommand $writer $reader 'a9' 'LOGOUT'

    $alerts = @($mails | Where-Object { $_.From -match $SenderFilter -or $_.Subject -match $SenderFilter })
    return [pscustomobject]@{
      CheckedAt   = (Get-Date).ToString('s')
      SinceHours  = $SinceHours
      RecentCount = $mails.Count
      JobAlerts   = $alerts
    }
  } finally { $tcp.Close() }
}

if ($DotSourceOnly) { return }
Get-JobMail -SinceHours $SinceHours -SenderFilter $SenderFilter -MaxMessages $MaxMessages | ConvertTo-Json -Depth 4
