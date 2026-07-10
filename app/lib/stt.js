// Speech-to-text: local whisper.cpp (no cloud, no keys - speech never leaves the machine).
// Binary + model live in app/vendor/whisper (gitignored); scripts/setup-whisper.ps1 fetches them.
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');

const VENDOR = path.join(__dirname, '..', 'vendor', 'whisper');

function findExe() {
  // whisper-cli.exe only: modern releases ship main.exe as a deprecation stub that exits 1
  const roots = [VENDOR, path.join(VENDOR, 'Release')];
  try {
    for (const d of fs.readdirSync(VENDOR, { withFileTypes: true }))
      if (d.isDirectory()) roots.push(path.join(VENDOR, d.name));
  } catch { return null; }
  for (const root of roots) {
    const p = path.join(root, 'whisper-cli.exe');
    if (fs.existsSync(p)) return p;
  }
  return null;
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
    if (!exe || !model) return reject(new Error('whisper not installed - run scripts/setup-whisper.ps1'));
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

module.exports = { transcribe, sttAvailable };
