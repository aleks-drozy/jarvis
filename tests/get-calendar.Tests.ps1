# tests/get-calendar.Tests.ps1 - ICS parsing + recurrence, using a synthetic fixture (no network)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\get-calendar.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

# fixture built around a fixed reference day: Wednesday 2026-07-15
$day = [datetime]::ParseExact('2026-07-15','yyyy-MM-dd',$null)   # a Wednesday
$ics = @"
BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:One-off today
DTSTART:20260715T100000
DTEND:20260715T110000
END:VEVENT
BEGIN:VEVENT
SUMMARY:One-off tomorrow
DTSTART:20260716T100000
END:VEVENT
BEGIN:VEVENT
SUMMARY:Weekly judo
DTSTART;TZID=Europe/Dublin:20260401T180000
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR
END:VEVENT
BEGIN:VEVENT
SUMMARY:Weekly but excluded today
DTSTART:20260401T090000
RRULE:FREQ=WEEKLY;BYDAY=WE
EXDATE:20260715T090000
END:VEVENT
BEGIN:VEVENT
SUMMARY:All-day today
DTSTART;VALUE=DATE:20260715
END:VEVENT
BEGIN:VEVENT
SUMMARY:Weekly ended in June
DTSTART:20260401T120000
RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260630T000000Z
END:VEVENT
END:VCALENDAR
"@

$events = Get-TodayEvents -Text $ics -Day $day
$names = @($events | ForEach-Object { $_.Summary })

Assert ($names -contains 'One-off today') "one-off event on the day must appear"
Assert (-not ($names -contains 'One-off tomorrow')) "tomorrow's event must not appear"
Assert ($names -contains 'Weekly judo') "WEEKLY BYDAY=WE must occur on a Wednesday"
Assert (-not ($names -contains 'Weekly but excluded today')) "EXDATE for the day must exclude"
Assert ($names -contains 'All-day today') "all-day event must appear"
Assert (-not ($names -contains 'Weekly ended in June')) "UNTIL in the past must exclude"
$judo = $events | Where-Object { $_.Summary -eq 'Weekly judo' }
Assert ($judo.Start -eq '18:00') "recurring event keeps its clock time (got $($judo.Start))"

Write-Host "get-calendar: ALL PASS"
