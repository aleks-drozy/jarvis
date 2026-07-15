# tests/wakeword-gate.Tests.ps1 - wakeReducer in orb.html: decides when a "Jarvis" detection actually
# starts a listen, and the cooldown that stops the spoken reply (or a repeat wake word) from re-triggering.
# Extracted from orb.html and exercised in node (same technique as downsample / vad-calibration).
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$orb = Join-Path $PSScriptRoot '..\app\renderer\orb.html'
Assert (Test-Path $orb) "orb.html present"
$node = Get-Command node -ErrorAction SilentlyContinue
Assert ($null -ne $node) "node on PATH (needed to exercise renderer JS)"

$js = @'
const fs = require('fs');
function fail(m) { console.error('FAIL: ' + m); process.exit(1); }
function assert(c, m) { if (!c) fail(m); }

const html = fs.readFileSync(process.argv[2], 'utf8');
const start = html.indexOf('function wakeReducer');
assert(start >= 0, 'wakeReducer found in orb.html');
let depth = 0, end = -1;
for (let i = html.indexOf('{', start); i < html.length; i++) {
  if (html[i] === '{') depth++;
  else if (html[i] === '}' && --depth === 0) { end = i + 1; break; }
}
assert(end > start, 'wakeReducer body extracted');
// eval is safe here: test-only process evaluating our own checked-in source (orb.html), no external input
const wakeReducer = eval('(' + html.slice(start, end) + ')');

const CD = 1500;
const S = (o) => Object.assign({ listening: false, speaking: false, cooldownUntil: 0 }, o);

// idle wake, past cooldown -> arm, and set a short guard window. CRUCIALLY it does NOT latch
// listening:true (that is what caused the permanent-wedge bug: if the listen never started, nothing
// ever cleared the latch). Only listenStart marks a real listen.
let r = wakeReducer(S(), { type: 'wake', now: 5000, cooldownMs: CD });
assert(r.arm === true, 'idle wake arms a listen');
assert(r.state.listening === false, 'wake does NOT latch listening (no-wedge)');
assert(r.state.cooldownUntil === 6500, 'wake sets a guard window now+CD');

// second wake before the listen starts (still inside the guard) -> ignored (debounces double-fire)
r = wakeReducer(S({ cooldownUntil: 6500 }), { type: 'wake', now: 5100, cooldownMs: CD });
assert(r.arm === false, 'rapid second wake within guard is ignored');

// WEDGE-PREVENTION: a wake armed, the listen never materialised, guard expires -> next wake arms again
r = wakeReducer(S({ cooldownUntil: 6500 }), { type: 'wake', now: 7000, cooldownMs: CD });
assert(r.arm === true, 'after guard expires, wake arms again (never permanently wedged)');

// wake while a real listen is in progress -> ignored
r = wakeReducer(S({ listening: true }), { type: 'wake', now: 6000, cooldownMs: CD });
assert(r.arm === false && r.state.listening === true, 'wake while listening is ignored');

// listenStart marks the real listen; listenEnd clears it and arms the post-listen cooldown
r = wakeReducer(S(), { type: 'listenStart', now: 1, cooldownMs: CD });
assert(r.state.listening === true && r.arm === false, 'listenStart marks listening, no arm');
r = wakeReducer(S({ listening: true }), { type: 'listenEnd', now: 10000, cooldownMs: CD });
assert(r.state.listening === false && r.state.cooldownUntil === 11500, 'listenEnd sets cooldown now+CD');

// reply overlap: while Jarvis is SPEAKING, a wake (from the TTS saying "Jarvis") is suppressed; when
// the reply ends the cooldown is re-armed from that moment, then wake works again after it.
r = wakeReducer(S(), { type: 'replyStart', now: 20000, cooldownMs: CD });
assert(r.state.speaking === true, 'replyStart marks speaking');
r = wakeReducer(S({ speaking: true }), { type: 'wake', now: 21000, cooldownMs: CD });
assert(r.arm === false, 'wake during spoken reply is suppressed');
r = wakeReducer(S({ speaking: true }), { type: 'replyEnd', now: 26000, cooldownMs: CD });
assert(r.state.speaking === false && r.state.cooldownUntil === 27500, 'replyEnd clears speaking, arms cooldown from reply end');
r = wakeReducer(S({ cooldownUntil: 27500 }), { type: 'wake', now: 27000, cooldownMs: CD });
assert(r.arm === false, 'wake still suppressed until reply cooldown elapses');
r = wakeReducer(S({ cooldownUntil: 27500 }), { type: 'wake', now: 28000, cooldownMs: CD });
assert(r.arm === true, 'wake works again after the reply cooldown');

// unknown event is a no-op
r = wakeReducer(S(), { type: 'noise', now: 1, cooldownMs: CD });
assert(r.arm === false && r.state.listening === false, 'unknown event no-op');

console.log('node: all wakeword-gate assertions passed');
'@

$tmp = Join-Path $env:TEMP 'jarvis-wakeword-gate-test.js'
Set-Content -Path $tmp -Value $js -Encoding ascii
try {
  $out = cmd /c "node `"$tmp`" `"$((Resolve-Path $orb).Path)`" 2>&1"
} finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
Assert ($LASTEXITCODE -eq 0) "wakeword-gate assertions ($($out -join ' '))"
Write-Host "wakeword-gate: ALL PASS"
