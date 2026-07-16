# tests/telegram-bot.Tests.ps1 - pure routing/parsing/safety logic for the Telegram bridge. NO network:
# dot-sources telegram-bot.ps1 and exercises the helpers. The self-only lock is the security-critical bit.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\skill\bin\telegram-bot.ps1" -DotSourceOnly
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

# --- Resolve-TelegramCommand: only a small whitelist maps to actions; everything else is help ---
Assert ((Resolve-TelegramCommand '/debrief') -eq 'debrief') "/debrief -> debrief"
Assert ((Resolve-TelegramCommand 'debrief') -eq 'debrief') "debrief -> debrief"
Assert ((Resolve-TelegramCommand "what's my day") -eq 'debrief') "natural phrasing -> debrief"
Assert ((Resolve-TelegramCommand '/debrief@JarvisButlerBot') -eq 'debrief') "strips @botname"
Assert ((Resolve-TelegramCommand 'STATUS') -eq 'status') "case-insensitive status"
Assert ((Resolve-TelegramCommand '/status') -eq 'status') "/status -> status"
Assert ((Resolve-TelegramCommand 'ping') -eq 'status') "ping -> status"
Assert ((Resolve-TelegramCommand 'delete all my files') -eq 'help') "arbitrary text is NOT executed -> help"
Assert ((Resolve-TelegramCommand '') -eq 'help') "empty -> help"
Assert ((Resolve-TelegramCommand $null) -eq 'help') "null -> help"

# --- Test-TelegramSenderAllowed: the self-only gate (numeric/string ids must compare equal) ---
Assert (Test-TelegramSenderAllowed 555 555) "same id allowed"
Assert (Test-TelegramSenderAllowed '555' 555) "string vs numeric id allowed"
Assert (-not (Test-TelegramSenderAllowed 999 555)) "different id refused"
Assert (-not (Test-TelegramSenderAllowed 555 $null)) "no allowed id -> refuse (fail closed)"
Assert (-not (Test-TelegramSenderAllowed $null 555)) "null sender refused"

# --- Parse-TelegramUpdates: robust flattening of the getUpdates payload ---
$json = @'
{ "ok": true, "result": [
  { "update_id": 100, "message": { "message_id": 1, "chat": { "id": 555 }, "text": "/debrief" } },
  { "update_id": 101, "message": { "message_id": 2, "chat": { "id": 555 }, "text": "hello" } },
  { "update_id": 102, "edited_message": { "message_id": 3, "chat": { "id": 555 }, "text": "edited" } }
] }
'@
$resp = $json | ConvertFrom-Json
$ups = @(Parse-TelegramUpdates $resp)
Assert ($ups.Count -eq 3) "3 updates parsed, got $($ups.Count)"
Assert ($ups[0].UpdateId -eq 100 -and $ups[0].ChatId -eq 555 -and $ups[0].Text -eq '/debrief') "first update fields"
Assert ($ups[2].Text -eq 'edited') "edited_message is handled"
Assert ((@(Parse-TelegramUpdates ($null))).Count -eq 0) "null response -> empty"
$notok = '{ "ok": false, "result": [] }' | ConvertFrom-Json
Assert ((@(Parse-TelegramUpdates $notok)).Count -eq 0) "ok:false -> empty"

# --- Get-NextOffset: highest update_id + 1 (Telegram's ack contract) ---
Assert ((Get-NextOffset $ups) -eq 103) "next offset = max+1 = 103"
Assert ($null -eq (Get-NextOffset @())) "no updates -> null offset"

# --- Format-JobMailAlert: pushes ONLY real status changes, never digests ---
$alerts = @(
  [pscustomobject]@{ Subject='Invitation to interview'; Classification='interview' },
  [pscustomobject]@{ Subject='5 new jobs for you';      Classification='generic' },
  [pscustomobject]@{ Subject='Offer of employment';     Classification='offer' }
)
$msg = Format-JobMailAlert $alerts
Assert ($msg -match 'INTERVIEW' -and $msg -match 'OFFER') "alert names interview + offer"
Assert ($msg -notmatch 'new jobs') "generic digest is NOT pushed"
Assert ($null -eq (Format-JobMailAlert @([pscustomobject]@{ Subject='x'; Classification='generic' }))) "all-generic -> no push"
Assert ($null -eq (Format-JobMailAlert @())) "empty -> no push"

# --- Split-TelegramText: chunk a long debrief so nothing is truncated (Telegram caps at 4096) ---
$one = @(Split-TelegramText 'short line' 100)
Assert ($one.Count -eq 1 -and $one[0] -eq 'short line') "short text -> single chunk"
Assert ((@(Split-TelegramText '' 100)).Count -eq 0) "empty text -> no chunks"
$txt = (1..12 | ForEach-Object { "line$_" }) -join "`n"
$chunks = @(Split-TelegramText $txt 20)
Assert ($chunks.Count -gt 1) "long text splits into multiple chunks"
Assert ((@($chunks | Where-Object { $_.Length -gt 20 })).Count -eq 0) "no chunk exceeds the cap"
Assert (((($chunks -join "`n") -replace "`n",'')) -eq ($txt -replace "`n",'')) "content preserved across chunks"
$long = 'x' * 55
$hc = @(Split-TelegramText $long 20)
Assert ((@($hc | Where-Object { $_.Length -gt 20 })).Count -eq 0) "over-long single line hard-split under cap"
Assert (($hc -join '') -eq $long) "hard-split preserves the whole line"

