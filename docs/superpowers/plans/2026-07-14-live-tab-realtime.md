# Real-Time Live Tab + Tray Health — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the desktop app's Live tab show accurate, Jarvis-specific state pushed in real time, and finally give the tray icon the health colour (green/amber/grey/busy) the original design called for.

**Architecture:** One `liveState` object in `app/main.js`, updated by watchers/polls, fanned to both the dashboard (a `data:live` IPC push) and the tray (`updateTrayHealth()`) through one debounced `pushLive()`. All state-collapsing logic lives in a pure, unit-tested module (`app/lib/livestate.js`); the Electron layer is thin glue verified manually.

**Tech Stack:** Electron (main + preload + renderer), Node.js, Windows PowerShell 5.1 collectors, pngjs (dev-only, for icon generation), plain-assertion tests (`tests/*.Tests.ps1`) + node for the pure module.

**Spec:** `docs/superpowers/specs/2026-07-14-live-tab-realtime-design.md`

## Global Constraints

- **Pure ASCII in every `.ps1` file** — enforced by a byte scan in tests (repo battle scar). No em dashes, no unicode.
- **`openssl`/native-command stderr** must never be merged with `2>&1` under `$ErrorActionPreference='Stop'` — discard with `2>$null` and check `$LASTEXITCODE` (repo battle scar). (Not relevant to new scripts here, but hold the rule.)
- **Single-writer principle:** the Electron app shell writes NOTHING to the vault. New on-disk writes (`bank-heartbeat.json`, `consent_expires` in `bank.json`) are done by the PowerShell scripts only. The app reads.
- **Redundancy invariant:** the 08:30 email path stays fully independent. Nothing in this plan may make the briefing depend on the app.
- **Read-only bank guarantee:** no code path references the `/payments` endpoint (already test-enforced in `tests/get-bank-data.Tests.ps1`).
- **`liveState` health values:** exactly one of `'normal' | 'amber' | 'grey' | 'busy' | 'unknown'`.
- **Tray task ExecutionTimeLimit:** 15 minutes (`scripts/register-task.ps1`) — the staleness threshold for a stuck "running".
- **Run the whole suite green after any task that adds/changes a test:** `Get-ChildItem tests\*.Tests.ps1 | %{ powershell -NoProfile -File $_.FullName }` — every file must exit 0.

---

### Task 1: Pure module — `parseLogTail` + node test harness

**Files:**
- Create: `app/lib/livestate.js`
- Create: `tests/livestate.node.js` (node assertions)
- Create: `tests/livestate.Tests.ps1` (PS wrapper so it joins the uniform suite)

**Interfaces:**
- Produces: `parseLogTail(lines: string[], now: Date) => { lastRun: string|null, lastResult: 'ok'|'failed'|null, lastRunLate: bool, running: bool, stalled: bool }` and the constant `RUN_LIMIT_MS = 900000`.

- [ ] **Step 1: Write the failing test** — create `tests/livestate.node.js`:

```js
// tests/livestate.node.js - node assertions for app/lib/livestate.js (pure logic, no Electron).
const LS = require('../app/lib/livestate');
let fails = 0;
function ok(cond, msg) { if (!cond) { console.log('FAIL: ' + msg); fails++; } }
const NOW = new Date('2026-07-14T10:30:00');

// parseLogTail
(() => {
  const start = ['2026-07-14T10:29:00 run start'];
  let r = LS.parseLogTail(start, NOW);
  ok(r.running === true && r.stalled === false, 'run start with no terminal -> running');
  ok(r.lastRun === '2026-07-14T10:29:00', 'running lastRun = start ts');

  r = LS.parseLogTail(['2026-07-14T08:30:03 run start', '2026-07-14T08:33:46 run ok (note written 08:32)'], NOW);
  ok(r.running === false && r.lastResult === 'ok', 'start + ok -> ok');
  ok(r.lastRunLate === false, 'plain ok is not late');

  r = LS.parseLogTail(['2026-07-14T08:30:03 run start', '2026-07-14T10:04:31 run ok (note written 10:07) [late catch-up]'], NOW);
  ok(r.lastResult === 'ok' && r.lastRunLate === true, 'late tag -> lastRunLate true');

  r = LS.parseLogTail(['2026-07-14T08:30:03 run start', '2026-07-14T08:33:46 run FAILED: boom'], NOW);
  ok(r.lastResult === 'failed' && r.running === false, 'start + FAILED -> failed');

  r = LS.parseLogTail([], NOW);
  ok(r.running === false && r.lastResult === null && r.lastRun === null, 'empty -> never');

  // stalled: run start 20 min ago (> 15 min limit), no terminal line
  r = LS.parseLogTail(['2026-07-14T10:09:00 run start'], NOW);
  ok(r.running === false && r.stalled === true, 'start older than 15min -> stalled, not running');

  // ignores unrelated lines
  r = LS.parseLogTail(['2026-07-14T10:29:00 run start', 'garbage line'], NOW);
  ok(r.running === true, 'non-run lines are ignored');
})();

if (fails > 0) { console.log(fails + ' assertion(s) FAILED'); process.exit(1); }
console.log('livestate.node: ALL PASS');
```

- [ ] **Step 2: Create the PS wrapper** `tests/livestate.Tests.ps1`:

```powershell
# tests/livestate.Tests.ps1 - runs the node assertions for app/lib/livestate.js
$ErrorActionPreference = 'Stop'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Error 'FAIL: node not found (app tests need Node)'; exit 1 }
node "$PSScriptRoot\livestate.node.js"
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "livestate: ALL PASS"
```

- [ ] **Step 3: Run it, verify it fails**

Run: `powershell -NoProfile -File tests/livestate.Tests.ps1`
Expected: FAIL (exit 1) — `Cannot find module '../app/lib/livestate'`.

- [ ] **Step 4: Write minimal implementation** — create `app/lib/livestate.js`:

