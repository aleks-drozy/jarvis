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