# --- note capture: text a note on the go. A note is DATA appended to a file, NEVER executed ---
Assert ((Resolve-TelegramCommand 'note buy protein') -eq 'note') "note <text> -> note"
Assert ((Resolve-TelegramCommand '/note buy protein') -eq 'note') "/note -> note"
Assert ((Resolve-TelegramCommand 'idea: a tool for X') -eq 'note') "idea: -> note"
Assert ((Resolve-TelegramCommand 'remember to call the recruiter') -eq 'note') "remember -> note"
Assert ((Resolve-TelegramCommand 'note') -eq 'note') "bare note -> note (will prompt for text)"
Assert ((Resolve-TelegramCommand '/notes') -eq 'notes') "/notes -> notes (read back)"
Assert ((Resolve-TelegramCommand 'notes') -eq 'notes') "notes -> notes"
Assert ((Resolve-TelegramCommand 'notebook shopping list') -eq 'help') "'notebook' must NOT trigger note"
Assert ((Resolve-TelegramCommand 'delete all my files') -eq 'help') "arbitrary text still -> help (not captured, not executed)"
# payload extraction strips the trigger word + optional punctuation, preserving the note's own casing
Assert ((Get-NotePayload 'note buy Protein') -eq 'buy Protein') "note payload keeps case"
Assert ((Get-NotePayload '/note: buy protein') -eq 'buy protein') "slash+colon payload"
Assert ((Get-NotePayload 'idea a tool for X') -eq 'a tool for X') "idea payload"
Assert ((Get-NotePayload 'remember to call mom') -eq 'to call mom') "remember payload"
Assert ((Get-NotePayload 'note') -eq '') "bare note -> empty payload"

# --- Select-ActionableUpdates: the 2026-07-16 bug. Four queued /debrief ran four full generations and
# --- delivered four briefings minutes apart. Expensive commands must collapse; stale backlog must not fire.
function U($id, $text, $date) { [pscustomobject]@{ UpdateId = $id; ChatId = 555; Text = $text; Date = $date } }
$now   = Get-Date '2026-07-16T10:40:00'
$fresh = $now.AddMinutes(-1)
$stale = $now.AddMinutes(-30)

# 1) the actual incident: 4x /debrief in one batch -> ONE run, and it is the most recent
$b = @( (U 1 '/debrief' $fresh), (U 2 '/debrief' $fresh), (U 3 '/debrief' $fresh), (U 4 '/debrief' $fresh) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10)
Assert ($act.Count -eq 1) "4x /debrief collapses to 1 run, got $($act.Count)"
Assert ($act[0].UpdateId -eq 4) "the LAST /debrief is the one that runs"

# 2) notes must NOT collapse - each note is distinct data, losing one loses information
$b = @( (U 1 'note a' $fresh), (U 2 'note b' $fresh), (U 3 'note c' $fresh) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10)
Assert ($act.Count -eq 3) "notes are never deduped, got $($act.Count)"

# 3) stale backlog (e.g. laptop asleep, commands from 30 min ago) must not fire
$b = @( (U 1 '/debrief' $stale), (U 2 'note old' $stale) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10)
Assert ($act.Count -eq 0) "stale updates are not acted on, got $($act.Count)"

# 4) mixed batch: one debrief (the last), both notes, one status; order preserved
$b = @( (U 1 '/debrief' $fresh), (U 2 'note x' $fresh), (U 3 '/debrief' $fresh), (U 4 '/status' $fresh), (U 5 'note y' $fresh) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10)
Assert ($act.Count -eq 4) "mixed batch -> 1 debrief + 2 notes + 1 status, got $($act.Count)"
Assert (@($act | Where-Object { $_.UpdateId -eq 1 }).Count -eq 0) "the superseded first /debrief must not run"
Assert (@($act | Where-Object { $_.UpdateId -eq 3 }).Count -eq 1) "the last /debrief runs"
Assert ($act[0].UpdateId -lt $act[-1].UpdateId) "original order preserved"

# 5) empty batch
Assert ((@(Select-ActionableUpdates -Updates @() -Now $now -MaxAgeMinutes 10)).Count -eq 0) "empty -> empty"

# 6) a missing date must NOT silently swallow a real command (act, don't drop)
$b = @( (U 1 '/debrief' $null) )
Assert ((@(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10)).Count -eq 1) "unknown date -> still acted on"

Write-Host "telegram-bot: ALL PASS"
