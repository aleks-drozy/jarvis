# skill/bin/telegram-bot.ps1
# Remote control + push channel over Telegram. SELF-ONLY: the bot talks to exactly one chat id (Alex's
# own, stored in the credential). A message from any other chat id is ignored; a send to any other chat
# id is refused in code before the network is touched (Safety rule 2, same spirit as the email recipient
# lock in send-debrief.ps1). The remote surface is deliberately NARROW - /debrief and /status only,
# never arbitrary command execution, so a leaked token cannot be turned into a shell. Bodies are never
# read from mail here. The bot token is DPAPI-encrypted at ~/.jarvis/telegram.cred.xml, never in the
# repo or vault (Safety rule 6). ASCII only (PS 5.1 reads .ps1 as ANSI).
#
# One-time setup (RUN BY ALEX, interactive - Jarvis never creates the bot or handles the raw token):
#   1. In Telegram, message @BotFather -> /newbot -> copy the HTTP API token it gives you.
#   2. Message your new bot once (say "hi") so a chat exists between you and it.
#   3. powershell -File telegram-bot.ps1 -StoreCredential      (paste the token; it auto-detects your chat id)
#   4. Flip CONFIG.md   modules: telegram: on
#
# Usage after setup:
#   telegram-bot.ps1 -Send -Text "..."     push a one-off message to Alex (self only)
#   telegram-bot.ps1 -Once                  one long-poll for incoming commands (for Task Scheduler)
#   telegram-bot.ps1 -Poll                  continuous long-poll loop (foreground/manual)
#   telegram-bot.ps1 -AlertJobMail          push IF a recent job email classifies interview/offer/rejection
param(
  [switch]$StoreCredential, [string]$Token,
  [switch]$Send, [string]$Text,
  [switch]$Poll, [switch]$Once,
  [switch]$AlertJobMail, [int]$SinceHours = 24,
  [switch]$DotSourceOnly,
  [string]$CredPath   = (Join-Path $HOME '.jarvis\telegram.cred.xml'),
  [string]$OffsetPath = (Join-Path $HOME '.jarvis\telegram-offset.json'),
  [string]$ApiBase    = 'https://api.telegram.org'
)
$ErrorActionPreference = 'Stop'
$BIN = $PSScriptRoot
. "$PSScriptRoot\get-jarvis-config.ps1"
. "$PSScriptRoot\telegram-chat.ps1"
$VAULT = (Get-JarvisConfig).vault_path

# ---------- pure helpers (unit-tested; no network) ----------

function Resolve-TelegramCommand {
  # Map an incoming message to ONE of a small whitelist of safe actions. Default = help. This is not a
  # shell: unknown text never executes anything - it just gets the help reply.
  # -ChatEnabled adds ONE extra outcome: unknown text becomes 'chat' instead of 'help'. Without the
  # switch the behaviour is byte-identical to the pre-chat bridge, so the whitelist stays the default.
  # The four existing commands always win over chat: /debrief never becomes a conversation.
  param([string]$Text, [switch]$ChatEnabled)
  if (-not $Text -or -not $Text.Trim()) { return 'help' }   # empty AND whitespace-only -> help
  $t = $Text.Trim().ToLower() -replace '^/','' -replace '@\w+$',''   # strip a leading slash and @botname
  if ($t -match '^notes$') { return 'notes' }                                   # read recent notes back
  if ($t -match '^(note|log|idea|remember|todo|jot|capture)\b') { return 'note' } # capture the rest as a note
  switch -regex ($t) {
    '^(debrief|brief|briefing|what''?s my day|what should i do)$' { return 'debrief' }
    '^(status|health|how are you|ping)$'                          { return 'status' }
    default { if ($ChatEnabled) { return 'chat' } else { return 'help' } }
  }
}

function Get-NotePayload {
  # Extract the note body from a capture message: strip a leading /note|note|log|idea|remember|todo|jot|
  # capture and any following colon/comma/space. Preserves the note's original casing.
  param([string]$Text)
  if (-not $Text) { return '' }
  return ($Text.Trim() -replace '^/?(?i)(note|log|idea|remember|todo|jot|capture)\b[:,\s]*', '').Trim()
}

