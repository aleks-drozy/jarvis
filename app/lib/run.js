// PowerShell spawn helpers - the app reuses the proven skill/bin collectors, never reimplements them
const { execFile } = require('child_process');

function runPowerShell(scriptPath, args = [], timeoutMs = 180000) {
  return new Promise((resolve, reject) => {
    execFile('powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args],
      { timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024, windowsHide: true },
      (err, stdout, stderr) => err ? reject(new Error(stderr || err.message)) : resolve(stdout));
  });
}

async function runCollector(scriptPath, args) {
  const out = await runPowerShell(scriptPath, args);
  try { return JSON.parse(out); } catch { return { raw: out }; }
}

module.exports = { runPowerShell, runCollector };
