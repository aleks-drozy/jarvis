# tests/downsample.Tests.ps1 - encodeWav16k in orb.html: box-filter downsample, no aliasing above 8 kHz.
# orb.html keeps the function inline (no nodeIntegration), so we extract its source and exercise it in node.
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$orb = Join-Path $PSScriptRoot '..\app\renderer\orb.html'
Assert (Test-Path $orb) "orb.html present"
$node = Get-Command node -ErrorAction SilentlyContinue
Assert ($null -ne $node) "node on PATH (needed to exercise renderer JS)"

$js = @'
// pulls encodeWav16k out of orb.html and checks header layout, lengths, averaging, and anti-alias behavior
const fs = require('fs');
function fail(m) { console.error('FAIL: ' + m); process.exit(1); }
function assert(c, m) { if (!c) fail(m); }

const html = fs.readFileSync(process.argv[2], 'utf8');
const start = html.indexOf('function encodeWav16k');
assert(start >= 0, 'encodeWav16k found in orb.html');
let depth = 0, end = -1;
for (let i = html.indexOf('{', start); i < html.length; i++) {
  if (html[i] === '{') depth++;
  else if (html[i] === '}' && --depth === 0) { end = i + 1; break; }
}
assert(end > start, 'encodeWav16k body extracted');
// eval is safe here: test-only process evaluating our own checked-in source (orb.html), no external input
const encodeWav16k = eval('(' + html.slice(start, end) + ')');

function sine(freq, rate, n, amp) {
  const a = new Float32Array(n);
  for (let i = 0; i < n; i++) a[i] = amp * Math.sin(2 * Math.PI * freq * i / rate);
  return a;
}
function dc(n, v) { return new Float32Array(n).fill(v); }
function pcm(buf) {
  const v = new DataView(buf);
  const n = v.getUint32(40, true) / 2, out = new Int16Array(n);
  for (let i = 0; i < n; i++) out[i] = v.getInt16(44 + 2 * i, true);
  return out;
}
function rms(a) { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * a[i]; return Math.sqrt(s / a.length); }
function tag(buf, off, len) { return Buffer.from(buf, off, len).toString('ascii'); }

// 1) header layout + integer-ratio length: 48000 samples @ 48k -> 16000 samples of valid 16 kHz mono WAV
let buf = encodeWav16k([dc(48000, 0.25)], 48000);
const v = new DataView(buf);
assert(buf.byteLength === 44 + 16000 * 2, 'byteLength = 44 + outLen*2');
assert(tag(buf, 0, 4) === 'RIFF' && tag(buf, 8, 4) === 'WAVE' && tag(buf, 12, 4) === 'fmt ' && tag(buf, 36, 4) === 'data', 'RIFF/WAVE/fmt/data tags');
assert(v.getUint32(4, true) === 36 + 16000 * 2, 'RIFF chunk size');
assert(v.getUint16(20, true) === 1 && v.getUint16(22, true) === 1, 'PCM, mono');
assert(v.getUint32(24, true) === 16000 && v.getUint32(28, true) === 32000, '16 kHz, 32000 bytes/s');
assert(v.getUint16(32, true) === 2 && v.getUint16(34, true) === 16, 'block align 2, 16-bit');
assert(v.getUint32(40, true) === 16000 * 2, 'data chunk size');

// 2) DC v in -> every sample ~v out (averaging sanity, integer ratio)
let s = pcm(buf);
for (let i = 0; i < s.length; i++) assert(Math.abs(s[i] - 0.25 * 0x7fff) <= 2, 'DC 0.25 @ 48k -> ~8192, got ' + s[i] + ' at ' + i);

// input not divisible by 3 still floors: 48001 -> 16000
assert(encodeWav16k([dc(48001, 0.25)], 48000).byteLength === 44 + 16000 * 2, 'outLen = floor(input/3)');

// 3) DC through the non-integer ratio path (44.1k -> 16k, ratio 2.75625)
s = pcm(encodeWav16k([dc(44100, 0.5)], 44100));
assert(s.length === 16000, '44100 @ 44.1k -> 16000 samples, got ' + s.length);
for (let i = 0; i < s.length; i++) assert(Math.abs(s[i] - 0.5 * 0x7fff) <= 2, 'DC 0.5 @ 44.1k -> ~16384, got ' + s[i] + ' at ' + i);

// 4) out-of-range input clamps to int16 extremes
s = pcm(encodeWav16k([dc(48, 1.5), dc(48, -1.5)], 48000));
assert(s[0] === 32767 && s[s.length - 1] === -32768, 'clamps to int16');

// 5) a 1 kHz sine (well under 8 kHz) survives multi-chunk input at ~full amplitude
const tone = sine(1000, 48000, 48000, 0.5);
const chunks = [];
for (let o = 0; o < tone.length; o += 4096) chunks.push(tone.subarray(o, Math.min(o + 4096, tone.length)));
s = pcm(encodeWav16k(chunks, 48000));
assert(s.length === 16000, '1 kHz tone keeps 16000 samples, got ' + s.length);
const nominal = 0.5 * 0x7fff / Math.SQRT2;
assert(Math.abs(rms(s) - nominal) / nominal < 0.03, '1 kHz rms within 3%: got ' + rms(s).toFixed(0) + ' vs ' + nominal.toFixed(0));

// 6) anti-alias: 12 kHz sits above the 8 kHz output Nyquist and must come out attenuated, not folded back at full level
s = pcm(encodeWav16k([sine(12000, 48000, 48000, 0.5)], 48000));
assert(rms(s) < 0.5 * nominal, '12 kHz attenuated: rms ' + rms(s).toFixed(0) + ' not < ' + (0.5 * nominal).toFixed(0));

console.log('node: all downsample assertions passed');
'@

$tmp = Join-Path $env:TEMP 'jarvis-downsample-test.js'
Set-Content -Path $tmp -Value $js -Encoding ascii
try {
  # node logs failures to stderr; under -EA Stop that would read as failure. cmd /c merges it away.
  $out = cmd /c "node `"$tmp`" `"$((Resolve-Path $orb).Path)`" 2>&1"
} finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
Assert ($LASTEXITCODE -eq 0) "downsampler assertions ($($out -join ' '))"
Write-Host "downsample: ALL PASS"
