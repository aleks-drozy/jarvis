// app/lib/livestate.js - pure, testable live-state logic. NO Electron, NO I/O.
'use strict';

// Task ExecutionTimeLimit from scripts/register-task.ps1 (30 min, F4 - raised from 15 as Claude
// generation time climbed toward the old ceiling). A run still marked "running" past this is
// treated as stalled, not a perpetual spinner. MUST stay in sync with register-task.ps1's
// ExecutionTimeLimit - see tests/scheduler-settings.Tests.ps1, which fails if the two disagree.
const RUN_LIMIT_MS = 30 * 60 * 1000;

// Parse the tail of .jarvis-runs.log (raw lines, most recent last) into current scheduler run
// state. This is the wrapper script's OWN private channel (see jarvis-debrief.ps1) - the Claude
// subagent it invokes is never told this filename and must never write to it; it may only be
// read here. Line formats, all "<ISO-8601 seconds> <message>":
//   "2026-07-14T08:30:03 run start"
//   "2026-07-14T08:33:46 run ok (note written 08:32, via telegram)"   [+ optional " [late catch-up]"]
//   "2026-07-14T08:33:46 run FAILED: <error>"
//
// F2 hardening: a run only counts as successfully completed if there is a LATER line, timestamped
// AFTER the most recent "run start", that is either "run FAILED" or "run ok" carrying a non-empty
// "via <channel>" (proof the real send path ran). A "run ok" line WITHOUT "via <channel>" is
// suspicious - it is exactly the shape of a forged/headless line - and must never count as a
// success signal; it is ignored, not treated as a terminator. Lines with an unparseable/empty
// timestamp are not valid records at all and are skipped entirely (never crash, never terminate a
// run). A start with no valid terminator after it reports "stalled" (see deriveHealth), never "ok".
const RUN_LINE_RE = /^(\S+)\s+run (start|ok|FAILED)\b(.*)$/;

function parseRunRow(rawLine) {
  const l = (rawLine || '').trim();
  const m = RUN_LINE_RE.exec(l);
  if (!m) return null;
  const ts = m[1];
  const ms = Date.parse(ts);
  if (isNaN(ms)) return null;   // malformed/empty timestamp - not a valid record, skip
  const type = m[2] === 'start' ? 'start' : (m[2] === 'ok' ? 'ok' : 'failed');
  let hasVia = false;
  if (type === 'ok') {
    const viaM = /\bvia\s+(\S+)/.exec(m[3] || '');
    hasVia = !!(viaM && viaM[1]);
  }
  return { ts, ms, type, hasVia, raw: l };
}

function parseLogTail(lines, now) {
  const rows = (lines || []).map(parseRunRow).filter(Boolean);
  const out = { lastRun: null, lastResult: null, lastRunLate: false, running: false, stalled: false };
  if (rows.length === 0) return out;

  out.lastRun = rows[rows.length - 1].ts;

  let startIdx = -1;
  for (let i = rows.length - 1; i >= 0; i--) { if (rows[i].type === 'start') { startIdx = i; break; } }

  if (startIdx === -1) {
    // No run-start boundary visible in this tail; fall back to the last valid terminator only.
    const last = rows[rows.length - 1];
    if (last.type === 'failed') { out.lastResult = 'failed'; }
    else if (last.type === 'ok' && last.hasVia) {
      out.lastResult = 'ok';
      out.lastRunLate = /\[late catch-up\]/.test(last.raw);
    }
    return out;
  }

  const startRow = rows[startIdx];
  let terminator = null;
  let anyRowAfterStart = false;
  for (let i = startIdx + 1; i < rows.length; i++) {
    const r = rows[i];
    if (r.ms < startRow.ms) continue;   // must be timestamped AFTER the start
    anyRowAfterStart = true;
    if (r.type === 'failed' || (r.type === 'ok' && r.hasVia)) terminator = r;
  }

  if (terminator) {
    if (terminator.type === 'failed') { out.lastResult = 'failed'; }
    else {
      out.lastResult = 'ok';
      out.lastRunLate = /\[late catch-up\]/.test(terminator.raw);
    }
  } else if (anyRowAfterStart) {
    // Something followed the start (e.g. a suspicious ok-without-via, a forged/headless line)
    // but nothing that qualifies as a real terminator. This is not "still legitimately running" -
    // an event already happened and it wasn't a valid one - so flag it as stalled immediately
    // rather than waiting out RUN_LIMIT_MS on the optimistic assumption nothing is wrong.
    out.lastRun = startRow.ts;
    out.stalled = true;
  } else {
    // Nothing at all followed the start yet - genuinely still in flight until RUN_LIMIT_MS passes.
    out.lastRun = startRow.ts;
    if (now.getTime() - startRow.ms > RUN_LIMIT_MS) { out.stalled = true; }
    else { out.running = true; }
  }
  return out;
}

// Days until the stored (requested) consent expiry; null if unknown/unparseable.
function bankDaysLeft(state, now) {
  const d = state && state.bank && state.bank.consentExpires;
  if (!d) return null;
  const exp = Date.parse(d + 'T00:00:00');
  if (isNaN(exp)) return null;
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  return Math.floor((exp - today) / (24 * 60 * 60 * 1000));
}

function localDateStr(now) {
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

// F3: the debrief-heartbeat.json written by jarvis-debrief.ps1 ONLY after a channel send has
// actually returned successfully (skill/bin/jarvis-debrief.ps1). A heartbeat whose date is not
// today's date, once it is past 09:00 local (an hour and a half of slack past the 08:30 schedule),
// means a real send has not been confirmed today - flag degraded, same as any other health signal.
// Before 09:00 there is no expectation yet (the morning run may simply not have happened), so this
// never fires overnight or first thing. Missing heartbeat info entirely is treated as "unknown, not
// wrong" (fails open) rather than amber, consistent with how bank/scheduler absence is handled.
function heartbeatStale(heartbeat, now) {
  if (!heartbeat || !heartbeat.date) return false;
  if (now.getHours() < 9) return false;
  return heartbeat.date !== localDateStr(now);
}

// Collapse liveState into a single glance-able health value. Precedence: busy > grey > amber/unknown.
function deriveHealth(state, now) {
  const s = (state && state.scheduler) || {};
  const b = (state && state.bank) || {};
  const chat = (state && state.chat) || {};
  const hb = state && state.heartbeat;
  if (chat.inFlight || (s.running && !s.stalled)) return 'busy';
  if (s.registered === false || s.enabled === false) return 'grey';   // grey outranks amber: a dead scheduler is worst
  const dl = bankDaysLeft(state, now);
  const amber =
       s.lastResult === 'failed'
    || s.stalled === true
    || (b.enabled && b.configured && b.ok === false)
    || (dl !== null && dl < 7)
    || heartbeatStale(hb, now);
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
    if (heartbeatStale(state && state.heartbeat, now)) return 'Jarvis - no confirmed debrief send today, check the log';
    return 'Jarvis - attention needed, open the dashboard';
  }
  if (health === 'unknown') return 'Jarvis - scheduler state unknown right now';
  return 'Jarvis - next briefing ' + (s.nextRun ? hhmm(s.nextRun) : '08:30');
}

module.exports = {
  parseLogTail, RUN_LIMIT_MS, bankDaysLeft, heartbeatStale, deriveHealth, chooseTrayIcon, pillFor, tooltipFor
};
