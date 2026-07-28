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

  r = LS.parseLogTail(['2026-07-14T08:30:03 run start', '2026-07-14T08:33:46 run ok (note written 08:32, via telegram)'], NOW);
  ok(r.running === false && r.lastResult === 'ok', 'start + ok -> ok');
  ok(r.lastRunLate === false, 'plain ok is not late');

  r = LS.parseLogTail(['2026-07-14T08:30:03 run start', '2026-07-14T10:04:31 run ok (note written 10:07, via telegram) [late catch-up]'], NOW);
  ok(r.lastResult === 'ok' && r.lastRunLate === true, 'late tag -> lastRunLate true');

  r = LS.parseLogTail(['2026-07-14T08:30:03 run start', '2026-07-14T08:33:46 run FAILED: boom'], NOW);
  ok(r.lastResult === 'failed' && r.running === false, 'start + FAILED -> failed');

  r = LS.parseLogTail([], NOW);
  ok(r.running === false && r.lastResult === null && r.lastRun === null, 'empty -> never');

  // stalled: run start 31 min ago (> 30 min limit, F4), no terminal line
  r = LS.parseLogTail(['2026-07-14T09:59:00 run start'], NOW);
  ok(r.running === false && r.stalled === true, 'start older than 30min -> stalled, not running');

  // ignores unrelated lines
  r = LS.parseLogTail(['2026-07-14T10:29:00 run start', 'garbage line'], NOW);
  ok(r.running === true, 'non-run lines are ignored');
})();

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

// --- F2/F3 hardening: run-status log integrity + debrief heartbeat staleness ---

// (a) literal reproduction case from the bug report: a real "run start" followed by a forged/
// headless "run ok" with NO "via <channel>" and no real script terminator afterward. This must
// NEVER read as a successful/delivered run - it must report stalled.
(() => {
  const NOW2 = new Date('2026-07-28T14:20:00');
  const lines = [
    '2026-07-28T14:11:02 run start',
    '2026-07-28T14:13:30 run ok (note written 14:13, headless)',
  ];
  const r = LS.parseLogTail(lines, NOW2);
  ok(r.lastResult !== 'ok', 'headless ok-without-via must NOT set lastResult to ok');
  ok(r.stalled === true, 'headless ok-without-via with no real terminator -> stalled');
  ok(r.running === false, 'stalled is not running');
  ok(LS.deriveHealth({ scheduler: r, bank: {}, chat: {} }, NOW2) === 'amber', 'stalled -> amber health');
})();

// (b) an "ok" line missing "via <channel>" must never set the result to ok, even when it is the
// only line after start and nothing else contradicts it.
(() => {
  const NOW2 = new Date('2026-07-28T14:20:00');
  const lines = [
    '2026-07-28T08:30:00 run start',
    '2026-07-28T08:33:00 run ok (note written 08:32)',   // no "via" at all
  ];
  const r = LS.parseLogTail(lines, NOW2);
  ok(r.lastResult !== 'ok', 'ok line without "via <channel>" must not count as success');
})();

// (c) the malformed empty-timestamp line must be skipped entirely - not accepted as a record, not
// crash the parser, and (critically) not treated as a valid terminator for the preceding start.
(() => {
  const NOW2 = new Date('2026-07-28T14:20:00');
  const lines = [
    '2026-07-28T14:10:00 run start',   // 10 minutes before NOW2, well within RUN_LIMIT_MS (30 min)
    ' run ok (note written , headless)',   // malformed: no timestamp before "run ok"
  ];
  let threw = false;
  let r;
  try { r = LS.parseLogTail(lines, NOW2); } catch (e) { threw = true; }
  ok(threw === false, 'a malformed empty-timestamp line must not crash the parser');
  ok(r.lastResult !== 'ok', 'a malformed line must not be accepted as a valid ok terminator');
  // NOW2 is well within RUN_LIMIT_MS of the start, so with the malformed line correctly discarded
  // this must read as still-running, not stalled and not ok.
  ok(r.running === true, 'malformed line skipped -> falls back to plain running (start, no valid terminator)');
})();

// (d) a run start older than RUN_LIMIT_MS with no terminator at all -> stalled -> amber health.
(() => {
  const NOW2 = new Date('2026-07-28T14:20:00');
  const started = new Date(NOW2.getTime() - (LS.RUN_LIMIT_MS + 60 * 1000));
  const iso = started.toISOString().slice(0, 19);
  const r = LS.parseLogTail([`${iso} run start`], NOW2);
  ok(r.stalled === true, 'start older than RUN_LIMIT_MS with no terminator -> stalled');
  ok(r.running === false, 'stalled excludes running');
  ok(LS.deriveHealth({ scheduler: r, bank: {}, chat: {} }, NOW2) === 'amber', 'stalled maps to amber health');
})();

// A real, well-formed success (FAILED terminator, and ok WITH via) must still work, including when
// a forged ok-without-via line lands AFTER the real one (it must not un-do the real success).
(() => {
  const NOW2 = new Date('2026-07-28T14:20:00');
  let r = LS.parseLogTail(
    ['2026-07-28T08:30:00 run start', '2026-07-28T08:33:00 run FAILED: boom'], NOW2);
  ok(r.lastResult === 'failed', 'FAILED terminator still reports failed');

  r = LS.parseLogTail(
    ['2026-07-28T08:30:00 run start', '2026-07-28T08:33:00 run ok (note written 08:32, via telegram)'], NOW2);
  ok(r.lastResult === 'ok', 'ok WITH via <channel> still reports ok');
  ok(LS.deriveHealth({ scheduler: r, bank: {}, chat: {} }, NOW2) !== 'amber', 'a real ok is not amber');

  r = LS.parseLogTail([
    '2026-07-28T08:30:00 run start',
    '2026-07-28T08:33:00 run ok (note written 08:32, via telegram)',
    '2026-07-28T08:40:00 run ok (note written 08:39, headless)',
  ], NOW2);
  ok(r.lastResult === 'ok', 'a real via-bearing ok still wins even with a later forged ok appended');
})();

// F3: heartbeatStale
(() => {
  const morning = new Date('2026-07-28T08:00:00');   // before 09:00 - no expectation yet
  const afterNine = new Date('2026-07-28T10:00:00');

  ok(LS.heartbeatStale(null, afterNine) === false, 'no heartbeat at all -> not stale (fails open, unknown not wrong)');
  ok(LS.heartbeatStale({ date: '2026-07-28' }, afterNine) === false, "today's heartbeat after 09:00 -> not stale");
  ok(LS.heartbeatStale({ date: '2026-07-27' }, afterNine) === true, "yesterday's heartbeat after 09:00 -> stale");
  ok(LS.heartbeatStale({ date: '2026-07-27' }, morning) === false, "yesterday's heartbeat BEFORE 09:00 -> not yet stale");

  const health = LS.deriveHealth(
    { scheduler: { registered: true, enabled: true, running: false, stalled: false, lastResult: 'ok' },
      bank: { enabled: false, configured: false, ok: null, consentExpires: null },
      chat: { inFlight: false },
      heartbeat: { date: '2026-07-27' } },
    afterNine);
  ok(health === 'amber', 'a stale heartbeat alone flips health to amber');
})();

if (fails > 0) { console.log(fails + ' assertion(s) FAILED'); process.exit(1); }
console.log('livestate.node: ALL PASS');