function Test-TelegramSenderAllowed {
  # Fail closed: only the stored owner chat id is ever allowed. Compare as strings so 555 == "555".
  param($ChatId, $AllowedChatId)
  if ($null -eq $AllowedChatId -or "$AllowedChatId" -eq '') { return $false }
  if ($null -eq $ChatId -or "$ChatId" -eq '') { return $false }
  return ("$ChatId" -eq "$AllowedChatId")
}

function Parse-TelegramUpdates {
  # getUpdates JSON -> flat list of {UpdateId, ChatId, Text, Date}. Tolerates missing message/chat/text/
  # date and edited messages. Date (from Telegram's unix `date`) is what lets us ignore a stale backlog.
  # Returns the List so callers wrap with @() and enumerate (empty stays 0-count).
  param($Response)
  $out = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Response -or -not $Response.ok -or $null -eq $Response.result) { return $out }
  foreach ($u in $Response.result) {
    $msg = $u.message
    if ($null -eq $msg) { $msg = $u.edited_message }
    $chatId = $null; $text = $null; $date = $null
    if ($msg -and $msg.chat) { $chatId = $msg.chat.id }
    if ($msg) {
      $text = $msg.text
      if ($msg.date) { try { $date = [DateTimeOffset]::FromUnixTimeSeconds([long]$msg.date).LocalDateTime } catch { $date = $null } }
    }
    $out.Add([pscustomobject]@{ UpdateId = [long]$u.update_id; ChatId = $chatId; Text = $text; Date = $date })
  }
  return $out
}

function Select-ActionableUpdates {
  # Decide which of a fetched batch should ACTUALLY run. Fixes the 2026-07-16 incident: four queued
  # /debrief commands each ran a full ~3-minute generation and delivered four briefings minutes apart.
  # Two rules:
  #   1. STALENESS - a backlog older than MaxAgeMinutes is not acted on. After the laptop sleeps, the
  #      queue holds commands from ages ago; Alex does not want a briefing he asked for 40 minutes back.
  #   2. COLLAPSE - repeat/idempotent commands (debrief, status, help) keep only the LAST occurrence.
  #      Running /debrief four times produces four identical briefings and ~12 minutes of work.
  # Notes are NEVER collapsed: each note is distinct data and dropping one loses information.
  # Chat messages are NEVER collapsed: two questions are two questions, and collapsing silently loses one.
  # An update with an unknown date is acted on (dropping a real command silently is the worse failure).
  param($Updates, [datetime]$Now, [int]$MaxAgeMinutes = 10, [switch]$ChatEnabled)
  $fresh = New-Object System.Collections.Generic.List[object]
  foreach ($u in $Updates) {
    if ($null -ne $u.Date -and $u.Date -lt $Now.AddMinutes(-$MaxAgeMinutes)) { continue }   # stale
    $fresh.Add($u)
  }
  # keep the LAST update per collapsible command; keep every note AND every chat message.
  # -ChatEnabled MUST be threaded into Resolve-TelegramCommand here: without it, chat messages resolve
  # to 'help' and collapse into one, silently discarding questions (the 2026-07-16 bug class).
  $lastOf = @{}
  foreach ($u in $fresh) {
    $cmd = Resolve-TelegramCommand -Text $u.Text -ChatEnabled:$ChatEnabled
    if ($cmd -ne 'note' -and $cmd -ne 'chat') { $lastOf[$cmd] = $u.UpdateId }
  }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($u in $fresh) {
    $cmd = Resolve-TelegramCommand -Text $u.Text -ChatEnabled:$ChatEnabled
    if ($cmd -eq 'note' -or $cmd -eq 'chat') { $out.Add($u); continue }
    if ($lastOf[$cmd] -eq $u.UpdateId) { $out.Add($u) }   # superseded duplicates are dropped
  }
  return $out
}

