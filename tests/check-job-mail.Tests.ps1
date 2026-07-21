# tests/check-job-mail.Tests.ps1 - the job-mail sender filter and subject classifier.
# NO NETWORK: dot-sources check-job-mail.ps1 and exercises the pure parts only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\skill\bin\check-job-mail.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

# --- VACUITY GUARD, must run FIRST. If $JarvisJobSenderFilter is ever undefined (e.g. a typo'd
# --- rename), '-imatch' against $null/'' coerces to an empty pattern that matches EVERYTHING, so
# --- every "must match" assertion below would pass for the wrong reason - only the "must NOT match"
# --- noise assertions would catch it, with a misleading message. Assert real presence and content
# --- before any pattern-matching loop runs, so a broken filter fails loudly and specifically here.
Assert (Test-Path Variable:JarvisJobSenderFilter) "JarvisJobSenderFilter must be defined (sender filter must be defined)"
Assert (-not [string]::IsNullOrWhiteSpace($JarvisJobSenderFilter)) "JarvisJobSenderFilter must be non-empty (sender filter must be defined)"

# --- The filter must not NARROW. Every sender it matched before must still match. ---
foreach ($old in @('linkedin','indeed','gradireland','glassdoor','jobs.ie','irishjobs',
                   'mastercard','workday','myworkday','maynooth','nuim.ie','vodafone')) {
  Assert ("notifications@$old.com" -imatch $JarvisJobSenderFilter) "pre-existing sender '$old' must still match"
}

# --- THE DEMONSTRATED MISS. Learnosity rejected Alex via Workable on 2026-07-20 and Jarvis never
# --- reported it: 'workable' was not in the filter, so the classifier was never shown the message.
Assert ('no-reply@workable.com' -imatch $JarvisJobSenderFilter) "Workable must match - this is the Learnosity miss"

# --- Assessment platforms: the SIG CodeSignal invite expired 2026-07-10 unactioned. ---
foreach ($vendor in @('codesignal','hackerrank','codility','karat','hirevue')) {
  Assert ("invite@$vendor.com" -imatch $JarvisJobSenderFilter) "assessment platform '$vendor' must match"
}

# --- ATS platforms that carry real Irish job mail ---
foreach ($ats in @('greenhouse','lever','smartrecruiters','teamtailor','ashby','icims','taleo','successfactors','rezoomo','harri','amris')) {
  Assert ("careers@$ats.io" -imatch $JarvisJobSenderFilter -or "careers@$ats.com" -imatch $JarvisJobSenderFilter) "ATS '$ats' must match"
}

# --- It must still be a filter, not a sieve: ordinary mail stays out. ---
foreach ($noise in @('newsletter@substack.com','friend@gmail.com','billing@electricireland.ie')) {
  Assert (-not ($noise -imatch $JarvisJobSenderFilter)) "'$noise' must NOT match the job filter"
}

# --- 'ashby' and 'ashbyhq' were redundant (ashby already matches ashbyhq.com); 'harri' is anchored
# --- to its real domain so it doesn't also catch harrison@/harriet@/harrington@-style senders. ---
Assert ('careers@ashbyhq.com' -imatch $JarvisJobSenderFilter) "ashbyhq.com (the real Ashby domain) must still match via 'ashby'"
foreach ($falsePositive in @('harrison@example.com','harriet@example.com','harrington@example.com')) {
  Assert (-not ($falsePositive -imatch $JarvisJobSenderFilter)) "'$falsePositive' must NOT match (harri must be anchored, not bare)"
}

# --- THE PRODUCTION PATH. debrief.md (both the inbox and jobs modules) and app/main.js all invoke
# --- the script's standalone entry point with NO -SenderFilter override. That path must resolve to
# --- the SAME widened filter as $JarvisJobSenderFilter, not a second, stale copy - otherwise the
# --- Learnosity/Workable and CodeSignal misses stay invisible in the 08:30 debrief in production
# --- even though $JarvisJobSenderFilter itself is correct. $SenderFilter here is the real param()
# --- default from dot-sourcing with no override supplied - exactly the state debrief.md/main.js run in.
Assert ((Resolve-JobSenderFilter -SenderFilter $SenderFilter) -imatch 'workable') "production entry point (no -SenderFilter override) must reach Workable"
Assert ((Resolve-JobSenderFilter -SenderFilter $SenderFilter) -imatch 'codesignal') "production entry point (no -SenderFilter override) must reach CodeSignal"

# --- An explicit -SenderFilter override must still win over the shared default. ---
Assert ((Resolve-JobSenderFilter -SenderFilter 'onlythis') -eq 'onlythis') "explicit -SenderFilter override must win over the shared default"

# --- The classifier already handles the phrases we care about (regression, not new work) ---
Assert ((Classify-JobMailSubject 'Your CodeSignal assessment invitation') -eq 'interview') "assessment subject -> interview"
Assert ((Classify-JobMailSubject 'Next steps in your application') -eq 'interview') "next steps -> interview"
Assert ((Classify-JobMailSubject 'Unfortunately we are moving forward with other candidates') -eq 'rejection') "rejection stays rejection"

Write-Host "check-job-mail: ALL PASS"
