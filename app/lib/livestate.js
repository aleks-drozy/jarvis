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

// Days until the stored (requested) consent expiry; null if unknown/unparseable.
function bankDaysLeft(state, now) {
  const d = state && state.bank && state.bank.consentExpires;
  if (!d) return null;
  const exp = Date.parse(d + 'T00:00:00');
  if (isNaN(exp)) return null;
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  return Math.floor((exp - today) / (24 * 60 * 60 * 1000));
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
