# tests/vad-calibration.Tests.ps1 - calibrateSilenceRms in orb.html: ambient-adaptive silence gate.
# orb.html keeps the function inline (no nodeIntegration), so we extract its source and exercise it in node
# (same technique as downsample.Tests.ps1).
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$orb = Join-Path $PSScriptRoot '..\app\renderer\orb.html'
Assert (Test-Path $orb) "orb.html present"
$node = Get-Command node -ErrorAction SilentlyContinue
Assert ($null -ne $node) "node on PATH (needed to exercise renderer JS)"

$js = @'
// pulls calibrateSilenceRms out of orb.html and checks the noise-floor -> threshold mapping + clamps
const fs = require('fs');
function fail(m) { console.error('FAIL: ' + m); process.exit(1); }
function assert(c, m) { if (!c) fail(m); }

const html = fs.readFileSync(process.argv[2], 'utf8');
const start = html.indexOf('function calibrateSilenceRms');
assert(start >= 0, 'calibrateSilenceRms found in orb.html');
let depth = 0, end = -1;
for (let i = html.indexOf('{', start); i < html.length; i++) {
  if (html[i] === '{') depth++;
  else if (html[i] === '}' && --depth === 0) { end = i + 1; break; }
}
assert(end > start, 'calibrateSilenceRms body extracted');
// eval is safe here: test-only process evaluating our own checked-in source (orb.html), no external input
const calibrateSilenceRms = eval('(' + html.slice(start, end) + ')');

const MIN = 0.008, MAX = 0.02, DEFAULT = 0.012;
function fill(n, v) { return new Array(n).fill(v); }

// 1) no samples -> documented fixed fallback (the original hand-tuned value)
assert(calibrateSilenceRms([]) === DEFAULT, 'empty samples -> 0.012 fallback, got ' + calibrateSilenceRms([]));
assert(calibrateSilenceRms(null) === DEFAULT, 'null samples -> 0.012 fallback');

// 2) quiet room (~0.004 ambient) -> threshold near 0.010 (0.004 * 2.5), reproducing the old good value
let t = calibrateSilenceRms(fill(8, 0.004));
assert(Math.abs(t - 0.010) < 0.0005, 'quiet room -> ~0.010, got ' + t);

// 3) dead-silent room (~0.001) -> clamps UP to MIN so tiny samples do not all read as speech
t = calibrateSilenceRms(fill(8, 0.001));
assert(t === MIN, 'dead room clamps to MIN 0.008, got ' + t);

// 4) loud room (~0.03 ambient) -> clamps DOWN to MAX so the bar never sits above real speech
t = calibrateSilenceRms(fill(8, 0.03));
assert(t === MAX, 'loud room clamps to MAX 0.05, got ' + t);

// 5) robustness: mostly-quiet window with a few speech-onset transients must NOT inflate the floor
//    (low-percentile floor ignores the loud tail). 6 quiet @0.004 + 2 loud @0.06.
t = calibrateSilenceRms([0.004,0.004,0.004,0.004,0.004,0.004,0.06,0.06]);
assert(Math.abs(t - 0.010) < 0.0015, 'transients do not inflate threshold, got ' + t);

// 6) output is ALWAYS within [MIN, MAX] across a sweep
for (const v of [0, 0.0001, 0.005, 0.01, 0.02, 0.05, 0.2, 1.0]) {
  const r = calibrateSilenceRms(fill(5, v));
  assert(r >= MIN && r <= MAX, 'threshold in-band for ambient ' + v + ', got ' + r);
}

console.log('node: all vad-calibration assertions passed');
'@

$tmp = Join-Path $env:TEMP 'jarvis-vad-calibration-test.js'
Set-Content -Path $tmp -Value $js -Encoding ascii
try {
  # node logs failures to stderr; under -EA Stop that would read as failure. cmd /c merges it away.
  $out = cmd /c "node `"$tmp`" `"$((Resolve-Path $orb).Path)`" 2>&1"
} finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
Assert ($LASTEXITCODE -eq 0) "vad-calibration assertions ($($out -join ' '))"
Write-Host "vad-calibration: ALL PASS"
