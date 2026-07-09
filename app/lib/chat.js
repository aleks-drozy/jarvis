// Chat: talks to the REAL Jarvis - spawns `claude -p` with the jarvis skill and the same
// encrypted OAuth token the 08:30 scheduler uses. Jarvis's hard safety rules apply unchanged.
const { execFile, execFileSync } = require('child_process');

let cachedToken = null;
function getToken() {
  if (cachedToken) return cachedToken;
  // decrypt exactly like jarvis-debrief.ps1 does (DPAPI clixml, PSCredential wrapper)
  const ps = `$sec = Import-Clixml "$HOME\\.jarvis\\claude-token.xml"; ` +
    `(New-Object System.Management.Automation.PSCredential('t', $sec)).GetNetworkCredential().Password`;
  cachedToken = execFileSync('powershell.exe', ['-NoProfile', '-Command', ps],
    { windowsHide: true, timeout: 15000 }).toString().trim();
  return cachedToken;
}

function sendChat(message) {
  return new Promise((resolve) => {
    let token;
    try { token = getToken(); }
    catch { return resolve({ ok: false, text: 'No Claude token found, Sir. Run claude setup-token.' }); }
    const prompt = 'You are Jarvis (skill at ~/.claude/skills/jarvis/SKILL.md - load it and obey its ' +
      'safety rules). Alex says, via the desktop app: "' + String(message).replace(/"/g, "'") + '". ' +
      'Act on it (you may read/write your usual vault files per your rules) and reply as Jarvis, ' +
      'concisely - 1 to 4 sentences, no markdown headers.';
    execFile('claude', ['-p', prompt,
      '--permission-mode', 'acceptEdits',
      '--allowedTools', 'Read Write Edit Bash Glob Grep',
      '--output-format', 'text'],
      {
        timeout: 120000, maxBuffer: 4 * 1024 * 1024, windowsHide: true, shell: true,
        env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: token },
      },
      (err, stdout, stderr) => {
        if (err) return resolve({ ok: false, text: 'That errand failed, Sir: ' + (stderr || err.message).slice(0, 300) });
        resolve({ ok: true, text: String(stdout).trim() || '(done, Sir)' });
      });
  });
}

module.exports = { sendChat };
