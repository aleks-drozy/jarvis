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

# --- -ChatEnabled adds exactly one outcome and changes nothing else (the whitelist stays the default) ---
Assert ((Resolve-TelegramCommand 'how am I doing on the job hunt') -eq 'help') "chat OFF: arbitrary text -> help"
Assert ((Resolve-TelegramCommand 'how am I doing on the job hunt' -ChatEnabled) -eq 'chat') "chat ON: arbitrary text -> chat"
Assert ((Resolve-TelegramCommand '   ' -ChatEnabled) -eq 'help') "chat ON: whitespace-only -> help, never chat"
Assert ((Resolve-TelegramCommand '' -ChatEnabled) -eq 'help') "chat ON: empty -> help"
Assert ((Resolve-TelegramCommand $null -ChatEnabled) -eq 'help') "chat ON: null -> help"
# the four real commands must be unreachable by chat - they win in BOTH modes
Assert ((Resolve-TelegramCommand '/debrief' -ChatEnabled) -eq 'debrief') "chat ON: /debrief still debrief"
Assert ((Resolve-TelegramCommand 'ping' -ChatEnabled) -eq 'status') "chat ON: ping still status"
Assert ((Resolve-TelegramCommand 'note buy protein' -ChatEnabled) -eq 'note') "chat ON: note still note"
Assert ((Resolve-TelegramCommand '/notes' -ChatEnabled) -eq 'notes') "chat ON: /notes still notes"

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

# 7) chat messages are DATA like notes, never collapsed: two questions are two questions
$b = @( (U 1 'how is the job hunt going' $fresh), (U 2 'and what about my balance' $fresh) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10 -ChatEnabled)
Assert ($act.Count -eq 2) "two chat questions both survive, got $($act.Count)"

# 8) chat does not break the existing collapse: debriefs still collapse in the same batch
$b = @( (U 1 '/debrief' $fresh), (U 2 'how is the job hunt going' $fresh), (U 3 '/debrief' $fresh) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10 -ChatEnabled)
Assert ($act.Count -eq 2) "1 collapsed debrief + 1 chat, got $($act.Count)"
Assert (@($act | Where-Object { $_.UpdateId -eq 3 }).Count -eq 1) "the LAST /debrief still wins"

# 9) without -ChatEnabled the old behaviour is intact: arbitrary text is 'help' and collapses
$b = @( (U 1 'random text a' $fresh), (U 2 'random text b' $fresh) )
$act = @(Select-ActionableUpdates -Updates $b -Now $now -MaxAgeMinutes 10)
Assert ($act.Count -eq 1) "chat OFF: arbitrary text is help and still collapses, got $($act.Count)"

# --- Invoke-TelegramCommand 'chat' / Invoke-PollOnce stale-question ack: the two behaviours added in
# --- Task 7 that carry real stakes and had no test. Both rely on Send-Telegram (Telegram's HTTP API)
# --- and Invoke-ChatTurn (spawns the claude CLI against the model) - the network/model surface that is
# --- exactly why this wiring was never exercised before. Redefine both AFTER the dot-source above:
# --- PowerShell resolves an unqualified function call by NAME at CALL time, searching the scope the
# --- caller was DEFINED in - since Invoke-TelegramCommand/Invoke-PollOnce were defined by the dot-source
# --- into THIS script's scope, a same-named function assigned here shadows the original for them too
# --- (verified empirically before writing these: a function-calls-function dot-sourced setup, redefine
# --- the callee afterward, the caller picks up the redefinition with no other change needed). Recording
# --- calls instead of performing them is enough to assert what would have been sent/generated without
# --- ever touching the network or the model.

$script:MockSentMessages  = New-Object System.Collections.Generic.List[object]
$script:MockChatTurnCalls = New-Object System.Collections.Generic.List[object]
$script:MockChatTurnReturn = $null   # staged return value for the next Invoke-ChatTurn call(s)

function Reset-TelegramMocks {
  $script:MockSentMessages.Clear()
  $script:MockChatTurnCalls.Clear()
  $script:MockChatTurnReturn = $null
}

function Send-Telegram {
  # Shadow of the real Telegram send (skill/bin/telegram-bot.ps1). Records instead of calling out.
  param([string]$Text, $ToChatId, $Cred)
  $script:MockSentMessages.Add([pscustomobject]@{ Text = $Text; ToChatId = $ToChatId })
}

function Invoke-ChatTurn {
  # Shadow of the real headless-claude turn (skill/bin/telegram-chat.ps1). Records instead of spawning
  # claude/the model and returns whatever the test staged in $script:MockChatTurnReturn.
  param([string]$Prompt, [string]$ScopeDir, [int]$TimeoutSec = 180)
  $script:MockChatTurnCalls.Add([pscustomobject]@{ Prompt = $Prompt; ScopeDir = $ScopeDir })
  return $script:MockChatTurnReturn
}