function Get-NextOffset {
  # Telegram consumes a batch when you next call getUpdates with (highest update_id + 1).
  param($Updates)
  $max = -1
  foreach ($u in $Updates) { if ($u.UpdateId -gt $max) { $max = $u.UpdateId } }
  if ($max -lt 0) { return $null }
  return $max + 1
}

function Format-JobMailAlert {
  # Compose a push from classified alerts. Returns $null when nothing is worth pinging (digests/generic).
  param($Alerts)
  $hot = @($Alerts | Where-Object { $_.Classification -in @('interview','offer','rejection') })
  if ($hot.Count -eq 0) { return $null }
  $lines = foreach ($a in $hot) { "$($a.Classification.ToUpper()) - $($a.Subject)" }
  return "Sir, application news:`n" + ($lines -join "`n")
}

function Limit-Text {
  # Telegram caps a message at 4096 chars; keep well under and mark the cut.
  param([string]$Text, [int]$Max = 3900)
  if (-not $Text) { return $Text }
  if ($Text.Length -le $Max) { return $Text }
  return $Text.Substring(0, $Max) + "`n...(truncated - full note on the desktop, Sir)"
}

function Split-TelegramText {
  # Split into <=Max-char chunks on line boundaries where possible (Telegram caps a message at 4096) so a
  # long debrief is delivered whole rather than truncated. A single over-long line is hard-split. Pure.
  param([string]$Text, [int]$Max = 3900)
  $chunks = New-Object System.Collections.Generic.List[string]
  if (-not $Text) { return $chunks }
  $cur = ''
  foreach ($line0 in ($Text -split "`n")) {
    $line = $line0
    while ($line.Length -gt $Max) {                       # a line longer than the cap: flush, then hard-split
      if ($cur -ne '') { $chunks.Add($cur); $cur = '' }
      $chunks.Add($line.Substring(0, $Max)); $line = $line.Substring($Max)
    }
    $candidate = if ($cur -eq '') { $line } else { "$cur`n$line" }
    if ($candidate.Length -le $Max) { $cur = $candidate }
    else { if ($cur -ne '') { $chunks.Add($cur) }; $cur = $line }
  }
  if ($cur -ne '') { $chunks.Add($cur) }
  return $chunks
}

# ---------- network + side-effecting (guarded behind -DotSourceOnly) ----------

function Get-TelegramCred {
  if (-not (Test-Path $CredPath)) { throw "Missing $CredPath - run telegram-bot.ps1 -StoreCredential first." }
  $c = Import-Clixml $CredPath
  return [pscustomobject]@{ ChatId = $c.UserName; Token = $c.GetNetworkCredential().Password }
}

function Invoke-TelegramApi {
  param([string]$Token, [string]$Method, [hashtable]$Body)
  return Invoke-RestMethod -Uri "$ApiBase/bot$Token/$Method" -Method Post -Body $Body -TimeoutSec 65
}

