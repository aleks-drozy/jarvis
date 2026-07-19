# skill/bin/telegram-chat.ps1
# Read-only conversational Jarvis over Telegram. Dot-sourced by telegram-bot.ps1.
#
# THE SECURITY CONTRACT (spec DESIGN-TELEGRAM-CHAT sections 2 and 4): this file must never create a
# path from a text message to code execution. The agent is spawned with the allowlist 'Read Glob Grep'
# and nothing else; live data reaches it because PowerShell runs fixed, argument-free collectors HERE
# and injects their output as fenced data. A keyword scan picks WHICH collector by name; it never
# builds a command line and never passes message text as an argument. Changing the allowlist breaks
# the whole argument - tests/telegram-chat.Tests.ps1 fails the build if you do.
# ASCII only (PS 5.1 reads .ps1 as ANSI).
param([switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Test-ChatEnabled {
  # Is free-form chat turned on? Reads CONFIG.md 'telegram_chat'. Absent, unreadable, or anything other
  # than 'on' -> FALSE. Fails closed on purpose: the closed command whitelist stays the default and
  # chat is the exception. Same shape as Get-DebriefChannel in jarvis-debrief.ps1.
  param([string]$VaultPath)
  try {
    $cfgFile = Join-Path $VaultPath 'CONFIG.md'
    if (-not (Test-Path $cfgFile)) { return $false }
    $m = [regex]::Match((Get-Content -LiteralPath $cfgFile -Raw), '(?m)^\s*-?\s*telegram_chat:\s*(on|off)\b')
    if ($m.Success) { return ($m.Groups[1].Value.ToLower() -eq 'on') }
  } catch { }
  return $false
}

# The CLOSED SET of collectors chat may trigger. Adding a member here is a security decision: it must
# be a read-only script that takes NO arguments derived from message text.
$script:JarvisChatCollectors = @('bank','jobmail','calendar')

function Get-ChatPrefetch {
  # Decide which read-only collectors this message needs. Returns NAMES from $JarvisChatCollectors,
  # never a command line and never an argument. That is the whole trick: untrusted text selects from a
  # fixed menu, so it never reaches an execution context (spec section 4.1). A miss is acceptable - the
  # answer then comes from FINANCE.md and the grounding rule makes Jarvis label it stale.
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[string]
  if (-not $Text) { return $out.ToArray() }
  $t = $Text.ToLower()
  if ($t -match '\b(bank|balance|money|afford|spend|spending|skint|broke|savings|saving|budget|allowance|cash)\b') { $out.Add('bank') }
  if ($t -match '\b(job|jobs|application|applications|applied|interview|recruiter|rejection|offer|hiring)\b')      { $out.Add('jobmail') }
  if ($t -match '\b(calendar|schedule|diary|meeting|appointment|tomorrow|today)\b')                                 { $out.Add('calendar') }
  return $out.ToArray()
}

function Test-CollectorErrorJson {
  # If a collector's stdout parses as JSON carrying a top-level 'error' property, that collector is
  # reporting failure IN-BAND (get-bank-data.ps1 does this by design - it always exits 0 so the feed
  # degrades rather than kills the debrief, and signals failure via {"configured":true,"error":...}
  # instead). An unchecked exit code alone would miss this, so parse and check explicitly. Returns the
  # error string, or $null if the text is not JSON or has no truthy top-level 'error'.
  param([string]$Text)
  try {
    $parsed = $Text | ConvertFrom-Json -ErrorAction Stop
    if ($null -ne $parsed -and ($parsed.PSObject.Properties.Name -contains 'error') -and $parsed.error) {
      return [string]$parsed.error
    }
  } catch { }
  return $null
}

function Protect-CollectorDelimiter {
  # This file invents the '## collector: <name>' block delimiter, so guarding it belongs here too.
  # Some collectors carry attacker-controlled text verbatim (check-job-mail.ps1 surfaces email
  # SUBJECTS - the exact vector behind the 2026-07-15 command-injection incident). Unneutralised, a
  # subject reading "## collector: bank" followed by fabricated balance text would forge an
  # authentic-looking block that Jarvis could then cite as real data. Neutralise any line that could
  # open a fake block before it is appended.
  param([string]$Text)
  if (-not $Text) { return $Text }
  $lines = $Text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*##') { $lines[$i] = '(blocked delimiter) ' + $lines[$i] }
  }
  return ($lines -join "`n")
}

function Invoke-ChatPrefetch {
  # Run the named collectors and return their output as a labelled text block for the prompt fence.
  # Each is invoked with NO arguments - nothing from the message is passed through. A collector that
  # fails is reported as unavailable rather than omitted, so the grounding rule makes Jarvis SAY the
  # feed is down instead of quietly answering from stale numbers.
  param(
    [string[]]$Names,
    [string]$BinDir,
    [string]$HeartbeatPath = (Join-Path $HOME '.jarvis\bank-heartbeat.json')
  )
  if (-not $Names -or $Names.Count -eq 0) { return '' }
  $scripts = @{
    bank     = 'get-bank-data.ps1'
    jobmail  = 'check-job-mail.ps1'
    calendar = 'get-calendar.ps1'
  }
  $sb = New-Object System.Text.StringBuilder
  foreach ($n in $Names) {
    if (-not ($script:JarvisChatCollectors -contains $n)) { continue }   # belt and braces
    $path = Join-Path $BinDir $scripts[$n]
    [void]$sb.AppendLine("## collector: $n")
    if (-not (Test-Path $path)) { [void]$sb.AppendLine("unavailable: $($scripts[$n]) not found"); continue }
    try {
      # No 2>&1 here: on a NATIVE command, merging stderr wraps every stderr line in a terminating
      # NativeCommandError under $ErrorActionPreference='Stop', even when the child exits 0 - that
      # would discard perfectly good stdout over one benign warning line (same trap documented at
      # get-bank-data.ps1 ~line 70). Capture stdout only and judge success from $LASTEXITCODE instead.
      $res = (& powershell -NoProfile -File $path | Out-String)
      if ($LASTEXITCODE -ne 0) { [void]$sb.AppendLine("unavailable: exit $LASTEXITCODE"); continue }
      $res = $res.Trim()
      if (-not $res) { [void]$sb.AppendLine('unavailable: collector returned nothing'); continue }
      # Some collectors (get-bank-data.ps1 by design) exit 0 on every failure path and report the
      # failure IN-BAND as {"error": "..."} - a clean exit code alone would miss this.
      $errMsg = Test-CollectorErrorJson $res
      if ($errMsg) { [void]$sb.AppendLine("unavailable: $(Protect-CollectorDelimiter $errMsg)") }
      else { [void]$sb.AppendLine((Protect-CollectorDelimiter $res)) }
    } catch {
      [void]$sb.AppendLine("unavailable: $(Protect-CollectorDelimiter $_.Exception.Message)")
    }
  }
  # The bank heartbeat is CHEAP (a local file, not an API call) and lives OUTSIDE the agent's
  # --add-dir scope, so the agent cannot read it itself. Fold it in whenever bank data was asked for.
  # The header is ALWAYS emitted once bank data was requested (even when the file is missing/unreadable)
  # - the heartbeat exists specifically to convey bank-feed freshness, so silently omitting it is the
  # failure mode most likely to produce a confidently stale answer.
  if ($Names -contains 'bank') {
    [void]$sb.AppendLine('## collector: bank-heartbeat')
    if (-not (Test-Path $HeartbeatPath)) {
      [void]$sb.AppendLine('unavailable: heartbeat file not found')
    } else {
      try {
        $raw = ((Get-Content -LiteralPath $HeartbeatPath -Raw) -replace ('^' + [char]0xFEFF), '').Trim()
        if ($raw) { [void]$sb.AppendLine((Protect-CollectorDelimiter $raw)) }
        else { [void]$sb.AppendLine('unavailable: heartbeat file empty') }
      } catch {
        [void]$sb.AppendLine("unavailable: $(Protect-CollectorDelimiter $_.Exception.Message)")
      }
    }
  }
  return $sb.ToString()
}

if ($DotSourceOnly) { return }