# Write-ChatLog's default -LogPath is (Get-ChatLogPath), which points at the REAL
# ~/.jarvis/telegram-chat.log on this machine. Redirect it to a throwaway temp file so these tests never
# touch that file. Write-ChatLog itself is left REAL (not shadowed) - the point of this test is to prove
# it actually wrote the reply that was sent, not to mock that away too.
$script:MockChatLogPath = Join-Path $env:TEMP ('jarvis-telegram-bot-test-chatlog-' + [guid]::NewGuid().ToString('N') + '.log')
function Get-ChatLogPath { return $script:MockChatLogPath }

# $VAULT and $OffsetPath are plain script-scope variables bound when telegram-bot.ps1 was dot-sourced at
# the top of this file; reassigning them here is visible to every function it defined, same mechanism as
# the function shadowing above. Point $VAULT at a throwaway vault with chat turned on (so
# Invoke-PollOnce's own Test-ChatEnabled check resolves true) and $OffsetPath at a throwaway file, so
# these tests never read or write anything under the real ~/.jarvis on this machine.
$origVault      = $VAULT
$origOffsetPath = $OffsetPath
$mockVault = Join-Path $env:TEMP ('jarvis-telegram-bot-test-vault-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $mockVault | Out-Null
Set-Content -Encoding UTF8 (Join-Path $mockVault 'CONFIG.md') "- modules:`n    telegram_chat: on"
$VAULT         = $mockVault
$mockOffsetPath = Join-Path $env:TEMP ('jarvis-telegram-bot-test-offset-' + [guid]::NewGuid().ToString('N') + '.json')
$OffsetPath    = $mockOffsetPath

$mockCred = [pscustomobject]@{ ChatId = 555; Token = 'test-token-not-real' }

# ===== Invoke-TelegramCommand 'chat': a failed turn must never reach Alex as Jarvis' own voice =====
# Each message below is deliberately free of bank/job/calendar keywords, so Get-ChatPrefetch resolves to
# no collectors and Invoke-ChatPrefetch returns immediately without running any real collector script.

Reset-TelegramMocks
$script:MockChatTurnReturn = $null
Invoke-TelegramCommand -Command 'chat' -Text 'Tell me a joke, Sir' -Cred $mockCred
Assert ($script:MockSentMessages.Count -eq 1) "null Invoke-ChatTurn: exactly one Send-Telegram call, got $($script:MockSentMessages.Count)"
Assert ($null -ne $script:MockSentMessages[0].Text -and $script:MockSentMessages[0].Text -ne '') "null Invoke-ChatTurn: sent text is never raw `$null or empty"
Assert ($script:MockSentMessages[0].Text -eq 'That one got away from me, Sir - the run timed out. Try again, or ask me at the desk.') "null Invoke-ChatTurn: substituted with the butler-voiced apology, got '$($script:MockSentMessages[0].Text)'"
$loggedNull = Get-Content -LiteralPath $script:MockChatLogPath -Raw
Assert ($loggedNull -match [regex]::Escape($script:MockSentMessages[0].Text)) "null case: the logged reply matches what was sent"
Remove-Item -LiteralPath $script:MockChatLogPath -Force -ErrorAction SilentlyContinue

Reset-TelegramMocks
$script:MockChatTurnReturn = ''
Invoke-TelegramCommand -Command 'chat' -Text 'Tell me a joke, Sir' -Cred $mockCred
Assert ($script:MockSentMessages.Count -eq 1) "empty-string Invoke-ChatTurn: exactly one Send-Telegram call, got $($script:MockSentMessages.Count)"
Assert ($null -ne $script:MockSentMessages[0].Text -and $script:MockSentMessages[0].Text -ne '') "empty-string Invoke-ChatTurn: sent text is never raw `$null or empty"
Assert ($script:MockSentMessages[0].Text -eq 'That one got away from me, Sir - the run timed out. Try again, or ask me at the desk.') "empty-string Invoke-ChatTurn: substituted with the butler-voiced apology, got '$($script:MockSentMessages[0].Text)'"
$loggedEmpty = Get-Content -LiteralPath $script:MockChatLogPath -Raw
Assert ($loggedEmpty -match [regex]::Escape($script:MockSentMessages[0].Text)) "empty case: the logged reply matches what was sent"
Remove-Item -LiteralPath $script:MockChatLogPath -Force -ErrorAction SilentlyContinue

Reset-TelegramMocks
$script:MockChatTurnReturn = 'The meaning of life is 42, Sir.'
Invoke-TelegramCommand -Command 'chat' -Text 'Tell me a joke, Sir' -Cred $mockCred
Assert ($script:MockSentMessages.Count -eq 1) "normal reply: exactly one Send-Telegram call, got $($script:MockSentMessages.Count)"
Assert ($script:MockSentMessages[0].Text -eq 'The meaning of life is 42, Sir.') "normal reply is sent UNCHANGED, got '$($script:MockSentMessages[0].Text)'"
$loggedNormal = Get-Content -LiteralPath $script:MockChatLogPath -Raw
Assert ($loggedNormal -match [regex]::Escape('The meaning of life is 42, Sir.')) "normal case: the logged reply matches what was sent"
Remove-Item -LiteralPath $script:MockChatLogPath -Force -ErrorAction SilentlyContinue

# ===== Invoke-PollOnce: the stale-question ack must fire ONLY for chat, and must never call the model =====
# getUpdates goes through Invoke-TelegramApi directly (a separate call site from Send-Telegram), so
# shadow that too - but only answer 'getUpdates'. A 'sendMessage' call reaching this shadow would mean
# Send-Telegram itself got bypassed somewhere, which is exactly the kind of routing regression to catch.

function New-FakeUpdate {
  param([int]$Id, $ChatId, [string]$Text, [double]$MinutesAgo)
  $unix = [DateTimeOffset]::UtcNow.AddMinutes(-$MinutesAgo).ToUnixTimeSeconds()
  return [pscustomobject]@{
    update_id = $Id
    message   = [pscustomobject]@{
      message_id = $Id
      chat       = [pscustomobject]@{ id = $ChatId }
      text       = $Text
      date       = $unix
    }
  }
}

$script:MockGetUpdatesResult = @()
function Invoke-TelegramApi {
  param([string]$Token, [string]$Method, [hashtable]$Body)
  if ($Method -eq 'getUpdates') { return [pscustomobject]@{ ok = $true; result = @($script:MockGetUpdatesResult) } }
  throw "test double: unexpected Invoke-TelegramApi -Method '$Method' - sendMessage must go through the Send-Telegram shadow, not here"
}

# 10) a stale chat message: exactly one acknowledgement, and the model is never called for it
Reset-TelegramMocks
$script:MockGetUpdatesResult = @( (New-FakeUpdate -Id 501 -ChatId 555 -Text 'how is the weather today' -MinutesAgo 30) )
$handled = Invoke-PollOnce -Cred $mockCred -TimeoutSec 5
Assert ($handled -eq 0) "stale chat: nothing counted as handled, got $handled"
Assert ($script:MockSentMessages.Count -eq 1) "stale chat: exactly one acknowledgement sent, got $($script:MockSentMessages.Count)"
Assert ($script:MockSentMessages[0].Text -match 'let it lie') "stale chat: the sent text is the stale-question acknowledgement, got '$($script:MockSentMessages[0].Text)'"
Assert ($script:MockChatTurnCalls.Count -eq 0) "stale chat: Invoke-ChatTurn must NEVER be called for a stale question (no model call), got $($script:MockChatTurnCalls.Count) call(s)"

# 11) a stale /debrief: total silence preserved - the 2026-07-16 fix, still correct, must stay silent
Reset-TelegramMocks
$script:MockGetUpdatesResult = @( (New-FakeUpdate -Id 601 -ChatId 555 -Text '/debrief' -MinutesAgo 30) )
$handled = Invoke-PollOnce -Cred $mockCred -TimeoutSec 5
Assert ($handled -eq 0) "stale /debrief: nothing counted as handled, got $handled"
Assert ($script:MockSentMessages.Count -eq 0) "stale /debrief: total silence preserved - no ack, no message at all, got $($script:MockSentMessages.Count)"
Assert ($script:MockChatTurnCalls.Count -eq 0) "stale /debrief: no model call either"

# 12) a superseded chat message (an older question overtaken, in the same batch, by a fresh one) is
# acknowledged, not silently dropped - while the fresh question next to it still gets a real, unmodified
# reply. Chat is never collapsed (test 7/8 above), so the ONLY way a chat update can be missing from the
# actionable set is staleness; this proves that being "superseded" by a newer question in the same poll
# does not make the older one fall through to silence the way a superseded /debrief correctly does.
Reset-TelegramMocks
$script:MockChatTurnReturn = 'Fresh answer, Sir.'
$script:MockGetUpdatesResult = @(
  (New-FakeUpdate -Id 701 -ChatId 555 -Text 'what did you think of my old plan' -MinutesAgo 30),
  (New-FakeUpdate -Id 702 -ChatId 555 -Text 'what do you think of my new plan'  -MinutesAgo 1)
)
$handled = Invoke-PollOnce -Cred $mockCred -TimeoutSec 5
Assert ($handled -eq 1) "superseded+fresh chat: exactly the fresh one is handled, got $handled"
Assert ($script:MockSentMessages.Count -eq 2) "superseded+fresh chat: one ack + one real reply sent, got $($script:MockSentMessages.Count)"
Assert (@($script:MockSentMessages | Where-Object { $_.Text -match 'let it lie' }).Count -eq 1) "the superseded question is acknowledged, not silently dropped"
Assert (@($script:MockSentMessages | Where-Object { $_.Text -eq 'Fresh answer, Sir.' }).Count -eq 1) "the fresh question still gets a real, unmodified reply"
Assert ($script:MockChatTurnCalls.Count -eq 1) "only the fresh question reaches the model, the superseded one does not"

# clean up the throwaway temp state BEFORE restoring the script-scope variables these tests borrowed -
# reassigning $OffsetPath back to the real path first would make this delete the wrong (real) file
Remove-Item -LiteralPath $script:MockChatLogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $mockVault -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $mockOffsetPath -Force -ErrorAction SilentlyContinue
$VAULT      = $origVault
$OffsetPath = $origOffsetPath

Write-Host "telegram-bot: ALL PASS"