function Send-Telegram {
  # Self-only (Safety 2): refuse any chat id other than the stored owner, BEFORE the network call, so a
  # prompt-injected Jarvis cannot exfiltrate to a third party.
  param([string]$Text, $ToChatId, $Cred)
  if (-not $Cred) { $Cred = Get-TelegramCred }
  if (-not $ToChatId) { $ToChatId = $Cred.ChatId }
  if (-not (Test-TelegramSenderAllowed $ToChatId $Cred.ChatId)) {
    throw "Safety rule 2 (self-only): refusing to send to chat '$ToChatId' - locked to $($Cred.ChatId)."
  }
  return Invoke-TelegramApi -Token $Cred.Token -Method 'sendMessage' `
    -Body @{ chat_id = $ToChatId; text = $Text; disable_web_page_preview = 'true' }
}

function Send-DebriefTelegram {
  # Deliver a debrief note to Alex's Telegram (self-only via Send-Telegram). Strips frontmatter and
  # splits into <=4096-char chunks so a long briefing is never truncated. Throws on failure so the 08:30
  # wrapper's try/catch turns it into a loud FAILED rather than a silent miss.
  param([string]$NotePath, $Cred)
  if (-not $Cred) { $Cred = Get-TelegramCred }
  if (-not (Test-Path $NotePath)) { throw "no debrief note at $NotePath" }
  $body = Get-Content -LiteralPath $NotePath -Raw -Encoding UTF8
  $body = [regex]::Replace($body, '(?s)\A\s*---\r?\n.*?\r?\n---\r?\n', '').TrimStart()   # strip frontmatter
  $parts = @(Split-TelegramText $body 3900)
  if ($parts.Count -eq 0) { throw "debrief note is empty - not sending" }
  foreach ($chunk in $parts) { Send-Telegram -Text $chunk -Cred $Cred | Out-Null }
}

function Save-Capture {
  # Append a texted note to the vault capture file (12-jarvis - an allowed write target, Safety 7). The
  # note is DATA: written literally via Add-Content, NEVER executed. Newlines are flattened to keep one
  # note per line. Returns the note text.
  param([string]$Text)
  $f = Join-Path $VAULT 'CAPTURE.md'
  $line = '- [' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + '] ' + ($Text -replace '\r?\n', ' ')
  Add-Content -Encoding UTF8 -Path $f -Value $line
  return $Text
}

function Get-RecentCaptures {
  param([int]$N = 10)
  $f = Join-Path $VAULT 'CAPTURE.md'
  if (-not (Test-Path $f)) { return '' }
  $lines = @(Get-Content $f | Where-Object { $_ -match '^\s*- \[' })
  if ($lines.Count -eq 0) { return '' }
  return (($lines | Select-Object -Last $N) -join "`n")
}

function Get-TodayDebriefText {
  $iso = (Get-Date).ToString('yyyy-MM-dd')
  $p = Join-Path $VAULT ("debriefs\$iso.md")
  if (-not (Test-Path $p)) { return $null }
  $t = Get-Content -LiteralPath $p -Raw -Encoding UTF8
  $t = [regex]::Replace($t, '(?s)\A\s*---\r?\n.*?\r?\n---\r?\n', '').TrimStart()   # strip frontmatter
  return $t
}

function Get-StatusText {
  $parts = New-Object System.Collections.Generic.List[string]
  try {
    $s = & (Join-Path $BIN 'scheduler-status.ps1') | ConvertFrom-Json
    $en = if ($s.enabled) { 'enabled' } else { 'disabled' }
    $nx = if ($s.nextRun) { $s.nextRun } else { 'unknown' }
    $parts.Add("Debrief task: $en; next $nx")
  } catch { $parts.Add('Debrief task: status unavailable') }
  $hb = Join-Path $HOME '.jarvis\bank-heartbeat.json'
  if (Test-Path $hb) {
    try {
      $h = (Get-Content $hb -Raw) -replace '^\xEF\xBB\xBF','' | ConvertFrom-Json
      $parts.Add("Bank feed: " + $(if ($h.ok) { "ok (as of $($h.asOf))" } else { "error" }))
    } catch { }
  }
  $note = Get-TodayDebriefText
  $parts.Add($(if ($note) { "Today's debrief: written." } else { "Today's debrief: not yet." }))
  return "At your service, Sir.`n" + ($parts -join "`n")
}

