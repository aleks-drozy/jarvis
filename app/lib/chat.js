// Chat: talks to the REAL Jarvis - spawns claude.exe DIRECTLY (no shell = no quote mangling;
// v1 bug: shell:true made cmd.exe split the prompt at quotes and Claude received just "You").
const { execFile, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const CLAUDE_EXE = path.join(process.env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links', 'claude.exe');

let cachedToken = null;
function getToken() {
  if (cachedToken) return cachedToken;
  const ps = `$sec = Import-Clixml "$HOME\\.jarvis\\claude-token.xml"; ` +
    `(New-Object System.Management.Automation.PSCredential('t', $sec)).GetNetworkCredential().Password`;
  cachedToken = execFileSync('powershell.exe', ['-NoProfile', '-Command', ps],
    { windowsHide: true, timeout: 15000 }).toString().trim();
  return cachedToken;
}

function sendChat(message) {
  return new Promise((resolve) => {
    if (!fs.existsSync(CLAUDE_EXE)) return resolve({ ok: false, text: 'claude.exe not found, Sir.' });
    let token;
    try { token = getToken(); }
    catch { return resolve({ ok: false, text: 'No Claude token found, Sir. Run claude setup-token.' }); }
    const prompt =
      'You are Jarvis, Alex\'s butler (personality + HARD safety rules in ' +
      '~/.claude/skills/jarvis/SKILL.md - read it first and obey it). ' +
      'Alex says, via the desktop app: <<<' + String(message) + '>>>\n' +
      'Be FAST: read only the files this specific request needs, act (you may write your usual ' +
      'vault files per your rules), then reply as Jarvis in 1-3 short sentences, plain text.';
    execFile(CLAUDE_EXE, ['-p', prompt,
      '--permission-mode', 'acceptEdits',
      '--allowedTools', 'Read Write Edit Bash Glob Grep',
      '--output-format', 'text'],
      {
        timeout: 180000, maxBuffer: 4 * 1024 * 1024, windowsHide: true,
        env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: token },
      },
      (err, stdout, stderr) => {
        if (err) return resolve({ ok: false, text: 'That errand failed, Sir: ' + (stderr || err.message).slice(0, 300) });
        resolve({ ok: true, text: String(stdout).trim() || '(done, Sir)' });
      });
  });
}

module.exports = { sendChat };
