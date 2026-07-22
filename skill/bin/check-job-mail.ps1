# skill/bin/check-job-mail.ps1
# Reads recent Gmail INBOX headers via IMAP (app password from ~/.jarvis/gmail.cred.xml) and
# reports job-alert emails (LinkedIn, Indeed, Workable, CodeSignal, ...). SENDER + SUBJECT + DATE
# ONLY, never bodies (Jarvis Safety rule 5). Works headless: no claude.ai connector involved.
# Usage: powershell -File check-job-mail.ps1 [-SinceHours 24] [-SenderFilter 'linkedin|indeed|workable']
# Omit -SenderFilter to use the full shared filter ($script:JarvisJobSenderFilter, defined below -
# job boards, ATS platforms, assessment platforms, tracked employers). An explicit -SenderFilter
# always overrides it.
param(
  [int]$SinceHours = 24,
  # empty by default: resolved to $script:JarvisJobSenderFilter at call time unless overridden below
  [string]$SenderFilter = '',
  # sensitive categories are counted but never itemised (Jarvis Safety rule 5)
  [string]$SensitiveFilter = 'bank|revolut|paypal|stripe|payment|invoice|statement|transaction|medical|doctor|clinic|prescription|verification code|2fa|one.?time|passcode|password|security alert',
  [ValidateSet('jobs','inbox','both')][string]$Mode = 'jobs',
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

# THE SENDER FILTER. One definition, shared by every caller, because it drifted once and cost a miss.
#
# 2026-07-20: Learnosity rejected Alex through WORKABLE and Jarvis never reported it. The classifier
# below would have tagged it correctly - it was simply never shown the message, because 'workable' was
# not in this list. The same gap means a CodeSignal assessment invite is invisible, which is how the
# 2026-07-10 Susquehanna invite expired unactioned: the only door that opened in 44 applications.
#
# Widening this widens what Jarvis SEES, not what it READS. Safety 5 is unchanged: sender + subject +
# date, never bodies.
$script:JarvisJobSenderFilter = @(
  # job boards and aggregators
  'linkedin','indeed','gradireland','glassdoor','jobs\.ie','irishjobs','jooble','adzuna',
  # applicant tracking systems - where the actual decisions arrive from
  'workday','myworkday','greenhouse','lever\.co','workable','smartrecruiters','teamtailor',
  # 'ashby' already matches 'ashbyhq.com' (the real Ashby sender domain) as a substring, so a
  # separate 'ashbyhq' entry was redundant and removed. 'harri' is anchored to its real domain
  # (harri.com) so it does not also catch harrison@/harriet@/harrington@-style senders.
  'ashby','icims','taleo','successfactors','rezoomo','harri\.com','amris','pinpointhq',
  # assessment platforms - the time-limited ones, the reason this list was widened
  'codesignal','hackerrank','codility','karat','hirevue','testgorilla','coderbyte','devskiller',
  # employers already in the tracker
  'mastercard','maynooth','nuim\.ie','vodafone'
) -join '|'

function Resolve-JobSenderFilter {
  # The ONE place a caller's -SenderFilter is reconciled with the shared filter above. An explicit,
  # non-empty override always wins; otherwise every caller (this script's own standalone entry point,
  # telegram-bot.ps1, or a future caller) falls back to $script:JarvisJobSenderFilter. This is what
  # keeps it to one real definition - the param() default below is deliberately empty, not a second
  # copy of the list, so it cannot drift out of sync with the shared filter again.
  param([string]$SenderFilter)
  if ($SenderFilter) { return $SenderFilter }
  return $script:JarvisJobSenderFilter
}

function Classify-JobMailSubject {
  # Coarse application-status guess from the SUBJECT LINE ALONE (headers only - Safety 5; bodies never
  # read). Precedence: digest -> rejection -> interview -> offer -> generic. Subject-only is imperfect
  # (an ambiguous "Update on your application" reads 'generic'), so the downstream policy is
  # flag-and-confirm in the debrief - never a silent tracker write.
  param([string]$Subject)
  if (-not $Subject) { return 'generic' }
  $s = $Subject
  $digest    = 'job alert|jobs? for you|new jobs?|\d+\+? (new )?jobs?|recommended for you|jobs? matching|weekly (jobs|digest)|interview tips|career tips|newsletter'
  $rejection = 'unfortunately|regret to inform|not been (successful|shortlisted|selected)|(was|were) not successful|not successful on this occasion|other candidates|not (moving|proceeding|progressing) (forward|with)|will not be (moving|proceeding|progressing)|decided not to (move|proceed|progress)|no longer under consideration|not shortlisted|unsuccessful'
  $interview = 'interview|phone screen|schedule (a|your) (call|time|chat)|book a (time|slot|call)|next steps|next stage|(technical|coding|online) (test|challenge|assessment)|assessment|invitation to|invite you to|availability (for|to)|meet the team|first round|final round'
  $offer     = 'offer of employment|job offer|offer letter|pleased to offer you|delighted to offer you|formal offer|would like to offer you the'
  if ($s -imatch $digest)    { return 'generic' }
  if ($s -imatch $rejection) { return 'rejection' }
  if ($s -imatch $interview) { return 'interview' }
  if ($s -imatch $offer)     { return 'offer' }
  return 'generic'
}

function Add-JobMailClassification {
  # Tags each alert object in place with a Classification note-property from its subject.
  param([object[]]$Alerts)
  foreach ($a in $Alerts) {
    $a | Add-Member -NotePropertyName Classification -NotePropertyValue (Classify-JobMailSubject $a.Subject) -Force
  }
  return $Alerts
}

function Get-JobMail {
  param([int]$SinceHours, [string]$SenderFilter, [int]$MaxMessages,
        [string]$SensitiveFilter = '', [string]$Mode = 'jobs')
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

    # unread count (whole inbox, not window-limited)
    $unseen = Invoke-ImapCommand $writer $reader 'a2b' 'SEARCH UNSEEN'
    $unseenLine = ($unseen | Where-Object { $_ -match '^\* SEARCH' } | Select-Object -First 1)
    $unreadCount = 0
    if ($unseenLine) { $unreadCount = @(($unseenLine -replace '^\* SEARCH\s*', '') -split '\s+' | Where-Object { $_ -match '^\d+$' }).Count }

    $since = (Get-Date).AddHours(-$SinceHours).ToString('dd-MMM-yyyy', [Globalization.CultureInfo]::InvariantCulture)
    $search = Invoke-ImapCommand $writer $reader 'a3' ("SEARCH SINCE $since")
    $idLine = ($search | Where-Object { $_ -match '^\* SEARCH' } | Select-Object -First 1)
    $ids = @()
    if ($idLine) { $ids = @(($idLine -replace '^\* SEARCH\s*', '') -split '\s+' | Where-Object { $_ -match '^\d+$' }) }
    if ($ids.Count -gt $MaxMessages) { $ids = $ids[-$MaxMessages..-1] }

    $mails = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
      $fetch = Invoke-ImapCommand $writer $reader "a4$id" ("FETCH $id (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
      # unfold RFC 5322 folded headers: continuation lines start with space/tab
      $unfolded = New-Object System.Collections.Generic.List[string]
      foreach ($l in $fetch) {
        if ($l -match '^[ \t]+' -and $unfolded.Count -gt 0) {
          $unfolded[$unfolded.Count - 1] = $unfolded[$unfolded.Count - 1] + ' ' + $l.Trim()
        } else { $unfolded.Add($l) }
      }
      $from = ''; $subj = ''; $date = ''
      foreach ($l in $unfolded) {
        if ($l -match '^(?i)From:\s*(.+)$')    { $from = $Matches[1].Trim() }
        elseif ($l -match '^(?i)Subject:\s*(.+)$') { $subj = $Matches[1].Trim() }
        elseif ($l -match '^(?i)Date:\s*(.+)$')    { $date = $Matches[1].Trim() }
      }
      if ($from) { $mails.Add([pscustomobject]@{ From = (Decode-MimeHeader $from); Subject = (Decode-MimeHeader $subj); Date = $date }) }
    }
    $null = Invoke-ImapCommand $writer $reader 'a9' 'LOGOUT'

    $alerts = @($mails | Where-Object { $_.From -match $SenderFilter -or $_.Subject -match $SenderFilter })
    $alerts = @(Add-JobMailClassification $alerts)   # tag each with interview/rejection/offer/generic
    $result = [ordered]@{
      CheckedAt   = (Get-Date).ToString('s')
      SinceHours  = $SinceHours
      RecentCount = $mails.Count
    }
    if ($Mode -in @('jobs','both'))  { $result.JobAlerts = $alerts }
    if ($Mode -in @('inbox','both')) {
      $sensitive = @(); $notable = @()
      if ($SensitiveFilter) {
        $sensitive = @($mails | Where-Object { $_.From -match $SensitiveFilter -or $_.Subject -match $SensitiveFilter })
      }
      $notable = @($mails | Where-Object { $sensitive -notcontains $_ -and $alerts -notcontains $_ } | Select-Object -Last 8)
      $result.UnreadCount    = $unreadCount
      $result.Notable        = $notable          # sender+subject only, never bodies
      $result.SensitiveCount = $sensitive.Count  # counted, never itemised (Safety 5)
    }
    return [pscustomobject]$result
  } finally { $tcp.Close() }
}

if ($DotSourceOnly) { return }
$effectiveSenderFilter = Resolve-JobSenderFilter -SenderFilter $SenderFilter
Get-JobMail -SinceHours $SinceHours -SenderFilter $effectiveSenderFilter -MaxMessages $MaxMessages `
  -SensitiveFilter $SensitiveFilter -Mode $Mode | ConvertTo-Json -Depth 4