```js
// app/lib/livestate.js - pure, testable live-state logic. NO Electron, NO I/O.
'use strict';

// Task ExecutionTimeLimit from scripts/register-task.ps1 (15 min). A run still marked "running"
// past this is treated as stalled, not a perpetual spinner.
const RUN_LIMIT_MS = 15 * 60 * 1000;

// Parse the tail of .jarvis.log (raw lines, most recent last) into current scheduler run state.
// Line formats, all "<ISO-8601 seconds> <message>":
//   "2026-07-14T08:30:03 run start"
//   "2026-07-14T08:33:46 run ok (note written 08:32)"   [+ optional " [late catch-up]"]
//   "2026-07-14T08:33:46 run FAILED: <error>"
function parseLogTail(lines, now) {
  const rows = (lines || [])
    .map((l) => (l || '').trim())
    .filter((l) => /\brun (start|ok|FAILED)\b/.test(l));
  const out = { lastRun: null, lastResult: null, lastRunLate: false, running: false, stalled: false };
  if (rows.length === 0) return out;
  const last = rows[rows.length - 1];
  const ts = (last.match(/^(\S+)/) || [])[1] || null;
  out.lastRun = ts;
  if (/\brun start\b/.test(last)) {
    const started = ts ? Date.parse(ts) : NaN;
    if (!isNaN(started) && now.getTime() - started > RUN_LIMIT_MS) { out.stalled = true; }
    else { out.running = true; }
  } else if (/\brun ok\b/.test(last)) {
    out.lastResult = 'ok';
    out.lastRunLate = /\[late catch-up\]/.test(last);
  } else if (/\brun FAILED\b/.test(last)) {
    out.lastResult = 'failed';
  }
  return out;
}

module.exports = { parseLogTail, RUN_LIMIT_MS };
```

- [ ] **Step 5: Run test to verify it passes**

Run: `powershell -NoProfile -File tests/livestate.Tests.ps1`
Expected: PASS — `livestate: ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add app/lib/livestate.js tests/livestate.node.js tests/livestate.Tests.ps1
git commit -m "feat(app): pure parseLogTail for live scheduler state + node test harness"
```

---

### Task 2: Pure module — `deriveHealth`, `bankDaysLeft`, `chooseTrayIcon`, `pillFor`, `tooltipFor`

**Files:**
- Modify: `app/lib/livestate.js`
- Modify: `tests/livestate.node.js`

**Interfaces:**
- Consumes: `parseLogTail`, `RUN_LIMIT_MS` (Task 1).
- Produces:
  - `bankDaysLeft(state, now) => number|null`
  - `deriveHealth(state, now) => 'normal'|'amber'|'grey'|'busy'|'unknown'`
  - `chooseTrayIcon(health) => string` (asset basename, no extension)
  - `pillFor(health) => { label: string, cls: string }`
  - `tooltipFor(state, now) => string`
- `state` is the `liveState` shape: `{ scheduler:{registered,enabled,state,nextRun,lastRun,lastResult,lastRunLate,running,stalled}, bank:{enabled,configured,ok,error,lastFetch,consentExpires}, chat:{inFlight} }`.

- [ ] **Step 1: Write the failing tests** — append to `tests/livestate.node.js` before the final `if (fails > 0)` block:

```js
// deriveHealth precedence
(() => {
  const base = { scheduler: { registered: true, enabled: true, running: false, stalled: false, lastResult: 'ok' },
                 bank: { enabled: false, configured: false, ok: null, consentExpires: null }, chat: { inFlight: false } };
  const clone = (o) => JSON.parse(JSON.stringify(o));

  ok(LS.deriveHealth(base, NOW) === 'normal', 'all good -> normal');

  let s = clone(base); s.chat.inFlight = true;
  ok(LS.deriveHealth(s, NOW) === 'busy', 'chat in flight -> busy');

  s = clone(base); s.scheduler.running = true;
  ok(LS.deriveHealth(s, NOW) === 'busy', 'running -> busy');

  s = clone(base); s.scheduler.running = true; s.scheduler.stalled = true;
  ok(LS.deriveHealth(s, NOW) === 'amber', 'stalled (not busy) -> amber');

  s = clone(base); s.scheduler.enabled = false;
  ok(LS.deriveHealth(s, NOW) === 'grey', 'disabled -> grey');

  s = clone(base); s.scheduler.enabled = false; s.scheduler.lastResult = 'failed';
  ok(LS.deriveHealth(s, NOW) === 'grey', 'grey OUTRANKS amber');

  s = clone(base); s.scheduler.lastResult = 'failed';
  ok(LS.deriveHealth(s, NOW) === 'amber', 'failed -> amber');

  s = clone(base); s.bank.enabled = true; s.bank.configured = true; s.bank.ok = false;
  ok(LS.deriveHealth(s, NOW) === 'amber', 'bank error -> amber');

  s = clone(base); s.bank.consentExpires = '2026-07-18'; // 4 days from NOW
  ok(LS.deriveHealth(s, NOW) === 'amber', 'consent < 7 days -> amber');

  s = clone(base); s.scheduler.registered = null; s.scheduler.enabled = null;
  ok(LS.deriveHealth(s, NOW) === 'unknown', 'scheduler check failed, nothing else wrong -> unknown');

  s = clone(base); s.scheduler.registered = null; s.scheduler.enabled = null; s.scheduler.lastResult = 'failed';
  ok(LS.deriveHealth(s, NOW) === 'amber', 'unknown scheduler but known failure -> amber');
})();

// bankDaysLeft
ok(LS.bankDaysLeft({ bank: { consentExpires: '2026-07-24' } }, NOW) === 10, 'bankDaysLeft = 10');
ok(LS.bankDaysLeft({ bank: { consentExpires: null } }, NOW) === null, 'no expiry -> null');
ok(LS.bankDaysLeft({ bank: { consentExpires: 'garbage' } }, NOW) === null, 'bad date -> null');

// chooseTrayIcon + pillFor
ok(LS.chooseTrayIcon('amber') === 'tray-amber', 'amber icon');
ok(LS.chooseTrayIcon('unknown') === 'tray-normal', 'unknown uses neutral tray icon (tooltip disambiguates)');
ok(LS.pillFor('grey').label === 'Off duty', 'grey pill label');
ok(LS.pillFor('busy').cls === 'busy', 'busy pill cls');

// tooltipFor
ok(/OFF DUTY/.test(LS.tooltipFor({ scheduler: { enabled: false, registered: true }, bank: {}, chat: {} }, NOW)), 'grey tooltip names off duty');
ok(/FAILED/.test(LS.tooltipFor({ scheduler: { registered: true, enabled: true, lastResult: 'failed', lastRun: '2026-07-14T08:33:46' }, bank: {}, chat: {} }, NOW)), 'failed tooltip names FAILED');
ok(/consent/.test(LS.tooltipFor({ scheduler: { registered: true, enabled: true, lastResult: 'ok' }, bank: { enabled: true, configured: true, ok: true, consentExpires: '2026-07-18' }, chat: {} }, NOW)), 'low-consent tooltip mentions consent');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -File tests/livestate.Tests.ps1`
Expected: FAIL — `LS.deriveHealth is not a function`.

