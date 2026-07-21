# tests/check-job-mail.Tests.ps1 - the job-mail sender filter and subject classifier.
# NO NETWORK: dot-sources check-job-mail.ps1 and exercises the pure parts only.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\check-job-mail.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

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

# --- The classifier already handles the phrases we care about (regression, not new work) ---
Assert ((Classify-JobMailSubject 'Your CodeSignal assessment invitation') -eq 'interview') "assessment subject -> interview"
Assert ((Classify-JobMailSubject 'Next steps in your application') -eq 'interview') "next steps -> interview"
Assert ((Classify-JobMailSubject 'Unfortunately we are moving forward with other candidates') -eq 'rejection') "rejection stays rejection"

Write-Host "check-job-mail: ALL PASS"
