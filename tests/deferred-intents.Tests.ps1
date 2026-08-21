# tests/deferred-intents.Tests.ps1 - the deferred-intent ledger (STEP 2). Pure, no network. Every test
# uses an explicit -Path/-VaultPath under $env:TEMP; the real ~/.jarvis/deferred-intents.json,
# ~/.jarvis/opportunities.json and Alex's real vault are never touched.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\deferred-intents.ps1" -DotSourceOnly
. "$PSScriptRoot\..\skill\bin\opportunity-store.ps1" -DotSourceOnly
. "$PSScriptRoot\..\skill\bin\check-opportunities.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$tmp = Join-Path $env:TEMP ('jarvis-deferred-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$vault = Join-Path $tmp 'vault'
New-Item -ItemType Directory -Force -Path (Join-Path $vault 'debriefs') | Out-Null

try {
  # =====================================================================================================
  # 1. Id: stable across calls; length-prefix ambiguity guard
  # =====================================================================================================
  $i1 = Get-DeferredIntentId -Utterance 'I should renew my residence permit' -SourceFile 'debriefs/2026-08-19.md' -MentionedOn '2026-08-19'
  $i2 = Get-DeferredIntentId -Utterance 'I should renew my residence permit' -SourceFile 'debriefs/2026-08-19.md' -MentionedOn '2026-08-19'
  Assert ($i1 -eq $i2) "the same candidate must always derive the same id"
  Assert ($i1 -match '^[0-9a-f]{6}$') "id is 6 lowercase hex chars, got '$i1'"

  $collide1 = Get-DeferredIntentId -Utterance 'a'   -SourceFile 'b|c' -MentionedOn 'd'
  $collide2 = Get-DeferredIntentId -Utterance 'a|b' -SourceFile 'c'   -MentionedOn 'd'
  Assert ($collide1 -ne $collide2) "a pipe inside a field must not let two different triples collide on the same id"

  # =====================================================================================================
  # 2. Store: absent -> @(); corrupt -> quarantined; write is a proper JSON array; atomic
  # =====================================================================================================
  $store = Join-Path $tmp 'deferred-intents.json'
  Assert ((@(Read-DeferredIntentStore -Path $store)).Count -eq 0) "absent store reads as empty"

  Set-Content -Encoding UTF8 $store '{ not valid json - marker-def-456'
  $wasCorrupt = $false
  $readBack = @(Read-DeferredIntentStore -Path $store -WasCorrupt ([ref]$wasCorrupt))
  Assert ($readBack.Count -eq 0) "corrupt store reads as empty instead of throwing"
  Assert ($wasCorrupt) "-WasCorrupt must be set true when the store was actually corrupt"
  Assert (-not (Test-Path $store)) "the corrupt file must be MOVED (quarantined), not left in place"
  $quarantined = @(Get-ChildItem -Path $tmp -Filter 'deferred-intents.json.corrupt-*')
  Assert ($quarantined.Count -eq 1) "exactly one quarantine file must exist, got $($quarantined.Count)"

  $rec0 = [pscustomobject]@{ Id='aaa111'; Utterance='x'; SourceFile='y.md'; MentionedOn='2026-08-19'; Category='admin'; ResurfaceAfter='2026-09-01'; Why='w'; Status='open'; FirstSeen='2026-08-19T09:00:00'; PromotedAt=$null }
  Write-DeferredIntentStore -Records @($rec0) -Path $store
  Assert (Test-Path $store) "write creates the file"
  Assert ((@(Get-ChildItem -Path $tmp -Filter 'deferred-intents.json.tmp-*')).Count -eq 0) "atomic write: no leftover temp file"
  $back = @(Read-DeferredIntentStore -Path $store)
  Assert ($back.Count -eq 1 -and $back[0].Id -eq 'aaa111') "round trip preserves the record"
  Write-DeferredIntentStore -Records @() -Path $store
  $emptyBack = Get-Content -LiteralPath $store -Raw | ConvertFrom-Json
  Assert ($emptyBack -is [array] -or $emptyBack.Count -eq 0) "zero records still writes a proper JSON array, not null"

  # =====================================================================================================
  # 3. Get-ResurfaceDate: garbage -> +14d; yesterday -> clamp +1d; +400d -> clamp +90d
  # =====================================================================================================
  $now = Get-Date '2026-08-20T09:00:00'
  $garbage = Get-ResurfaceDate -Proposed 'not-a-date' -Now $now
  Assert ($garbage -eq $now.Date.AddDays(14)) "garbage proposed date falls back to +14d, got $garbage"

  $tooSoon = Get-ResurfaceDate -Proposed '2026-08-19' -Now $now
  Assert ($tooSoon -eq $now.Date.AddDays(1)) "a proposed date in the past clamps to +1d, got $tooSoon"

  $tooFar = Get-ResurfaceDate -Proposed '2027-10-01' -Now $now
  Assert ($tooFar -eq $now.Date.AddDays(90)) "a proposed date beyond the ceiling clamps to +90d, got $tooFar"

  $reasonable = Get-ResurfaceDate -Proposed '2026-09-01' -Now $now
  Assert ($reasonable -eq (Get-Date '2026-09-01').Date) "a reasonable proposed date passes through unchanged"

  # =====================================================================================================
  # 4. CHEATING-AGENT TESTS (load-bearing): fixture vault with real files; the anti-fabrication gate
  # =====================================================================================================
  $srcFile = Join-Path $vault 'debriefs\2026-08-19.md'
  Set-Content -Encoding UTF8 $srcFile "Some debrief text.`nI should really renew my residence permit before October.`nMore text."
  $otherFile = Join-Path $vault 'debriefs\2026-08-18.md'
  Set-Content -Encoding UTF8 $otherFile "Nothing relevant here."

  # a) quote does NOT exist in the cited file -> rejected
  $fabricated = [pscustomobject]@{ utterance='I should learn to fly a helicopter someday'; source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='hobby'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (-not (Test-DeferredIntentCandidate -Candidate $fabricated -VaultPath $vault)) "a quote that does not exist verbatim on disk must be rejected (anti-fabrication)"

  # b) quote exists but source_file cites a DIFFERENT file -> rejected
  $wrongFile = [pscustomobject]@{ utterance='I should really renew my residence permit before October.'; source_file='debriefs/2026-08-18.md'; mentioned_on='2026-08-19'; category='admin'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (-not (Test-DeferredIntentCandidate -Candidate $wrongFile -VaultPath $vault)) "a quote must be verified against the FILE it claims to be from, not any file in the vault"

  # c) source_file escapes the vault (path traversal) -> rejected
  Set-Content -Encoding UTF8 (Join-Path $tmp 'outside.md') "I should really renew my residence permit before October."
  $traversal = [pscustomobject]@{ utterance='I should really renew my residence permit before October.'; source_file='..\outside.md'; mentioned_on='2026-08-19'; category='admin'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (-not (Test-DeferredIntentCandidate -Candidate $traversal -VaultPath $vault)) "a source_file that escapes the vault must be rejected (path traversal guard)"

  # d) whitespace/case variant of a real sentence -> accepted
  $variant = [pscustomobject]@{ utterance='i should REALLY renew my residence   permit before October.'; source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='admin'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (Test-DeferredIntentCandidate -Candidate $variant -VaultPath $vault) "a whitespace/case-collapsed variant of a real on-disk sentence must be accepted"

  # e) the exact real sentence -> accepted
  $real = [pscustomobject]@{ utterance='I should really renew my residence permit before October.'; source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='admin'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (Test-DeferredIntentCandidate -Candidate $real -VaultPath $vault) "the exact real sentence must be accepted"

  # f) too short / missing fields -> rejected
  $tooShort = [pscustomobject]@{ utterance='short'; source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='admin'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (-not (Test-DeferredIntentCandidate -Candidate $tooShort -VaultPath $vault)) "an utterance under 10 chars must be rejected"
  $missing = [pscustomobject]@{ utterance='I should really renew my residence permit before October.'; mentioned_on='2026-08-19' }
  Assert (-not (Test-DeferredIntentCandidate -Candidate $missing -VaultPath $vault)) "a candidate missing source_file must be rejected"
  $badDate = [pscustomobject]@{ utterance='I should really renew my residence permit before October.'; source_file='debriefs/2026-08-19.md'; mentioned_on='08/19/2026'; category='admin'; suggested_resurface_after='2026-09-01'; why='w' }
  Assert (-not (Test-DeferredIntentCandidate -Candidate $badDate -VaultPath $vault)) "a mentioned_on that does not parse as exactly yyyy-MM-dd must be rejected"

  # =====================================================================================================
  # 5. Merge: malformed staging -> Proposed=0, no throw, store untouched; cap at 3; dedupe; staging deleted
  # =====================================================================================================
  $stagingPath = Get-DeferredIntentStagingPath -VaultPath $vault -Date '2026-08-19'
  Assert ($stagingPath -like '*debriefs\.jarvis-deferred-staging-2026-08-19.json') "staging path is the pinned dot-leading filename, got '$stagingPath'"

  $mergeStore = Join-Path $tmp 'merge-store.json'
  Set-Content -Encoding UTF8 $stagingPath '{ not valid json at all'
  $threwMalformed = $false
  $mResult = $null
  try { $mResult = Merge-DeferredIntentCandidates -StagingPath $stagingPath -StorePath $mergeStore -VaultPath $vault -Now $now } catch { $threwMalformed = $true }
  Assert (-not $threwMalformed) "malformed staging JSON must never throw"
  Assert ($mResult.Proposed -eq 0) "malformed staging JSON yields Proposed=0, got $($mResult.Proposed)"
  Assert (-not (Test-Path $mergeStore)) "malformed staging with zero candidates must not create a store"

  # 5 valid candidates (all verified against the real source file) -> exactly 3 accepted (cap)
  Set-Content -Encoding UTF8 $srcFile @"
Line one is filler text that pads the source file out nicely.
Candidate utterance number one goes here for the merge cap test today.
Candidate utterance number two goes here for the merge cap test today.
Candidate utterance number three goes here for the merge cap test today.
Candidate utterance number four goes here for the merge cap test today.
Candidate utterance number five goes here for the merge cap test today.
"@
  $fiveCandidates = @(
    @{ utterance='Candidate utterance number one goes here for the merge cap test today.';   source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='c'; suggested_resurface_after='2026-09-01'; why='w' },
    @{ utterance='Candidate utterance number two goes here for the merge cap test today.';   source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='c'; suggested_resurface_after='2026-09-01'; why='w' },
    @{ utterance='Candidate utterance number three goes here for the merge cap test today.'; source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='c'; suggested_resurface_after='2026-09-01'; why='w' },
    @{ utterance='Candidate utterance number four goes here for the merge cap test today.';  source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='c'; suggested_resurface_after='2026-09-01'; why='w' },
    @{ utterance='Candidate utterance number five goes here for the merge cap test today.';  source_file='debriefs/2026-08-19.md'; mentioned_on='2026-08-19'; category='c'; suggested_resurface_after='2026-09-01'; why='w' }
  )
  $fiveCandidates | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $stagingPath
  $mergeStore2 = Join-Path $tmp 'merge-store-cap.json'
  $capResult = Merge-DeferredIntentCandidates -StagingPath $stagingPath -StorePath $mergeStore2 -VaultPath $vault -Now $now
  Assert ($capResult.Proposed -eq 5) "5 candidates staged -> Proposed=5, got $($capResult.Proposed)"
  Assert ($capResult.Accepted -eq 3) "exactly 3 accepted per run (cap), got $($capResult.Accepted)"
  Assert (-not (Test-Path $stagingPath)) "staging file must be deleted after merge"
  $afterCap = @(Read-DeferredIntentStore -Path $mergeStore2)
  Assert ($afterCap.Count -eq 3) "store holds exactly the 3 accepted records, got $($afterCap.Count)"

  # re-merge of the same candidates -> 0 new (dedupe)
  $fiveCandidates | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $stagingPath
  $reResult = Merge-DeferredIntentCandidates -StagingPath $stagingPath -StorePath $mergeStore2 -VaultPath $vault -Now $now
  Assert ($reResult.Accepted -le 2) "re-merging the same 5 candidates must add at most the 2 NOT already stored (the first 3 are dedup'd), got $($reResult.Accepted)"
  $afterReMerge = @(Read-DeferredIntentStore -Path $mergeStore2)
  Assert ($afterReMerge.Count -eq 5) "after re-merge all 5 distinct candidates are present exactly once each, got $($afterReMerge.Count)"

  # =====================================================================================================
  # 6. Promotion: due intent promoted exactly once; not-yet-due untouched; corrupt deferred store skipped
  # =====================================================================================================
  $dueIntent = [pscustomobject]@{ Id='ddd111'; Utterance='I should renew my passport before the trip.'; SourceFile='debriefs/2026-08-01.md'; MentionedOn='2026-08-01'; Category='admin'; ResurfaceAfter='2026-08-15'; Why='w'; Status='open'; FirstSeen='2026-08-01T09:00:00'; PromotedAt=$null }
  $notDueIntent = [pscustomobject]@{ Id='eee222'; Utterance='I should learn Spanish eventually for fun.'; SourceFile='debriefs/2026-08-01.md'; MentionedOn='2026-08-01'; Category='hobby'; ResurfaceAfter='2026-12-01'; Why='w'; Status='open'; FirstSeen='2026-08-01T09:00:00'; PromotedAt=$null }
  $promoNow = Get-Date '2026-08-20T09:00:00'
  $promo1 = Add-DeferredIntentPromotions -OppRecords @() -Intents @($dueIntent, $notDueIntent) -Now $promoNow
  Assert ($promo1.PromotedCount -eq 1) "exactly one due intent promoted per call, got $($promo1.PromotedCount)"
  $promotedIntent = @($promo1.Intents | Where-Object { $_.Id -eq 'ddd111' })[0]
  Assert ($promotedIntent.Status -eq 'promoted') "the due intent's status flips to promoted"
  Assert ($promotedIntent.PromotedAt) "the due intent gets a PromotedAt stamp"
  $untouchedIntent = @($promo1.Intents | Where-Object { $_.Id -eq 'eee222' })[0]
  Assert ($untouchedIntent.Status -eq 'open') "a not-yet-due intent is left untouched"
  Assert ($promo1.OppRecords.Count -eq 1) "one opportunity record was created for the promotion"
  Assert ($promo1.OppRecords[0].Type -eq 'deferred_intent') "the promoted opportunity record carries Type='deferred_intent'"
  Assert ($promo1.OppRecords[0].Id -match '^[0-9a-f]{6}$') "the promoted opportunity record has a 6-hex-char id, same format as every other opportunity"

  # second call on the ALREADY-promoted intents -> PromotedCount 0 (never re-promoted)
  $promo2 = Add-DeferredIntentPromotions -OppRecords $promo1.OppRecords -Intents $promo1.Intents -Now $promoNow.AddDays(1)
  Assert ($promo2.PromotedCount -eq 0) "an already-promoted intent must never be re-promoted, got $($promo2.PromotedCount)"
  Assert ($promo2.OppRecords.Count -eq 1) "no duplicate opportunity record is created on a second call"

  # corrupt deferred store -> promotion skipped, quarantine intact (exercised at the store-read layer:
  # a corrupt Read-DeferredIntentStore must leave -WasCorrupt true and the file quarantined, and the
  # caller is expected to skip calling Add-DeferredIntentPromotions in that case - see check-opportunities.ps1)
  $corruptDeferred = Join-Path $tmp 'deferred-corrupt.json'
  Set-Content -Encoding UTF8 $corruptDeferred '{ still not json'
  $wasCorrupt3 = $false
  $readCorrupt = @(Read-DeferredIntentStore -Path $corruptDeferred -WasCorrupt ([ref]$wasCorrupt3))
  Assert ($wasCorrupt3) "a corrupt deferred store must be flagged so the sweep skips promotion this run"
  Assert ($readCorrupt.Count -eq 0) "a corrupt deferred store reads as empty (never crashes the sweep)"
  Assert ((@(Get-ChildItem -Path $tmp -Filter 'deferred-corrupt.json.corrupt-*')).Count -eq 1) "the corrupt deferred store is quarantined, not erased"

  # =====================================================================================================
  # 7. Format-OpportunityPush deferred branch
  # =====================================================================================================
  $deferredRec = [pscustomobject]@{ Id='abc123'; From='deferred-intent'; Subject='I should renew my passport before the trip.'; Date='2026-08-01'; Status='open'; LastPushed=$null; Type='deferred_intent' }
  $pushText = Format-OpportunityPush -Record $deferredRec
  Assert ($pushText -match 'You mentioned this once, Sir') "deferred-intent push must use the distinct lead line"
  Assert ($pushText -match [regex]::Escape('I should renew my passport before the trip.')) "deferred-intent push must include the utterance"
  Assert ($pushText -match 'done abc123') "deferred-intent push must include the standard done <id> clear instruction"

  $reminderText = Format-OpportunityPush -Record $deferredRec -Reminder
  Assert ($reminderText -match 'You mentioned this once, Sir') "deferred-intent REMINDER push must also use the distinct lead line, not 'Still open, Sir'"

  # =====================================================================================================
  # 8. Sweep integration via the existing -MailFetcher/-Sender/-CredResolver seams: hour gate + real push
  # =====================================================================================================
  $fakeCred = [pscustomobject]@{ ChatId = 555; Token = 'test-token-not-real' }
  $credResolver = { $fakeCred }
  $script:sentTexts8 = New-Object System.Collections.Generic.List[string]
  $cleanSender8 = { param([string]$Text, $Cred) $script:sentTexts8.Add($Text) }
  $noAlerts8 = { param($SinceHours, $MaxMessages) [pscustomobject]@{ JobAlerts = @() } }

  $sweepDeferredStore = Join-Path $tmp 'sweep-deferred.json'
  $sweepOppStore1 = Join-Path $tmp 'sweep-opp-early.json'
  $sweepOppStore2 = Join-Path $tmp 'sweep-opp-late.json'
  $dueForSweep = [pscustomobject]@{ Id='fff333'; Utterance='I should back up my laptop before the trip.'; SourceFile='debriefs/2026-08-01.md'; MentionedOn='2026-08-01'; Category='admin'; ResurfaceAfter='2026-08-15'; Why='w'; Status='open'; FirstSeen='2026-08-01T09:00:00'; PromotedAt=$null }
  Write-DeferredIntentStore -Records @($dueForSweep) -Path $sweepDeferredStore

  $script:sentTexts8.Clear()
  $sentEarly8 = Invoke-OpportunitySweep -Now (Get-Date '2026-08-20T03:00:00') -StorePath $sweepOppStore1 `
    -DeferredIntentStorePath $sweepDeferredStore -MailFetcher $noAlerts8 -Sender $cleanSender8 -CredResolver $credResolver
  Assert ($sentEarly8 -eq 0) "before 08:00 a due deferred intent must NOT be promoted or pushed (hour gate)"
  Assert ($script:sentTexts8.Count -eq 0) "no deferred-intent push sent before the hour gate"

  Write-DeferredIntentStore -Records @($dueForSweep) -Path $sweepDeferredStore
  $script:sentTexts8.Clear()
  $sentLate8 = Invoke-OpportunitySweep -Now (Get-Date '2026-08-20T09:00:00') -StorePath $sweepOppStore2 `
    -DeferredIntentStorePath $sweepDeferredStore -MailFetcher $noAlerts8 -Sender $cleanSender8 -CredResolver $credResolver
  Assert ($sentLate8 -eq 1) "at/after 08:00 exactly one deferred-intent push must fire, got $sentLate8"
  Assert ($script:sentTexts8.Count -eq 1 -and $script:sentTexts8[0] -match 'You mentioned this once, Sir') "the push sent through the stub Sender uses the deferred-intent lead line"
  $sweptOpp = @(Read-OpportunityStore -Path $sweepOppStore2)
  Assert ($sweptOpp.Count -eq 1 -and $sweptOpp[0].Type -eq 'deferred_intent') "the promotion was persisted to the opportunity store"
  $sweptDeferred = @(Read-DeferredIntentStore -Path $sweepDeferredStore)
  Assert ($sweptDeferred[0].Status -eq 'promoted') "the deferred-intent store itself was persisted with the promoted status"

  # =====================================================================================================
  # 9. Prompt-pin (necessary-but-not-sufficient, ci-style): jarvis-debrief.ps1 wires prompt and merge
  #    through the SAME staging-path function - the filename-mismatch class pinned dead.
  # =====================================================================================================
  $debriefSrc = Get-Content -LiteralPath "$PSScriptRoot\..\skill\bin\jarvis-debrief.ps1" -Raw
  Assert ($debriefSrc -match 'Get-DeferredIntentPromptBlock') "jarvis-debrief.ps1 must call Get-DeferredIntentPromptBlock"
  Assert ($debriefSrc -match 'Get-DeferredIntentStagingPath') "jarvis-debrief.ps1 must call Get-DeferredIntentStagingPath"
  Assert ($debriefSrc -match 'Merge-DeferredIntentCandidates') "jarvis-debrief.ps1 must call Merge-DeferredIntentCandidates"

  # =====================================================================================================
  # 10. Additive regressions: Add-Opportunity default Type='email'; email-record push text unchanged
  # =====================================================================================================
  $emailAdd = Add-Opportunity -Records @() -From 'invite@codesignal.com' -Subject 'Your assessment' -Date '2026-08-19' -Now $now
  Assert ($emailAdd.Records[0].Type -eq 'email') "Add-Opportunity defaults Type to 'email' when -Type is not supplied"
  $emailPush = Format-OpportunityPush -Record $emailAdd.Records[0]
  Assert ($emailPush -match 'A door just opened, Sir') "an email-type opportunity push must be unchanged - the original lead line"
  $emailReminder = Format-OpportunityPush -Record $emailAdd.Records[0] -Reminder
  Assert ($emailReminder -match 'Still open, Sir') "an email-type reminder push must be unchanged"

} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "deferred-intents: ALL PASS"