- [ ] **Step 3: Write the implementation** — in `app/lib/livestate.js`, add these functions above `module.exports` and extend the export:

```js
// Days until the stored (requested) consent expiry; null if unknown/unparseable.
function bankDaysLeft(state, now) {
  const d = state && state.bank && state.bank.consentExpires;
  if (!d) return null;
  const exp = Date.parse(d + 'T00:00:00');
  if (isNaN(exp)) return null;
  return Math.floor((exp - now.getTime()) / (24 * 60 * 60 * 1000));
}

// Collapse liveState into a single glance-able health value. Precedence: busy > grey > amber/unknown.
function deriveHealth(state, now) {
  const s = (state && state.scheduler) || {};
  const b = (state && state.bank) || {};
  const chat = (state && state.chat) || {};
  if (chat.inFlight || (s.running && !s.stalled)) return 'busy';
  if (s.registered === false || s.enabled === false) return 'grey';   // grey outranks amber: a dead scheduler is worst
  const dl = bankDaysLeft(state, now);
  const amber =
       s.lastResult === 'failed'
    || s.stalled === true
    || (b.enabled && b.configured && b.ok === false)
    || (dl !== null && dl < 7);
  if (s.registered === null || s.enabled === null) return amber ? 'amber' : 'unknown';  // unknown != disabled
  return amber ? 'amber' : 'normal';
}

// health -> tray icon asset basename (files in app/assets/). Only 4 icons exist; 'unknown' rides the
// neutral glyph and lets the tooltip carry the "can't tell" nuance (spec: unknown -> neutral state).
function chooseTrayIcon(health) {
  switch (health) {
    case 'busy':  return 'tray-busy';
    case 'grey':  return 'tray-grey';
    case 'amber': return 'tray-amber';
    default:      return 'tray-normal';   // 'normal' and 'unknown'
  }
}

// health -> dashboard status pill.
function pillFor(health) {
  switch (health) {
    case 'busy':    return { label: 'Working...',     cls: 'busy' };
    case 'grey':    return { label: 'Off duty',       cls: 'grey' };
    case 'amber':   return { label: 'Attention',      cls: 'amber' };
    case 'unknown': return { label: 'Status unknown', cls: 'unknown' };
    default:        return { label: 'On duty',        cls: 'normal' };
  }
}

function hhmm(iso) { return (iso && iso.length >= 16) ? iso.slice(11, 16) : '?'; }

// A one-line tray tooltip that spells out WHY the colour is what it is (amber is ambiguous alone).
function tooltipFor(state, now) {
  const s = (state && state.scheduler) || {};
  const chat = (state && state.chat) || {};
  const health = deriveHealth(state, now);
  if (health === 'busy') return chat.inFlight ? 'Jarvis - answering you now...' : 'Jarvis - running a debrief now...';
  if (health === 'grey') return 'Jarvis - OFF DUTY: the 08:30 scheduler is disabled';
  if (health === 'amber') {
    if (s.lastResult === 'failed') return 'Jarvis - last run FAILED ' + hhmm(s.lastRun) + ', check the log';
    if (s.stalled) return 'Jarvis - a run may have stalled, check the log';
    const dl = bankDaysLeft(state, now);
    if (dl !== null && dl < 7) return 'Jarvis - bank consent expires in ' + dl + ' days, re-link Revolut';
    return 'Jarvis - attention needed, open the dashboard';
  }
  if (health === 'unknown') return 'Jarvis - scheduler state unknown right now';
  return 'Jarvis - next briefing ' + (s.nextRun ? hhmm(s.nextRun) : '08:30');
}

module.exports = { parseLogTail, RUN_LIMIT_MS, bankDaysLeft, deriveHealth, chooseTrayIcon, pillFor, tooltipFor };
```

Delete the old `module.exports` line from Task 1 (this one replaces it).

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -File tests/livestate.Tests.ps1`
Expected: PASS — `livestate: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/livestate.js tests/livestate.node.js
git commit -m "feat(app): deriveHealth/tray/pill/tooltip pure logic + tests"
```

---

### Task 3: `scheduler-status.ps1` collector

**Files:**
- Create: `skill/bin/scheduler-status.ps1`
- Create: `tests/scheduler-status.Tests.ps1`

**Interfaces:**
- Produces: stdout JSON `{ registered: bool, enabled: bool, state: string, nextRun: ISO|null }`, exit 0 always. Dot-source exposes `Get-SchedulerStatus -TaskName <name>`.

- [ ] **Step 1: Write the failing test** — create `tests/scheduler-status.Tests.ps1`:

```powershell
# tests/scheduler-status.Tests.ps1 - read-only Task Scheduler status collector
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }
$script = "$PSScriptRoot\..\skill\bin\scheduler-status.ps1"
Assert (Test-Path $script) "scheduler-status.ps1 must exist"

# Degradation: a missing task must still yield structured JSON + exit 0 (module isolation).
$raw = powershell -NoProfile -File $script -TaskName 'Definitely-No-Such-Task-XYZ'
Assert ($LASTEXITCODE -eq 0) "missing task must exit 0"
$j = ($raw -join "`n") | ConvertFrom-Json
Assert ($j.registered -eq $false) "missing task -> registered false"
Assert ($j.enabled -eq $false) "missing task -> enabled false"

# Dot-source: Get-SchedulerStatus returns a bool 'registered' for the real task name (present or not).
. $script -DotSourceOnly
$r = Get-SchedulerStatus -TaskName 'Jarvis Morning Debrief'
Assert ($r.registered -is [bool]) "registered must be a bool"

# ASCII purity (repo battle scar)
$bytes = [IO.File]::ReadAllBytes($script)
$bad = 0; for ($i=0; $i -lt $bytes.Length; $i++){ if ($bytes[$i] -gt 127){ $bad++ } }
Assert ($bad -eq 0) "scheduler-status.ps1 must be pure ASCII (found $bad)"

Write-Host "scheduler-status: ALL PASS"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `powershell -NoProfile -File tests/scheduler-status.Tests.ps1`
Expected: FAIL — `scheduler-status.ps1 must exist`.

- [ ] **Step 3: Write the implementation** — create `skill/bin/scheduler-status.ps1`:

