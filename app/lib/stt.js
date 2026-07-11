// Speech-to-text: local whisper.cpp (no cloud, no keys - speech never leaves the machine).
// Binary + model live in app/vendor/whisper (gitignored); scripts/setup-whisper.ps1 fetches them.
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');

const VENDOR = path.join(__dirname, '..', 'vendor', 'whisper');

// whisper.cpp has renamed its CLI before (main -> whisper-cli). Probe known names in preference
// order so one more upstream rename is a one-line change here, not a silent breakage.
const CLI_CANDIDATES = ['whisper-cli.exe', 'whisper.exe', 'whisper-cpp.exe'];
const DEPRECATED_STUB = 'main.exe'; // modern releases ship this as a stub that exits 1 - never use it

function whisperRoots() {
  const roots = [VENDOR, path.join(VENDOR, 'Release')];
  try {
    for (const d of fs.readdirSync(VENDOR, { withFileTypes: true }))
      if (d.isDirectory()) roots.push(path.join(VENDOR, d.name));
  } catch { /* VENDOR missing entirely - handled by callers */ }
  return roots;
}

function findExe() {
  for (const root of whisperRoots()) {
    for (const name of CLI_CANDIDATES) {
      const p = path.join(root, name);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

// Explain WHY STT is unavailable so a future upstream rename gives an actionable message
// instead of a misleading "not installed - re-run setup" (which would also fail).
function sttDiagnosis() {
  if (findExe()) return { ok: true };
  const exes = new Set();
  for (const root of whisperRoots()) {
    try { for (const f of fs.readdirSync(root)) if (/\.exe$/i.test(f)) exes.add(f.toLowerCase()); }
    catch { /* root missing */ }
  }
  if (exes.size === 0)
    return { ok: false, reason: `Voice input needs Whisper, Sir - run scripts/setup-whisper.ps1 once (expects one of ${CLI_CANDIDATES.join(', ')} in app/vendor/whisper).` };
  if (exes.size === 1 && exes.has(DEPRECATED_STUB))
    return { ok: false, reason: `Found only ${DEPRECATED_STUB} (deprecated whisper.cpp stub); the real CLI is ${CLI_CANDIDATES[0]}. Re-run scripts/setup-whisper.ps1.` };
  return { ok: false, reason: `A Whisper binary is present (${[...exes].join(', ')}) but under an unrecognized name - whisper.cpp may have renamed its CLI again. Add it to CLI_CANDIDATES in app/lib/stt.js.` };
}

function findModel() {
  try {
    const m = fs.readdirSync(VENDOR).find((f) => /^ggml-.*\.bin$/.test(f));
    return m ? path.join(VENDOR, m) : null;
  } catch { return null; }
}

function sttAvailable() { return !!(findExe() && findModel()); }

// wavPath must be 16 kHz mono 16-bit PCM (the orb's encoder produces exactly that)
function transcribe(wavPath) {
  return new Promise((resolve, reject) => {
    const exe = findExe(); const model = findModel();
    if (!exe) return reject(new Error(sttDiagnosis().reason));
    if (!model) return reject(new Error('Whisper model missing - run scripts/setup-whisper.ps1 to fetch ggml-base.en.'));
    execFile(exe, ['-m', model, '-f', wavPath, '-nt', '-np', '-l', 'en'],
      { timeout: 60000, maxBuffer: 1024 * 1024, windowsHide: true },
      (err, stdout) => {
        if (err) return reject(err);
        resolve(String(stdout)
          .replace(/\[[^\]]*\]|\([^)]*\)/g, ' ')   // strip [BLANK_AUDIO]-style + (noise) annotations
          .replace(/\s+/g, ' ').trim());
      });
  });
}

module.exports = { transcribe, sttAvailable, sttDiagnosis };
