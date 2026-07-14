# Live Tab: Accurate + Real-Time State — Design Spec

Date: 2026-07-14
Status: approved design, pending implementation plan
Repo: `C:/Users/Alex/Projects/jarvis`

## 1. Context & motivation

The desktop companion's dashboard has a "Live" tab (`app/renderer/dashboard.html` `#tab-live`,
rendered by `loadLive()` in `dashboard.js`). It already exists and polls every 60s, but has three
concrete gaps:

1. **A misleading signal.** "Claude sessions active (30m)" counts *any* `.jsonl` under
   `~/.claude/projects` touched in the last 30 min — i.e. the whole machine. Coding in an unrelated
   repo lights it up as if Jarvis were busy.
2. **Missing state.** No view of the next scheduled run, whether a debrief is running right now, or
   the health of the new (2026-07-14) Enable Banking feed — including the ~90-day PSD2 consent
   expiry, which will otherwise lapse silently.
3. **Poll-only, not live.** During an actual debrief run (1–3 min) nothing changes until the next
   60s tick.

The original Phase 2 design (`DESIGN-APP.md` §4) also called for a **tray icon health colour**
(normal / amber "failed" / grey "disabled") that was never built — the tray icon is static today.

This spec covers: accurate + complete Live-tab data, delivered in real time, **plus** ambient
signals (tray icon colour + dynamic tooltip) that reach the user even when the dashboard is closed —
which, per the app's own notes, is most of the time (the Summon HUD is the primary surface).

## 2. Goals & non-goals

**Goals**
- Replace the machine-wide "active sessions" counter with Jarvis-specific truths.
- Surface: next scheduled run, running-now, last-run outcome (incl. honest "late catch-up"), and
  bank-feed health (last fetch + consent countdown).
- Push updates the instant they happen where possible; a light poll as the correctness backstop.
- A tray icon that mirrors the dashboard's status via one shared function, with a tooltip that
  spells out *why*.

**Non-goals**
- No auto-refresh of the bank feed on tab-open (would burn the free-tier ~10 calls/day/account rate
  limit). "Last fetched" is by nature daily (debrief-time).
- No Electron test harness. Pure logic is unit-tested; the thin Electron glue is manually verified.
- No changes to the Today / Jobs / Money tabs.
- No payment/write capability anywhere (unchanged; single-writer + read-only invariants preserved).

## 3. Architecture

**One source of truth in the main process.** A single `liveState` object in `app/main.js`, updated
by whichever source changes, pushed to both surfaces through one function:

```
pushLive()  ──▶  dashboard (data:live IPC event)   — instant tab update
            └─▶  updateTrayHealth()                — recolour tray icon + set tooltip
```

`pushLive()` is debounced ~250ms (fs.watch fires multiple events per write).

**Push where we can, poll where we must** — the honest per-signal reality:

| Signal | Source | Mechanism | Latency |
|---|---|---|---|
| Debrief running / ok / failed / late | `.jarvis.log` lines | Push — extend existing `fs.watch` | ms |
| Jarvis busy (chat in flight) | in-process `sendChat()` state | Push — flag in the IPC/voice paths | instant |
| Next scheduled run + enabled? | Task Scheduler (`scheduler-status.ps1`) | Poll — ~5 min + startup + post-run | ≤5 min |
| Bank: last fetch, consent expiry | `~/.jarvis/bank-heartbeat.json` | Push — `fs.watch` the heartbeat | ms |

## 4. The `liveState` shape

```js
liveState = {
  scheduler: {
    registered: bool|null,   // null = unknown (the check itself failed)
    enabled:    bool|null,   // null = unknown
    state:      string|null, // 'Ready'|'Disabled'|'Running'|... from Task Scheduler
    nextRun:    ISO|null,
    lastRun:    ISO|null,    // parsed from .jarvis.log
    lastResult: 'ok'|'failed'|null,
    lastRunLate: bool,       // the [late catch-up] tag is present on the last run
    running:    bool,        // seen `run start` with no terminal line yet
    stalled:    bool,        // running, but `run start` older than the 15-min ExecutionTimeLimit
  },
  bank: {
    enabled:        bool,          // CONFIG finance_bank toggle
    configured:     bool,          // heartbeat present (has fetched at least once)
    ok:             bool|null,
    error:          string|null,
    lastFetch:      ISO|null,
    consentExpires: 'YYYY-MM-DD'|null,   // daysLeft computed live, never stored
  },
  chat: { inFlight: bool },
  ledgerOpenCount: number,
  health: 'normal'|'amber'|'grey'|'busy'|'unknown',   // derived by deriveHealth(); the glance state
}
```