```powershell
# skill/bin/scheduler-status.ps1
# Read-only Task Scheduler state for the desktop app's Live tab. ALWAYS exits 0 with JSON so the
# app degrades to "unknown", never crashes. No writes, no side effects.
param([string]$TaskName = 'Jarvis Morning Debrief', [switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'

function Get-SchedulerStatus {
  param([string]$TaskName)
  try {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $info = $t | Get-ScheduledTaskInfo
    $next = $null
    if ($info.NextRunTime) { $next = $info.NextRunTime.ToString('s') }
    return [pscustomobject]@{
      registered = $true
      enabled    = ($t.State -ne 'Disabled')
      state      = [string]$t.State
      nextRun    = $next
    }
  } catch {
    return [pscustomobject]@{ registered = $false; enabled = $false; state = 'unknown'; nextRun = $null }
  }
}

if ($DotSourceOnly) { return }
Get-SchedulerStatus -TaskName $TaskName | ConvertTo-Json -Compress
```

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -NoProfile -File tests/scheduler-status.Tests.ps1`
Expected: PASS — `scheduler-status: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add skill/bin/scheduler-status.ps1 tests/scheduler-status.Tests.ps1
git commit -m "feat(bank): read-only scheduler-status.ps1 collector for the Live tab"
```

---

### Task 4: `setup-bank.ps1` — persist `consent_expires`

**Files:**
- Modify: `skill/bin/setup-bank.ps1`
- Modify: `tests/get-bank-data.Tests.ps1`

**Interfaces:**
- Produces: `bank.json` now includes `consent_expires: 'YYYY-MM-DD'` after `-ExchangeCode`. Dot-source exposes `Get-ConsentDate -ValidUntil <iso>` returning the date portion.

- [ ] **Step 1: Write the failing test** — append to `tests/get-bank-data.Tests.ps1` before the final `Write-Host`:

```powershell
# Consent-date helper (setup-bank.ps1): the app needs a YYYY-MM-DD from the ISO valid_until.
. "$PSScriptRoot\..\skill\bin\setup-bank.ps1" -DotSourceOnly 2>$null
Assert ((Get-ConsentDate -ValidUntil '2026-10-12T16:00:00Z') -eq '2026-10-12') "Get-ConsentDate strips the time"
Assert ($null -eq (Get-ConsentDate -ValidUntil '')) "empty valid_until -> null"
```

Note: `setup-bank.ps1 -DotSourceOnly` must return before doing any work. Confirm it already has an early `if ($DotSourceOnly)`-style guard; if not, this task adds one (Step 3).

- [ ] **Step 2: Run it, verify it fails**

Run: `powershell -NoProfile -File tests/get-bank-data.Tests.ps1`
Expected: FAIL — `Get-ConsentDate` not recognized (and/or setup-bank has no `-DotSourceOnly`).

- [ ] **Step 3: Implement** — in `skill/bin/setup-bank.ps1`:

3a. Add `-DotSourceOnly` to the `param(...)` block if absent, and immediately after the dot-source of get-bank-data (the `$CredPath = $myCred; $StatePath = $myState` line) add:

```powershell
function Get-ConsentDate { param([string]$ValidUntil) if (-not $ValidUntil) { return $null }; return ($ValidUntil -replace 'T.*$', '') }
if ($DotSourceOnly) { return }
```

3b. In the `if ($NewSession)` block, hoist the validity to a variable and persist it into the pending file. Replace the `access = @{ valid_until = ... }` line and the pending-write with:

```powershell
  $validUntil = (Get-Date).AddDays($ValidDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $body = @{
    aspsp = @{ name = $AspspName; country = $AspspCountry }
    access = @{ valid_until = $validUntil }
    redirect_url = $RedirectUrl
    state = $state
    psu_type = 'personal'
  }
  $resp = Invoke-EBApi $jwt -Method 'Post' -Path '/auth' -BodyObj $body
  @{ state = $state; aspsp_name = $AspspName; aspsp_country = $AspspCountry; valid_until = $validUntil; created = (Get-Date).ToString('s') } |
    ConvertTo-Json | Set-Content -Encoding UTF8 $PendingPath
```

3c. In the `if ($ExchangeCode)` block, carry it into `bank.json`. Replace the state-writing line with:

```powershell
  $consentExpires = Get-ConsentDate -ValidUntil $pending.valid_until
  @{ session_id = $resp.session_id; accounts = $accounts; consent_expires = $consentExpires; linked = (Get-Date).ToString('s') } |
    ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $StatePath
```

- [ ] **Step 4: Run test to verify it passes, then the full suite**

Run: `powershell -NoProfile -File tests/get-bank-data.Tests.ps1`
Expected: PASS — `get-bank-data: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add skill/bin/setup-bank.ps1 tests/get-bank-data.Tests.ps1
git commit -m "feat(bank): persist consent_expires into bank.json for the Live tab countdown"
```

---

### Task 5: `get-bank-data.ps1` — best-effort heartbeat write

**Files:**
- Modify: `skill/bin/get-bank-data.ps1`
- Modify: `tests/get-bank-data.Tests.ps1`

**Interfaces:**
- Produces: `~/.jarvis/bank-heartbeat.json` = `{ asOf, ok, error, accountCount, consentExpires }`, written best-effort on every real fetch attempt (success or API error), never on the unconfigured early-exits. Dot-source exposes `Write-BankHeartbeat`.

- [ ] **Step 1: Write the failing test** — append to `tests/get-bank-data.Tests.ps1` before the final `Write-Host`:

```powershell
# Heartbeat: Write-BankHeartbeat writes the expected shape, and a bad path must NOT throw (best-effort).
. "$PSScriptRoot\..\skill\bin\get-bank-data.ps1" -DotSourceOnly
$hb = Join-Path $env:TEMP ('jarvis-hb-' + [Guid]::NewGuid().ToString('N') + '.json')
Write-BankHeartbeat -Path $hb -Ok $true -ErrorMsg $null -AccountCount 2 -ConsentExpires '2026-10-12'
Assert (Test-Path $hb) "heartbeat file must be written"
$h = Get-Content $hb -Raw | ConvertFrom-Json
Assert ($h.ok -eq $true) "heartbeat ok flows through"
Assert ($h.accountCount -eq 2) "heartbeat accountCount flows through"
Assert ($h.consentExpires -eq '2026-10-12') "heartbeat consentExpires flows through"
Assert ($h.asOf) "heartbeat stamps asOf"
Remove-Item $hb -Force -ErrorAction SilentlyContinue
$threw = $false
try { Write-BankHeartbeat -Path 'Z:\no\such\dir\hb.json' -Ok $false -ErrorMsg 'x' -AccountCount 0 -ConsentExpires $null }
catch { $threw = $true }
Assert (-not $threw) "a heartbeat write to a bad path must NOT throw (best-effort)"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `powershell -NoProfile -File tests/get-bank-data.Tests.ps1`
Expected: FAIL — `Write-BankHeartbeat` not recognized.

- [ ] **Step 3: Implement** — in `skill/bin/get-bank-data.ps1`:

3a. Add a heartbeat path param to `param(...)`:

```powershell
  [string]$HeartbeatPath = (Join-Path $HOME '.jarvis\bank-heartbeat.json'),
```

3b. Add the helper near the other functions (above `if ($DotSourceOnly)`):

```powershell
function Write-BankHeartbeat {
  # Best-effort: a heartbeat write must NEVER affect the feed's stdout JSON or exit-0 contract.
  param([string]$Path, [bool]$Ok, [string]$ErrorMsg, [int]$AccountCount, [string]$ConsentExpires)
  try {
    [pscustomobject]@{
      asOf = (Get-Date).ToString('s'); ok = $Ok; error = $ErrorMsg
      accountCount = $AccountCount; consentExpires = $ConsentExpires
    } | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 $Path
  } catch { }
}
```

3c. In the success path (after `$sum = Format-BankSummary $data`, before the final `ConvertTo-Json`), add:

```powershell
  Write-BankHeartbeat -Path $HeartbeatPath -Ok $true -ErrorMsg $null -AccountCount (@($sum.accounts).Count) -ConsentExpires $state.consent_expires
```

3d. In the `catch { ... }` block (the API-error path), before the `[pscustomobject]@{ configured = $true; error = $msg; ... }` line, add:

```powershell
  Write-BankHeartbeat -Path $HeartbeatPath -Ok $false -ErrorMsg $msg -AccountCount 0 -ConsentExpires $null
```

(Do NOT add heartbeat writes to the unconfigured early-exit paths — a missing heartbeat is how the app shows "awaiting first fetch" vs "off".)

- [ ] **Step 4: Run test to verify it passes, then the whole suite**

Run: `powershell -NoProfile -File tests/get-bank-data.Tests.ps1`
Expected: PASS.
Run: `Get-ChildItem tests\*.Tests.ps1 | %{ powershell -NoProfile -File $_.FullName }`
Expected: every file prints `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add skill/bin/get-bank-data.ps1 tests/get-bank-data.Tests.ps1
git commit -m "feat(bank): write bank-heartbeat.json so the app can show feed health"
```

---

### Task 6: Tray icon assets

**Files:**
- Create: `app/scripts/gen-tray-icons.js`
- Create (generated): `app/assets/tray-normal.png`, `tray-amber.png`, `tray-grey.png`, `tray-busy.png`
- Modify: `app/package.json` (add `pngjs` devDependency)
- Create: `tests/tray-icons.Tests.ps1`

**Interfaces:**
- Produces: four PNGs in `app/assets/` named exactly `tray-<health-icon>.png` matching `chooseTrayIcon()` output, each the same pixel dimensions as the base `tray.png`.

- [ ] **Step 1: Add the dev dependency**

Run: `cd app && npm install --save-dev pngjs && cd ..`
Expected: `pngjs` added to `app/package.json` devDependencies; exit 0.

- [ ] **Step 2: Write the generator** — create `app/scripts/gen-tray-icons.js`:

```js
// app/scripts/gen-tray-icons.js - composite a coloured status dot onto the base tray icon.
// Run: node app/scripts/gen-tray-icons.js   (from the repo root, or `node scripts/gen-tray-icons.js` from app/)
const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');

const ASSETS = path.join(__dirname, '..', 'assets');
const base = PNG.sync.read(fs.readFileSync(path.join(ASSETS, 'tray.png')));

const COLORS = {
  'tray-normal': [46, 204, 113, 255],   // green
  'tray-amber':  [243, 156, 18, 255],   // amber
  'tray-grey':   [127, 140, 141, 255],  // grey
  'tray-busy':   [52, 152, 219, 255],   // blue
};

function withDot(src, rgba, dimBase) {
  const out = new PNG({ width: src.width, height: src.height });
  src.data.copy(out.data);
  if (dimBase) { for (let i = 3; i < out.data.length; i += 4) out.data[i] = Math.round(out.data[i] * 0.5); }
  const r = Math.max(3, Math.round(src.width * 0.28));
  const cx = src.width - r - 1, cy = src.height - r - 1;
  for (let y = 0; y < src.height; y++) {
    for (let x = 0; x < src.width; x++) {
      if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) {
        const i = (src.width * y + x) << 2;
        out.data[i] = rgba[0]; out.data[i + 1] = rgba[1]; out.data[i + 2] = rgba[2]; out.data[i + 3] = rgba[3];
      }
    }
  }
  return out;
}

for (const [name, rgba] of Object.entries(COLORS)) {
  const img = withDot(base, rgba, name === 'tray-grey');
  fs.writeFileSync(path.join(ASSETS, name + '.png'), PNG.sync.write(img));
  console.log('wrote ' + name + '.png (' + img.width + 'x' + img.height + ')');
}
```

- [ ] **Step 3: Write the test** — create `tests/tray-icons.Tests.ps1`:

```powershell
# tests/tray-icons.Tests.ps1 - generate the tray status icons and verify they exist at base dimensions
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }
function Get-PngSize([string]$p) { $b = [IO.File]::ReadAllBytes($p); $w = ($b[16]*16777216)+($b[17]*65536)+($b[18]*256)+$b[19]; $h = ($b[20]*16777216)+($b[21]*65536)+($b[22]*256)+$b[23]; return @($w,$h) }

$assets = "$PSScriptRoot\..\app\assets"
Assert (Test-Path "$assets\tray.png") "base tray.png must exist"
$baseSize = Get-PngSize "$assets\tray.png"

node "$PSScriptRoot\..\app\scripts\gen-tray-icons.js"
Assert ($LASTEXITCODE -eq 0) "gen-tray-icons.js must run cleanly"

foreach ($n in @('tray-normal','tray-amber','tray-grey','tray-busy')) {
  $p = "$assets\$n.png"
  Assert (Test-Path $p) "$n.png must be generated"
  $sz = Get-PngSize $p
  Assert ($sz[0] -eq $baseSize[0] -and $sz[1] -eq $baseSize[1]) "$n.png must match base dimensions ($($baseSize[0])x$($baseSize[1]))"
}
Write-Host "tray-icons: ALL PASS"
```

- [ ] **Step 4: Run the test (generates + verifies)**

Run: `powershell -NoProfile -File tests/tray-icons.Tests.ps1`
Expected: PASS — `tray-icons: ALL PASS`, and the four PNGs now exist in `app/assets/`.

- [ ] **Step 5: Commit**

```bash
git add app/scripts/gen-tray-icons.js app/assets/tray-normal.png app/assets/tray-amber.png app/assets/tray-grey.png app/assets/tray-busy.png app/package.json app/package-lock.json tests/tray-icons.Tests.ps1
git commit -m "feat(app): generate green/amber/grey/busy tray status icons"
```

---

### Task 7: `main.js` — liveState, feeders, and the `data:live` push

**Files:**
- Modify: `app/main.js`

**Interfaces:**
- Consumes: `app/lib/livestate.js` (Task 2), `skill/bin/scheduler-status.ps1` (Task 3), `~/.jarvis/bank-heartbeat.json` (Task 5), `runCollector` (from `./lib/run`).
- Produces: a module-level `liveState`, `pushLive()`, and populated feeders. Sends `data:live` (full `liveState`) to the dashboard. `live:status` IPC now returns the full `liveState`. Calls `updateTrayHealth()` (a no-op stub added here; implemented in Task 8).

This task is Electron glue — **not** unit-testable. It is verified manually at the end of Task 8/10. Make the edits, then smoke-launch to confirm no crash and that the dashboard Live tab still renders (it will still use the OLD renderer until Task 9 — that's fine, `live:status` returns a superset).

- [ ] **Step 1: Require the pure module and CONFIG reader.** Near the top requires in `app/main.js`, add:

```js
const LS = require('./lib/livestate');
const BANK_HEARTBEAT = path.join(process.env.USERPROFILE, '.jarvis', 'bank-heartbeat.json');
const CONFIG_MD = path.join(VAULT, 'CONFIG.md');
```

- [ ] **Step 2: Declare `liveState` and `pushLive()`.** After `let state = loadState();`, add:

```js
let liveState = {
  scheduler: { registered: null, enabled: null, state: null, nextRun: null, lastRun: null, lastResult: null, lastRunLate: false, running: false, stalled: false },
  bank: { enabled: false, configured: false, ok: null, error: null, lastFetch: null, consentExpires: null },
  chat: { inFlight: false },
  ledgerOpenCount: 0,
  health: 'unknown',
};
let pushTimer = null;
function pushLive() {
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    liveState.health = LS.deriveHealth(liveState, new Date());
    if (dashboard && !dashboard.isDestroyed()) dashboard.webContents.send('data:live', liveState);
    updateTrayHealth();   // implemented in Task 8; safe no-op stub until then
  }, 250);
}
function updateTrayHealth() { /* Task 8 */ }
```

- [ ] **Step 3: Feeder — bank config + heartbeat.** Add:

```js
function readBankEnabled() {
  try { return /finance_bank:\s*on\b/.test(fs.readFileSync(CONFIG_MD, 'utf8')); } catch { return false; }
}
function refreshBank() {
  liveState.bank.enabled = readBankEnabled();
  try {
    const h = JSON.parse(fs.readFileSync(BANK_HEARTBEAT, 'utf8'));
    liveState.bank.configured = true;
    liveState.bank.ok = !!h.ok;
    liveState.bank.error = h.error || null;
    liveState.bank.lastFetch = h.asOf || null;
    liveState.bank.consentExpires = h.consentExpires || null;
  } catch {
    liveState.bank.configured = false;
    liveState.bank.ok = null; liveState.bank.error = null; liveState.bank.lastFetch = null; liveState.bank.consentExpires = null;
  }
  pushLive();
}
```

- [ ] **Step 4: Feeder — scheduler poll.** Add:

```js
async function pollScheduler() {
  try {
    const s = await runCollector(path.join(BIN, 'scheduler-status.ps1'), []);
    liveState.scheduler.registered = (s && typeof s.registered === 'boolean') ? s.registered : null;
    liveState.scheduler.enabled = (s && typeof s.enabled === 'boolean') ? s.enabled : null;
    liveState.scheduler.state = (s && s.state) || null;
    liveState.scheduler.nextRun = (s && s.nextRun) || null;
  } catch {
    liveState.scheduler.registered = null; liveState.scheduler.enabled = null;
  }
  pushLive();
}
```

- [ ] **Step 5: Feeder — extend the log watcher.** In `startWatchers()`, add a helper and a state-derivation call inside the existing `.jarvis.log` watcher (keep the existing FAILED->HUD behaviour):

```js
function refreshSchedulerFromLog() {
  try {
    const logPath = path.join(VAULT, 'debriefs', '.jarvis.log');
    const lines = fs.readFileSync(logPath, 'utf8').trim().split('\n').slice(-10);
    Object.assign(liveState.scheduler, LS.parseLogTail(lines, new Date()));
  } catch {}
  pushLive();
}
```

Call `refreshSchedulerFromLog()` once at the end of `startWatchers()`, and add a call to it inside the existing `.jarvis.log` `fs.watch` callback (right after the `if (/FAILED/i.test(tail)) ...` line). When a run finishes, also re-poll the scheduler so `nextRun` rolls forward — add after that same line: `if (/run (ok|FAILED)/.test(tail)) pollScheduler();`

- [ ] **Step 6: Track chat in-flight.** Add a wrapper and route both callers through it:

```js
async function sendChatTracked(message) {
  liveState.chat.inFlight = true; pushLive();
  try { return await sendChat(message); }
  finally { liveState.chat.inFlight = false; pushLive(); }
}
```

In the `chat:send` IPC handler, change `sendChat(message)` to `sendChatTracked(message)`. In `handleSpeech()`, change `const res = await sendChat(text);` to `const res = await sendChatTracked(text);`.

- [ ] **Step 7: Rewrite the `live:status` handler and add ledger count.** Replace the entire `ipcMain.handle('live:status', ...)` body with:

```js
  ipcMain.handle('live:status', () => {
    try {
      const ledger = fs.readFileSync(path.join(VAULT, 'LEDGER.md'), 'utf8');
      liveState.ledgerOpenCount = (ledger.match(/\|\s*open\s*\|/g) || []).length;
    } catch {}
    liveState.health = LS.deriveHealth(liveState, new Date());
    return liveState;
  });
```

- [ ] **Step 8: Kick the feeders on startup.** In `app.whenReady().then(() => { ... })`, after `startWatchers();`, add:

```js
    refreshBank();
    pollScheduler();
    setInterval(pollScheduler, 5 * 60 * 1000);
    fs.watch(path.dirname(BANK_HEARTBEAT), (_e, f) => { if (f === 'bank-heartbeat.json') refreshBank(); });
```

Wrap that `fs.watch` in try/catch (the `.jarvis` dir exists in practice, but be safe): if it throws, log and continue.

- [ ] **Step 9: Smoke-test (manual).**

Run: `cd app && npx electron . ; cd ..` (or the project's usual launch)
Expected: app starts, tray appears, no console crash. Open the dashboard (tray -> "Classic dashboard"); the Live tab still renders via the old renderer without error. Close.

- [ ] **Step 10: Commit**

```bash
git add app/main.js
git commit -m "feat(app): liveState + real-time feeders + data:live push (tray wiring stubbed)"
```

---

### Task 8: `main.js` — `updateTrayHealth()` (icons + dynamic tooltip)

**Files:**
- Modify: `app/main.js`

**Interfaces:**
- Consumes: `liveState`, `LS.chooseTrayIcon`, `LS.tooltipFor`, the Task 6 icons.
- Produces: the tray icon recolours and the tooltip updates on every `pushLive()`.

- [ ] **Step 1: Implement `updateTrayHealth()`.** Replace the `function updateTrayHealth() { /* Task 8 */ }` stub with:

```js
let lastTrayIcon = null;
function updateTrayHealth() {
  if (!tray || tray.isDestroyed()) return;
  const now = new Date();
  const iconName = LS.chooseTrayIcon(liveState.health);
  if (iconName !== lastTrayIcon) {
    const p = path.join(__dirname, 'assets', iconName + '.png');
    try { if (fs.existsSync(p)) { tray.setImage(nativeImage.createFromPath(p)); lastTrayIcon = iconName; } } catch {}
  }
  try { tray.setToolTip(LS.tooltipFor(liveState, now)); } catch {}
}
```

- [ ] **Step 2: Set the initial icon at creation.** In `createTray()`, after `tray = new Tray(icon);`, the base icon is `tray.png`; leave it — the first `pushLive()` will set the health icon. (No code change needed beyond confirming `createTray` runs before the first `pushLive`.)

- [ ] **Step 3: Manual verification — tray colours.**

1. Launch the app. Within a few seconds the tray shows **green** (normal) — hover: "next briefing 08:30…".
2. `Disable-ScheduledTask -TaskName 'Jarvis Morning Debrief'` (elevated PowerShell). Within ~5 min (or immediately if you trigger `pollScheduler` by reopening) the tray goes **grey**, tooltip "OFF DUTY". Re-enable: `Enable-ScheduledTask -TaskName 'Jarvis Morning Debrief'` — back to **green**.
3. Tray menu -> "Debrief now": tray goes **busy** (blue) during the run, then settles **green** (or **amber** if it failed).

- [ ] **Step 4: Commit**

```bash
git add app/main.js
git commit -m "feat(app): tray icon health colour + dynamic tooltip"
```

---

### Task 9: Dashboard — `onLive`, `renderLive`, rebuilt Status card

**Files:**
- Modify: `app/preload.js`
- Modify: `app/renderer/dashboard.html` (Status card markup)
- Modify: `app/renderer/dashboard.js` (`loadLive` -> `renderLive`, subscribe `onLive`)
- Modify: `app/renderer/dashboard.css` (pill + pulsing dot)

**Interfaces:**
- Consumes: `data:live` (Task 7), the full `liveState` shape, `LS`-equivalent labels (renderer re-derives display via the pushed `health` + fields; it does NOT import the node module — the main process already computed `liveState.health`).

- [ ] **Step 1: Add the `onLive` bridge.** In `app/preload.js`, add to the `jarvis` object:

```js
  onLive: (cb) => ipcRenderer.on('data:live', (_e, s) => cb(s)),
```

- [ ] **Step 2: Rebuild the Status card markup.** In `app/renderer/dashboard.html`, replace the `<ul class="stats">…</ul>` inside `#tab-live` with:

```html
          <div class="pill" id="jarvisPill"><span class="pdot"></span><span id="pillLabel">…</span></div>
          <ul class="stats">
            <li>Next briefing <b id="nextRun">–</b></li>
            <li>Last run <b id="lastRun">–</b></li>
            <li>Running now <b id="runningNow">–</b></li>
            <li>Bank feed <b id="bankFeed">–</b></li>
          </ul>
```

- [ ] **Step 3: Rewrite `loadLive` as `renderLive` + subscribe.** In `app/renderer/dashboard.js`, replace the whole `async function loadLive() { … }` with:

```js
function fmtStamp(iso) {
  if (!iso) return '–';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  const today = new Date().toDateString() === d.toDateString();
  const t = d.toLocaleTimeString('en-IE', { hour: '2-digit', minute: '2-digit' });
  return (today ? 'today ' : d.toLocaleDateString('en-IE', { day: 'numeric', month: 'short' }) + ' ') + t;
}
function daysLeft(dateStr) {
  if (!dateStr) return null;
  const exp = Date.parse(dateStr + 'T00:00:00');
  if (isNaN(exp)) return null;
  return Math.floor((exp - Date.now()) / 86400000);
}
const PILL = { busy:['Working…','busy'], grey:['Off duty','grey'], amber:['Attention','amber'], unknown:['Status unknown','unknown'], normal:['On duty','normal'] };

function renderLive(s) {
  if (!s) return;
  const [label, cls] = PILL[s.health] || PILL.normal;
  const pill = $('jarvisPill'); pill.className = 'pill ' + cls; $('pillLabel').textContent = label;

  const sc = s.scheduler || {};
  $('nextRun').textContent = fmtStamp(sc.nextRun);
  let lr = fmtStamp(sc.lastRun);
  if (sc.lastResult) lr += ' · ' + (sc.lastResult === 'ok' ? 'OK' : 'FAILED');
  if (sc.lastRunLate) lr += ' (late — machine was shut at 08:30)';
  $('lastRun').textContent = lr;

  $('runningNow').textContent = (s.chat && s.chat.inFlight) ? 'answering you…'
    : (sc.running ? 'debrief running…' : (sc.stalled ? 'a run may have stalled' : 'idle'));
  $('runningNow').className = ((s.chat && s.chat.inFlight) || sc.running) ? 'live' : '';

  const b = s.bank || {};
  if (!b.enabled) $('bankFeed').textContent = 'off';
  else if (!b.configured) $('bankFeed').textContent = 'awaiting first fetch';
  else {
    const dl = daysLeft(b.consentExpires);
    let txt = b.ok ? ('fetched ' + fmtStamp(b.lastFetch)) : ('error — ' + (b.error || 'see log'));
    if (dl !== null) txt += ' · consent ' + dl + 'd';
    $('bankFeed').textContent = txt;
    $('bankFeed').className = (b.ok === false || (dl !== null && dl < 7)) ? 'warn' : '';
  }

  const led = $('ledger');
  if (led && typeof s.ledgerOpenCount === 'number') { /* ledger list still loaded separately below */ }
}
async function loadLive() { renderLive(await window.jarvis.liveStatus()); await loadLedger(); }
async function loadLedger() {
  const ledger = await window.jarvis.read('ledger');
  if (ledger) {
    const open = stripFrontmatter(ledger).split('\n').filter((l) => /\|\s*open\s*\|/.test(l));
    $('ledger').textContent = open.length ? open.map((l) => '- ' + l.split('|')[1].trim() + ' (raised ' + l.split('|')[3].trim() + 'x)').join('\n') : 'Nothing open. Remarkable, Sir.';
  }
}
window.jarvis.onLive(renderLive);
```

- [ ] **Step 4: Drop the fast poll to a 5-min safety net.** In `app/renderer/dashboard.js`, change `setInterval(loadLive, 60000);` to `setInterval(loadLive, 5 * 60 * 1000);`.

- [ ] **Step 5: Add pill + pulse styles.** Append to `app/renderer/dashboard.css`:

```css
.pill { display:inline-flex; align-items:center; gap:.5em; padding:.3em .8em; border-radius:999px; font-weight:600; font-size:.9em; margin-bottom:.6em; }
.pill .pdot { width:.6em; height:.6em; border-radius:50%; background:currentColor; }
.pill.normal { color:#2ecc71; background:rgba(46,204,113,.12); }
.pill.amber  { color:#f39c12; background:rgba(243,156,18,.14); }
.pill.grey   { color:#95a5a6; background:rgba(149,165,166,.14); }
.pill.busy   { color:#3498db; background:rgba(52,152,219,.14); }
.pill.unknown{ color:#bbb;    background:rgba(200,200,200,.10); }
#runningNow.live { color:#3498db; }
#runningNow.live::after { content:''; display:inline-block; width:.5em; height:.5em; margin-left:.4em; border-radius:50%; background:#3498db; animation:pulse 1.4s ease-in-out infinite; }
#bankFeed.warn { color:#f39c12; }
@keyframes pulse { 0%,100%{opacity:.35;} 50%{opacity:1;} }
@media (prefers-reduced-motion: reduce) { #runningNow.live::after { animation:none; } }
```

- [ ] **Step 6: Manual verification — dashboard.**

1. Open the dashboard Live tab: pill shows "On duty" (green), Next briefing / Last run / Bank feed populated, "Running now: idle".
2. Tray "Debrief now": within the debounce the pill flips to "Working…", "Running now" pulses "debrief running…", then settles to "On duty" and "idle" — **without** re-opening the tab (proves the `onLive` push path).
3. Bank feed line shows "fetched today · consent NNd" (or "off"/"awaiting" per your CONFIG).

- [ ] **Step 7: Commit**

```bash
git add app/preload.js app/renderer/dashboard.html app/renderer/dashboard.js app/renderer/dashboard.css
git commit -m "feat(app): real-time Live tab — status pill, honest last-run, bank health, push updates"
```

---

### Task 10: End-to-end manual verification + reinstall

**Files:** none (verification only)

- [ ] **Step 1: Full automated suite.**

Run: `Get-ChildItem tests\*.Tests.ps1 | %{ powershell -NoProfile -File $_.FullName }`
Expected: every file prints `ALL PASS`, none exit non-zero.

- [ ] **Step 2: The spec §9 manual checklist** (with the app running):
  1. Fresh launch → tray **green**, pill "On duty".
  2. `Disable-ScheduledTask` → tray **grey** + "OFF DUTY" tooltip; pill "Off duty" (within 5 min or on next `pollScheduler`). Re-enable → green.
  3. "Debrief now" → tray **busy** → settles green; dashboard "Running now" pulses then idles, live (no tab reopen).
  4. Force a failure: temporarily rename `skill/bin/send-debrief.ps1`, run `skill/bin/jarvis-debrief.ps1` → tray **amber**, tooltip "last run FAILED"; dashboard shows FAILED. Restore the file, re-run → back to green.
  5. Low consent: temporarily edit `~/.jarvis/bank.json` `consent_expires` to 5 days out and re-run a debrief → tray **amber**, tooltip/dashboard show the countdown + re-link hint. Restore the real date.

- [ ] **Step 3: Confirm invariants by inspection:**
  - `git grep -n "writeFileSync\|Set-Content" app/` shows NO app-shell write into the vault (only reads); the heartbeat/consent writes are in `skill/bin/*.ps1`. 
  - Killing the app does not stop the 08:30 task (independent path).

- [ ] **Step 4: Reinstall the skill** (the new/changed `skill/bin/*.ps1` must reach the live skill dir):

Run: `powershell -NoProfile -File install.ps1`
Expected: `Jarvis skill installed to …`.

- [ ] **Step 5: Final commit (if anything changed during verification) + push.**

```bash
git add -A
git commit -m "chore: verify real-time Live tab end-to-end" --allow-empty
git push origin master
```

---

## Self-Review

**Spec coverage:** §3 architecture → Task 7 (liveState/pushLive). §4 shape → Task 7 Step 2. §5.1 log → Tasks 1,7. §5.2 chat → Task 7 Step 6. §5.3 scheduler → Tasks 3,7. §5.4 heartbeat+consent → Tasks 4,5. §5.5 config → Task 7 Step 3. §6 tray → Tasks 2,6,8. §7 dashboard → Task 9. §8 failure handling → degradation tests (Tasks 3–5), stalled (Tasks 1–2), debounce/try-catch (Task 7), invariants (Task 10 Step 3). §9 testing → every task's tests + Task 10. §10 files → all covered. §12 deferred → not implemented (correct).

**Placeholder scan:** no TBD/TODO; every code step shows complete code; the one "/* ledger loaded separately */" comment in Task 9 Step 3 is intentional (ledger list is filled by `loadLedger()` in the same step).

**Type consistency:** `liveState` shape identical across Task 2 (interface), Task 7 Step 2 (declaration), Task 9 (consumption). `chooseTrayIcon` returns `tray-*` basenames used verbatim in Tasks 6 & 8. `parseLogTail` fields (`running/stalled/lastResult/lastRunLate/lastRun`) consistent across Tasks 1, 2, 7, 9.
