# skill/bin/get-calendar.ps1
# Fetches Google Calendar via the SECRET iCal address (no connector, works headless) and emits
# today's events as JSON. Handles basic recurrence (DAILY / WEEKLY BYDAY / MONTHLY / YEARLY) and
# EXDATE exclusions; UNTIL respected, COUNT ignored (rare for personal calendars).
# Setup (one time): Google Calendar > Settings > your calendar > Integrate calendar >
#   copy "Secret address in iCal format", then:
#     $u = Read-Host 'Paste secret iCal URL' -AsSecureString
#     New-Object System.Management.Automation.PSCredential('ics', $u) | Export-Clixml $HOME\.jarvis\gcal-ics.xml
param(
  [string]$IcsFile,          # tests: parse a local .ics instead of fetching
  [string]$OnDate,           # tests: 'yyyy-MM-dd' to evaluate a specific day (default today)
  [switch]$DotSourceOnly
)
$ErrorActionPreference = 'Stop'

function Get-IcsText {
  param([string]$IcsFile)
  if ($IcsFile) { return (Get-Content -LiteralPath $IcsFile -Raw) }
  $f = Join-Path $HOME '.jarvis\gcal-ics.xml'
  if (-not (Test-Path $f)) { throw "No secret iCal URL at $f - see setup in this script's header." }
  $url = (Import-Clixml $f).GetNetworkCredential().Password
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  return (Invoke-WebRequest -Uri $url -TimeoutSec 30 -UseBasicParsing).Content
}

function Parse-IcsDate {
  param([string]$Value)
  $v = $Value.Trim()
  if ($v -match '^\d{8}$') { return @{ Date = [datetime]::ParseExact($v, 'yyyyMMdd', $null); AllDay = $true } }
  if ($v -match '^(\d{8}T\d{6})Z$') {
    $utc = [datetime]::ParseExact($Matches[1], "yyyyMMdd'T'HHmmss", $null)
    return @{ Date = [datetime]::SpecifyKind($utc, 'Utc').ToLocalTime(); AllDay = $false }
  }
  if ($v -match '^(\d{8}T\d{6})$') {
    return @{ Date = [datetime]::ParseExact($Matches[1], "yyyyMMdd'T'HHmmss", $null); AllDay = $false }
  }
  return $null
}

function Parse-Ics {
  param([string]$Text)
  # unfold folded lines (RFC 5545: continuation lines start with space/tab)
  $lines = $Text -split "`r?`n"
  $unfolded = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) {
    if ($l -match '^[ \t]' -and $unfolded.Count -gt 0) { $unfolded[$unfolded.Count - 1] += $l.Substring(1) }
    else { $unfolded.Add($l) }
  }
  $events = New-Object System.Collections.Generic.List[object]
  $cur = $null
  foreach ($l in $unfolded) {
    if ($l -eq 'BEGIN:VEVENT') { $cur = @{ Summary=''; Start=$null; End=$null; AllDay=$false; RRule=''; ExDates=@() }; continue }
    if ($l -eq 'END:VEVENT') { if ($cur -and $cur.Start) { $events.Add([pscustomobject]$cur) }; $cur = $null; continue }
    if ($null -eq $cur) { continue }
    if ($l -match '^SUMMARY(?:;[^:]*)?:(.*)$') { $cur.Summary = $Matches[1].Trim() }
    elseif ($l -match '^DTSTART(?:;[^:]*)?:(.+)$') {
      $p = Parse-IcsDate $Matches[1]; if ($p) { $cur.Start = $p.Date; $cur.AllDay = $p.AllDay }
    }
    elseif ($l -match '^DTEND(?:;[^:]*)?:(.+)$') {
      $p = Parse-IcsDate $Matches[1]; if ($p) { $cur.End = $p.Date }
    }
    elseif ($l -match '^RRULE:(.+)$') { $cur.RRule = $Matches[1].Trim() }
    elseif ($l -match '^EXDATE(?:;[^:]*)?:(.+)$') {
      foreach ($x in ($Matches[1] -split ',')) { $p = Parse-IcsDate $x; if ($p) { $cur.ExDates += $p.Date.Date } }
    }
  }
  return $events
}

function Test-OccursOn {
  param($Event, [datetime]$Day)
  $d = $Day.Date
  if ($Event.ExDates -contains $d) { return $false }
  if (-not $Event.RRule) { return ($Event.Start.Date -eq $d) }
  if ($Event.Start.Date -gt $d) { return $false }
  $rules = @{}
  foreach ($part in ($Event.RRule -split ';')) { $kv = $part -split '=', 2; if ($kv.Count -eq 2) { $rules[$kv[0]] = $kv[1] } }
  if ($rules['UNTIL']) { $u = Parse-IcsDate $rules['UNTIL']; if ($u -and $d -gt $u.Date.Date) { return $false } }
  $bydayMap = @{ MO='Monday'; TU='Tuesday'; WE='Wednesday'; TH='Thursday'; FR='Friday'; SA='Saturday'; SU='Sunday' }
  switch ($rules['FREQ']) {
    'DAILY'   { return $true }
    'WEEKLY'  {
      if ($rules['BYDAY']) {
        foreach ($code in ($rules['BYDAY'] -split ',')) {
          $code2 = $code -replace '^[+-]?\d+', ''   # strip ordinal prefixes like 2MO
          if ($bydayMap[$code2] -eq $d.DayOfWeek.ToString()) { return $true }
        }
        return $false
      }
      return ($Event.Start.DayOfWeek -eq $d.DayOfWeek)
    }
    'MONTHLY' {
      if ($rules['BYMONTHDAY']) { return (($rules['BYMONTHDAY'] -split ',') -contains [string]$d.Day) }
      return ($Event.Start.Day -eq $d.Day)
    }
    'YEARLY'  { return ($Event.Start.Month -eq $d.Month -and $Event.Start.Day -eq $d.Day) }
    default   { return $false }
  }
}

function Get-TodayEvents {
  param([string]$Text, [datetime]$Day)
  $all = Parse-Ics -Text $Text
  $hits = @($all | Where-Object { Test-OccursOn -Event $_ -Day $Day } | ForEach-Object {
    $startStr = if ($_.AllDay) { 'all day' } else {
      # recurring timed events keep their original clock time on each occurrence
      $_.Start.ToString('HH:mm')
    }
    $endStr = if ($_.End -and -not $_.AllDay) { $_.End.ToString('HH:mm') } else { '' }
    [pscustomobject]@{ Summary = $_.Summary; Start = $startStr; End = $endStr; AllDay = $_.AllDay }
  } | Sort-Object @{ Expression = { if ($_.AllDay) { '00:00' } else { $_.Start } } })
  return $hits
}

if ($DotSourceOnly) { return }

$day = if ($OnDate) { [datetime]::ParseExact($OnDate, 'yyyy-MM-dd', $null) } else { Get-Date }
$text = Get-IcsText -IcsFile $IcsFile
$events = Get-TodayEvents -Text $text -Day $day
[pscustomobject]@{
  Date   = $day.ToString('yyyy-MM-dd')
  Count  = $events.Count
  Events = @($events)
} | ConvertTo-Json -Depth 4