`health` is computed by `deriveHealth(liveState, now)` and consumed by BOTH `updateTrayHealth()`
(icon) and the dashboard pill — so the two surfaces can never disagree.

## 5. Data sources (detail)

### 5.1 Scheduler run state — extend the `.jarvis.log` watcher
Today the watcher reads the byte-delta and greps for `FAILED` (drives an existing HUD alert — keep
that). Add: on each change, read the **tail** (~last 10 lines) and derive current truth via the pure
`parseLogTail(lines, now)`:
- most recent `run start` with no following `run ok`/`run FAILED` → `running: true`;
- else `lastResult` = whichever terminal line followed, `lastRun` = its timestamp;
- `[late catch-up]` tag on the last `run ok` line → `lastRunLate: true`;
- `running` + `run start` older than 15 min (the task's `ExecutionTimeLimit`) → `stalled: true`.

Log line formats (from `jarvis-debrief.ps1`), all `^<ISO-8601 seconds> <message>`:
- `2026-07-14T08:30:03 run start`
- `2026-07-14T08:33:46 run ok (note written 08:32)` — optionally ` [late catch-up]`
- `2026-07-14T08:33:46 run FAILED: <error>`

### 5.2 Chat in-flight — wrap the two `sendChat()` callers
Callers: the `chat:send` IPC handler and `handleSpeech()` (voice). Route both through
`sendChatTracked(msg)`: set `chat.inFlight = true; pushLive()` before, and clear it in a `finally`
with another `pushLive()`. In-process; dies with the process on crash (cannot get stuck across
restarts).

### 5.3 Scheduler state — new `skill/bin/scheduler-status.ps1` (read-only)
Emits JSON, exit 0 always:
```json
{ "registered": true, "enabled": true, "state": "Ready", "nextRun": "2026-07-15T08:30:00" }
```
`Get-ScheduledTask -TaskName 'Jarvis Morning Debrief' | Get-ScheduledTaskInfo`; try/catch →
`{ "registered": false }` on any failure (task not found, access error). The app invokes it via the
existing `runCollector` helper, on a ~5-min interval + at startup + once right after a debrief
finishes (nextRun rolls to tomorrow then).

### 5.4 Bank feed — two new persistence writes
- **Heartbeat** (best-effort, must never break the feed's stdout JSON or exit-0 contract). Add to
  `get-bank-data.ps1` a try/catch write of `~/.jarvis/bank-heartbeat.json`:
  ```json
  { "asOf": "2026-07-14T16:28:48", "ok": true, "error": null,
    "accountCount": 1, "consentExpires": "2026-10-12" }
  ```
  The app `fs.watch`es it and maps `asOf`→`bank.lastFetch`, `consentExpires`→`bank.consentExpires`,
  `ok`/`error` straight through. Refreshes only when the collector runs (daily debrief, or "Debrief
  now").
- **Consent expiry.** `-NewSession` already computes `valid_until = now + 90d` and discards it.
  Carry it through: `-NewSession` writes it into `bank-pending.json`; `-ExchangeCode` copies it into
  `bank.json` as `consent_expires`. `get-bank-data.ps1` reads `state.consent_expires` into the
  heartbeat. The app computes days-left **live** from the date (stays current against a day-old
  heartbeat). Labelled honestly in the UI as the *requested* 90-day window (the bank may grant less;
  verifying the granted value against the session is a deferred refinement, not worth an extra call).

### 5.5 Config awareness
`finance_bank: off` → no heartbeat is expected; the app reads the CONFIG toggle and shows "off," not
"broken." On but no heartbeat yet → "awaiting first fetch."

## 6. Tray health states

`deriveHealth(liveState, now)` — strict precedence, most-severe/most-relevant wins:

```
if (chat.inFlight || (scheduler.running && !scheduler.stalled))   return 'busy'
if (scheduler.registered === false || scheduler.enabled === false) return 'grey'
// scheduler state unknown: still surface amber conditions we DO know, else 'unknown'
const amber =
     scheduler.lastResult === 'failed'
  || scheduler.stalled
  || (bank.enabled && bank.configured && bank.ok === false)
  || (bankDaysLeft(liveState, now) !== null && bankDaysLeft(liveState, now) < 7)
if (scheduler.registered === null || scheduler.enabled === null)   return amber ? 'amber' : 'unknown'
if (amber)                                                          return 'amber'
return 'normal'
```

Deliberate choices:
- **Grey outranks amber** — a disabled scheduler means the 08:30 briefing silently won't come at
  all, worse than one failed run.
- **Busy sits on top while active, then resolves** to the health colour — you watch a debrief run
  ("busy") and settle to green (ok) or amber (failed).
- **Unknown ≠ disabled** — a failed *check* never masquerades as a known-bad *state*. Grey is only
  for a confirmed off/unregistered task.

**Tooltip carries the meaning colour can't** (amber is ambiguous — failed run vs expiring consent).
`updateTrayHealth()` sets a dynamic tooltip: e.g. `"Jarvis — last run FAILED 08:33, check the log"`
/ `"Jarvis — consent expires in 5 days, re-link Revolut"` / `"Jarvis — running a debrief now…"` /
`"Jarvis — next briefing 08:30 tomorrow"`.

**Icons.** Four pre-rendered PNGs — the bowler hat with a corner status dot (green / amber /
grey-dimmed / busy) — at 16px and 32px for Windows tray scaling, legible on both light and dark
taskbars (the dot carries state regardless of taskbar theme). Generated from SVG at build time,
placed in `app/assets/`. `chooseTrayIcon(health)` (pure) maps health → asset path. Busy may use a
gentle 2-frame swap (~600ms) or a static glyph — decided at build time; either stops the instant the
run ends.

## 7. Dashboard Live-tab UI

The ledger open-items card stays. The **Status card** is rebuilt:

```
┌─ Jarvis ────────────────────────────────┐
│  ● On duty            (pill: same 4 states/colours as the tray)
│  Next briefing    tomorrow 08:30
│  Last run         08:33 today · OK        (+ "late (machine was shut at 08:30)" when applicable)
│  Running now      ◦ idle                  (pulsing dot when active; reduced-motion aware)
│  Bank feed        fetched 08:32 · 89 days (amber < 7 days, with a re-link hint)
└──────────────────────────────────────────┘
```

- The pill reads `liveState.health` — same value the tray icon uses, so the surfaces cannot
  disagree.
- "Running now" shows "Debrief running…" (`scheduler.running`), "Answering you…" (`chat.inFlight`),
  or "idle". This replaces the deleted machine-wide counter.
- "Last run" surfaces the honest late story when `lastRunLate`.
- Bank countdown computed live from `consentExpires`.

**Data path — one renderer, two feeds:**
```
dashboard opens ─▶ liveStatus() (full snapshot) ─┐
                                                  ├─▶ renderLive(state)
main pushes     ─▶ onLive(state) event ──────────┘
```
- Rewrite the `live:status` IPC handler to return the full `liveState` shape (not the old 3 fields).
- Add `onLive` to `preload.js`: `onLive: (cb) => ipcRenderer.on('data:live', (_e, s) => cb(s))`.
- `renderLive(liveState)` is the single renderer for both the cold load and every push.
- Slow safety-net poll drops from 60s to ~5 min.

**Deleted:** the whole-machine `.jsonl` walk in the `live:status` handler.

## 8. Failure handling

- **Degrade to honest "unknown," never fabricate, never crash.** `scheduler-status.ps1` failure →
  `scheduler.registered = null` → pill "status unknown," tray NOT forced grey. Bank date parse
  failure → "consent: unknown," not amber.
- **Stuck-"running" guard** (§5.1): `running` + start older than the 15-min limit → `stalled`
  (folds into amber), not a perpetual spinner. Chat-in-flight cannot get stuck (in-process).
- **Watchers best-effort; poll is the backstop.** Every watcher callback in try/catch (existing
  pattern) + 250ms debounce. The 5-min poll re-derives full state, so any missed `fs.watch` event
  self-heals within 5 min.
- **Invariants preserved:** (1) single-writer — the app shell writes nothing to the vault; the new
  writes (heartbeat, `consent_expires`) are done by the PowerShell scripts; the app only reads.
  (2) redundancy — the 08:30 email path is independent; if this whole system breaks, the briefing
  still arrives. No new single point of failure.

## 9. Testing

**Pure logic → node tests (following the `downsample.Tests.ps1` precedent).** Extract into
`app/lib/livestate.js`: `parseLogTail(lines, now)`, `deriveHealth(state, now)`, `bankDaysLeft(state,
now)`, `chooseTrayIcon(health)`, and the pill label/colour map. `"now"` is injected so tests are
deterministic. Wrapped as `tests/livestate.Tests.ps1` (shells out to node), keeping "run all tests"
one uniform command. Cases:
- `parseLogTail`: start-no-terminal → running; start+ok → ok; start+FAILED → failed; late tag →
  lastRunLate; empty/missing → never; start 20 min old → stalled.
- `deriveHealth`: disabled → grey; failed → amber; consent<7 → amber; running → busy;
  unknown-scheduler(+no amber) → unknown; unknown-scheduler+failed → amber; grey outranks amber.

**PowerShell scripts → existing degradation-test style.**
- `tests/scheduler-status.Tests.ps1`: bogus task name → `registered:false`, exit 0; ASCII purity.
- Extend `tests/get-bank-data.Tests.ps1`: heartbeat written with expected fields; a heartbeat-write
  failure does NOT break the feed (best-effort); `consent_expires` flows into the heartbeat.
- `setup-bank.ps1`: `-ExchangeCode` carries `consent_expires` into `bank.json` (test the
  state-writing logic in isolation if factored into a function).
- ASCII purity on every new/changed `.ps1`.

**Electron glue → manual (documented, not faked).** The tray recolour, IPC push, and live
`fs.watch` firing need a running instance. Manual checklist (also §11):
1. Start app → tray green, pill "On duty."
2. `Disable-ScheduledTask -TaskName 'Jarvis Morning Debrief'` → within ~5 min tray grey, pill "Off
   duty," tooltip says so. Re-enable → back to green.
3. Tray "Debrief now" → tray busy → settles green; dashboard "Running now" pulses then idles.
4. Temporarily rename `send-debrief.ps1`, force a run → tray amber + tooltip "last run FAILED";
   dashboard shows FAILED. Restore.
5. Temporarily set `consent_expires` to 5 days out → tray amber, tooltip + dashboard show the
   countdown and re-link hint.

**Test-first** for the pure functions (this codebase's habit); manual verification for the glue.

## 10. Files touched

**New**
- `app/lib/livestate.js` — pure functions.
- `skill/bin/scheduler-status.ps1` — read-only Task Scheduler collector.
- `app/assets/tray-normal.png`, `tray-amber.png`, `tray-grey.png`, `tray-busy.png` (+ 32px variants).
- `tests/livestate.Tests.ps1`, `tests/scheduler-status.Tests.ps1`.

**Modified**
- `app/main.js` — `liveState`, `pushLive()` (debounced), `updateTrayHealth()` + dynamic tooltip,
  extended log watcher (state derivation), heartbeat watcher, scheduler poll, `sendChatTracked()`,
  rewritten `live:status` handler.
- `app/preload.js` — add `onLive` bridge.
- `app/renderer/dashboard.js` — `renderLive(state)`, `onLive` subscription, poll 60s→5min.
- `app/renderer/dashboard.html` — rebuilt Status card markup.
- dashboard styles (locate the linked/inline stylesheet) — pill colours, pulsing dot
  (reduced-motion aware).
- `skill/bin/get-bank-data.ps1` — best-effort heartbeat write.
- `skill/bin/setup-bank.ps1` — persist `consent_expires` through `-NewSession`/`-ExchangeCode`.
- `tests/get-bank-data.Tests.ps1` — heartbeat assertions.

## 11. Manual verification checklist
See §9 "Electron glue → manual." Run after implementation, before considering the feature done.

## 12. Deferred / explicitly out of scope
- Verifying the bank-granted consent window against the API (vs the requested 90 days).
- Any manual "refresh bank now" button (rate-limit cost).
- A full Electron integration-test harness.
