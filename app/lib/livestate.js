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
