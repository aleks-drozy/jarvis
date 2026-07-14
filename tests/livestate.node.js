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

if (fails > 0) { console.log(fails + ' assertion(s) FAILED'); process.exit(1); }
console.log('livestate.node: ALL PASS');
