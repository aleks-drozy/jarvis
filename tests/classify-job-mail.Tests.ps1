# tests/classify-job-mail.Tests.ps1 - subject-line classification of job-alert mail (headers only,
# Safety 5). No network: dot-sources check-job-mail.ps1 and exercises the pure functions directly.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\check-job-mail.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }
function CJ($subj){ Classify-JobMailSubject $subj }   # 'Cat' collides with the Get-Content alias

# --- rejection ---
Assert ((CJ 'Unfortunately, your application was not successful') -eq 'rejection') "plain rejection"
Assert ((CJ 'We regret to inform you about your application') -eq 'rejection') "regret to inform"
Assert ((CJ 'Update: you have not been shortlisted') -eq 'rejection') "not shortlisted"
Assert ((CJ 'We have decided not to proceed with your application') -eq 'rejection') "decided not to proceed"

# --- interview ---
Assert ((CJ 'Invitation to interview - Software Engineer') -eq 'interview') "invitation to interview"
Assert ((CJ "Let's schedule a call about your application") -eq 'interview') "schedule a call"
Assert ((CJ 'Next steps in your application with Acme') -eq 'interview') "next steps"
Assert ((CJ 'Your technical assessment for the Graduate Programme') -eq 'interview') "technical assessment"

# --- offer ---
Assert ((CJ 'Offer of employment - Software Engineer II') -eq 'offer') "offer of employment"
Assert ((CJ 'We are pleased to offer you the position') -eq 'offer') "pleased to offer you"

# --- precedence (the hard cases) ---
Assert ((CJ "We'd like to offer you an interview") -eq 'interview') "offer+interview -> interview, not offer"
Assert ((CJ 'Unfortunately we cannot offer you an interview at this time') -eq 'rejection') "reject wins over offer+interview"

# --- generic / digests must NOT read as a status change ---
Assert ((CJ 'Your application to Acme has been received') -eq 'generic') "confirmation is generic"
Assert ((CJ '5 new jobs for graduate software engineer') -eq 'generic') "job digest is generic"
Assert ((CJ 'Interview tips to help you succeed') -eq 'generic') "newsletter 'interview tips' is generic, not interview"
Assert ((CJ '') -eq 'generic') "empty subject -> generic"
Assert ((CJ $null) -eq 'generic') "null subject -> generic"

# --- wiring: Add-JobMailClassification tags each alert object in place ---
$alerts = @(
  [pscustomobject]@{ From='no-reply@myworkday.com'; Subject='Invitation to interview'; Date='x' },
  [pscustomobject]@{ From='jobs@linkedin.com';      Subject='Unfortunately, not this time'; Date='y' }
)
$tagged = @(Add-JobMailClassification $alerts)
Assert ($tagged.Count -eq 2) "classification preserves count"
Assert ($tagged[0].Classification -eq 'interview') "first alert tagged interview"
Assert ($tagged[1].Classification -eq 'rejection') "second alert tagged rejection"
# empty input must not throw and must stay an array
Assert ((@(Add-JobMailClassification @())).Count -eq 0) "empty alerts -> empty, no throw"

Write-Host "classify-job-mail: ALL PASS"