function Invoke-TelegramCommand {
  param([string]$Command, [string]$Text, $Cred)
  switch ($Command) {
    'debrief' {
      Send-Telegram -Text 'On it, Sir. Generating your debrief now - it will arrive here shortly.' -Cred $Cred | Out-Null
      # -Channel telegram makes the wrapper deliver the finished note to Telegram itself (chunked). We do
      # NOT also send it here - that double-sent the briefing. On failure the wrapper alarms on the PC.
      try { & (Join-Path $BIN 'jarvis-debrief.ps1') -Channel telegram -OnDemand | Out-Null }
      catch { Send-Telegram -Text "The debrief run failed, Sir: $($_.Exception.Message)" -Cred $Cred | Out-Null }
    }
    'status' { Send-Telegram -Text (Get-StatusText) -Cred $Cred | Out-Null }
    'note' {
      $payload = Get-NotePayload $Text
      if (-not $payload) { Send-Telegram -Text 'What should I note, Sir? e.g. "note buy protein".' -Cred $Cred | Out-Null }
      else { $null = Save-Capture $payload; Send-Telegram -Text "Noted, Sir: $payload" -Cred $Cred | Out-Null }
    }
    'notes' {
      $recent = Get-RecentCaptures 10
      Send-Telegram -Text $(if ($recent) { "Recent notes, Sir:`n$recent" } else { 'No notes captured yet, Sir.' }) -Cred $Cred | Out-Null
    }
    'chat' {
      # Read-only remote turn. Pre-fetch runs FIXED collectors here in PowerShell; the agent itself
      # only ever gets Read/Glob/Grep (see telegram-chat.ps1 for the full contract).
      $names     = Get-ChatPrefetch -Text $Text
      $collector = Invoke-ChatPrefetch -Names $names -BinDir $BIN
      $nonce     = New-ChatNonce
      # A SECOND, independent per-turn token: the receipt. It rides on the prompt's last line and the
      # reply has to carry it back, which is what makes "the model was given the whole message" an
      # observation rather than an inference from pipe state (see Invoke-ChatTurn's receipt gate).
      # Drawn separately from the fence nonce and re-drawn on the astronomically unlikely collision,
      # because Build-ChatPrompt treats the two being equal as a programming error and throws - and a
      # throw here would take the poller down.
      $receipt   = New-ChatNonce
      while ($receipt -eq $nonce) { $receipt = New-ChatNonce }
      $prompt    = Build-ChatPrompt -Message $Text -Persona (Get-ChatPersona) `
                     -CollectorText $collector -History (Get-ChatHistory -Turns 6) -Nonce $nonce -Receipt $receipt
      $reply     = Invoke-ChatTurn -Prompt $prompt -ScopeDir $VAULT -Receipt $receipt -TimeoutSec 180
      if (-not $reply) {
        # Invoke-ChatTurn returns $null for MANY causes - a missing/corrupt token, a non-zero claude
        # exit, empty output, a refused scope, a failed setup write - and only SOMETIMES a timeout.
        # This line used to name the timeout regardless, so every other failure reached Alex as a
        # confident, specific, and false account of what happened. Jarvis does not state what it does
        # not know: say plainly that nothing came back and that the reason is not known here.
        $reply = 'Nothing came back from that one, Sir - and I cannot tell you why. Try again, or ask me at the desk.'
      }
      # Fix 4: SEND before logging. The reply already cost an up-to-180s model run; logging used to run
      # first, so a disk-full, a file lock from a concurrent manual run, or an unset $HOME throwing here
      # discarded a reply that had already succeeded. Delivering the reply matters more than the audit
      # trail, so send first. The log write is then wrapped in its own try/catch: a failure there must
      # not propagate past this point either, since an uncaught throw here would stop the caller
      # (Invoke-PollOnce) from counting this turn as handled - which Fix 5's warm-window gate depends on.
      # Trade-off, accepted: a failed log write means this turn is silently missing from the audit trail
      # rather than retried - the reply already reached Alex either way.
      foreach ($chunk in @(Split-TelegramText $reply 3900)) { Send-Telegram -Text $chunk -Cred $Cred | Out-Null }
      try { Write-ChatLog -Message $Text -Reply $reply } catch { Write-Warning "chat log write failed (reply already sent): $($_.Exception.Message)" }
    }
    default  {
      $extra = if (Test-ChatEnabled -VaultPath $VAULT) { ' You can also just ask me things in plain English, Sir.' } else { '' }
      Send-Telegram -Text ('I take: /debrief, /status, "note <text>" to jot something down, and /notes to read them back, Sir.' + $extra + ' Full conversation is on the desktop (Ctrl+Shift+J).') -Cred $Cred | Out-Null
    }
  }
}

function Read-Offset { if (Test-Path $OffsetPath) { try { return (Get-Content $OffsetPath -Raw | ConvertFrom-Json).offset } catch { return $null } } return $null }
function Write-Offset { param($Offset) @{ offset = $Offset } | ConvertTo-Json | Set-Content -Encoding ASCII $OffsetPath }

function Invoke-PollOnce {
  # One long-poll: fetch, act on allowed commands, advance the offset. Returns count handled.
  param($Cred, [int]$TimeoutSec = 30)
  $chatOn = Test-ChatEnabled -VaultPath $VAULT
  $offset = Read-Offset
  $body = @{ timeout = $TimeoutSec }
  if ($offset) { $body.offset = $offset }
  $resp = Invoke-TelegramApi -Token $Cred.Token -Method 'getUpdates' -Body $body
  $ups = @(Parse-TelegramUpdates $resp)
  # Collapse repeats + ignore a stale backlog BEFORE doing any work (see Select-ActionableUpdates).
  $act = @{}
  foreach ($a in @(Select-ActionableUpdates -Updates $ups -Now (Get-Date) -MaxAgeMinutes 10 -ChatEnabled:$chatOn)) { $act[[string]$a.UpdateId] = $true }
  $handled = 0
  # Fix 5: report whether a CHAT turn specifically was handled this poll, via a script-scope flag rather
  # than changing this function's int return - $handled's meaning (count of handled commands, any kind)
  # stays exactly what existing callers and tests already rely on. The -Once dispatch below reads this
  # flag to decide whether to open the warm window: that window exists for conversational latency, so
  # texting /status (or any non-chat command) must never hold the process open for it.
  $script:JarvisChatTurnHandled = $false
  foreach ($u in $ups) {
    # CONSUME FIRST (at-most-once). /debrief takes ~3 minutes; if this process is killed mid-command
    # (ExecutionTimeLimit, sleep, reboot) an offset written only at the END of the batch means the whole
    # batch REPLAYS on the next poll - forever. That is the 2026-07-16 duplicate-briefing incident.
    # Losing one command to a crash is strictly better than delivering it five times.
    Write-Offset ($u.UpdateId + 1)
    if (-not (Test-TelegramSenderAllowed $u.ChatId $Cred.ChatId)) { continue }   # self-only
    $cmd = Resolve-TelegramCommand -Text $u.Text -ChatEnabled:$chatOn
    if (-not $act.ContainsKey([string]$u.UpdateId)) {
      # Stale or superseded. A superseded /debrief is silently dropped (that IS the fix). But a stale
      # QUESTION deserves a word: silence is what made Alex press /debrief four times on 2026-07-16.
      # Cheap acknowledgement, no model call.
      if ($cmd -eq 'chat' -and $null -ne $u.Date) {
        try {
          Send-Telegram -Text ("That came in at $($u.Date.ToString('HH:mm')), Sir. I have let it lie - ask again if it still matters.") -Cred $Cred | Out-Null
        } catch { }
      }
      continue
    }
    try {
      Invoke-TelegramCommand -Command $cmd -Text $u.Text -Cred $Cred
      $handled++
      if ($cmd -eq 'chat') { $script:JarvisChatTurnHandled = $true }
    }
    catch { Write-Warning "command failed (dropped, not retried): $($_.Exception.Message)" }
  }
  return $handled
}

if ($DotSourceOnly) { return }

# ---------- mode dispatch ----------
if ($StoreCredential) {
  if (-not $Token) {
    $sec = Read-Host -AsSecureString 'Paste your BotFather token'
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  }
  Write-Host 'Detecting your chat id (make sure you have already messaged the bot at least once)...'
  $resp = Invoke-TelegramApi -Token $Token -Method 'getUpdates' -Body @{ timeout = 0 }
  $ups = @(Parse-TelegramUpdates $resp)
  # Fail closed when binding the owner: the bot's @username is public, so a stranger could have messaged
  # it. Require EXACTLY one distinct chat id, else refuse rather than silently binding the wrong owner.
  $chatIds = @($ups | Where-Object { $_.ChatId } | ForEach-Object { "$($_.ChatId)" } | Select-Object -Unique)
  if ($chatIds.Count -eq 0) { throw 'No chat id found - message your bot ("hi") in Telegram first, then re-run -StoreCredential.' }
  if ($chatIds.Count -gt 1) { throw "Ambiguous owner: getUpdates shows more than one chat id ($($chatIds -join ', ')). Someone else may have messaged your bot. Make sure only YOU have, then re-run -StoreCredential." }
  $chatId = $chatIds[0]
  $dir = Split-Path $CredPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }   # Export-Clixml won't create it
  $sec = ConvertTo-SecureString $Token -AsPlainText -Force
  New-Object System.Management.Automation.PSCredential("$chatId", $sec) | Export-Clixml $CredPath
  Write-Host "Stored (DPAPI-encrypted to this Windows user): $CredPath  (owner chat id $chatId)"
  Write-Host 'Secrets never go in the repo or vault (Safety 6). Next: flip CONFIG.md modules: telegram: on'
  exit 0
}

$cred = Get-TelegramCred

if ($Send) {
  if (-not $Text) { throw '-Send requires -Text' }
  Send-Telegram -Text $Text -Cred $cred | Out-Null
  Write-Host 'Sent.'
  exit 0
}

if ($AlertJobMail) {
  . (Join-Path $BIN 'check-job-mail.ps1') -DotSourceOnly
  $res = Get-JobMail -SinceHours $SinceHours -SenderFilter 'linkedin|indeed|gradireland|glassdoor|jobs\.ie|irishjobs|mastercard|workday|myworkday|maynooth|nuim\.ie|vodafone' -MaxMessages 40 -Mode 'jobs'
  $msg = Format-JobMailAlert $res.JobAlerts
  if ($msg) { Send-Telegram -Text $msg -Cred $cred | Out-Null; Write-Host 'Alert sent.' }
  else { Write-Host 'No status-change mail to alert on.' }
  exit 0
}

if ($Once) {
  # WARM WINDOW: a scheduled -Once run normally handles a batch and exits, which is right for
  # fire-and-forget commands but means up to 3 minutes of dead air per conversational turn. When chat
  # is on and something was actually handled, stay on a bounded long-poll loop so replies during an
  # active conversation are near-instant, then exit and let the 3-minute schedule resume.
  # Deliberately BOUNDED, not persistent: a permanent -Poll process is the RAM cost this machine's
  # 3-minute schedule was chosen to avoid.
  # Expect the next scheduled tick to be refused as 0x800710E0 while this window is open. That is
  # CORRECT (this loop is doing the polling), not the 2026-07-16 stacking bug.
  $n = Invoke-PollOnce -Cred $cred -TimeoutSec 30
  # Fix 5: gate on a CHAT turn having actually been handled, not on $n -gt 0 (any handled command). The
  # old gate opened this window for /status, /debrief, notes - anything - holding this process (and
  # blocking the next scheduled tick) for 5 minutes a plain command never needed. Worse, a /debrief
  # (~3 min) plus a re-armed 5-minute window was the combination most likely to hit the scheduled
  # task's hard 10-minute ExecutionTimeLimit. The warm window exists for conversational latency, so it
  # opens only when a chat turn was handled.
  if ($script:JarvisChatTurnHandled -and (Test-ChatEnabled -VaultPath $VAULT)) {
    $warmUntil = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $warmUntil) {
      try {
        $m = Invoke-PollOnce -Cred $cred -TimeoutSec 50
        $n += $m
        if ($script:JarvisChatTurnHandled) { $warmUntil = (Get-Date).AddMinutes(5) }   # keep the window alive while he is talking
      } catch {
        Write-Warning $_.Exception.Message
        Start-Sleep -Seconds 5
      }
    }
  }
  Write-Host "Handled $n update(s)."
  exit 0
}

if ($Poll) {
  Write-Host 'Long-polling for commands (Ctrl+C to stop). Self-only; only your chat id is honoured.'
  while ($true) { try { Invoke-PollOnce -Cred $cred -TimeoutSec 50 | Out-Null } catch { Write-Warning $_.Exception.Message; Start-Sleep -Seconds 5 } }
}

Write-Host 'Nothing to do. Use -Send / -Once / -Poll / -AlertJobMail (or -StoreCredential for first-time setup).'
