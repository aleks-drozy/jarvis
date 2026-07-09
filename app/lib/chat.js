// Chat v2: ONE persistent warm Jarvis session (stream-json pipe) instead of a cold boot per
// message. First reply pays startup once; later replies are fast. Falls back to one-shot
// execFile if the streaming session misbehaves.
const { spawn, execFile, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const CLAUDE_EXE = path.join(process.env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links', 'claude.exe');
const CHAT_LOG = path.join(__dirname, '..', 'chat-timing.log');
function tlog(msg) {
  try { fs.appendFileSync(CHAT_LOG, new Date().toISOString().slice(11, 19) + ' ' + msg + '\n'); } catch {}
}
const PERSONA =
  "You are Jarvis, Alex's butler (personality + HARD safety rules in ~/.claude/skills/jarvis/SKILL.md - " +
  'read it once and obey it for the whole conversation). Messages come from Alex via his desktop app. ' +
  'Be FAST: read only files each request needs; act (write your usual vault files per your rules); ' +
  'reply as Jarvis in 1-3 short sentences, plain text, no markdown.';

let cachedToken = null;
function getToken() {
  if (cachedToken) return cachedToken;
  const ps = `$sec = Import-Clixml "$HOME\\.jarvis\\claude-token.xml"; ` +
    `(New-Object System.Management.Automation.PSCredential('t', $sec)).GetNetworkCredential().Password`;
  cachedToken = execFileSync('powershell.exe', ['-NoProfile', '-Command', ps],
    { windowsHide: true, timeout: 15000 }).toString().trim();
  return cachedToken;
}

// ---------- persistent session ----------
let proc = null;
let buf = '';
let pending = null;   // { resolve, timer } - one in-flight message at a time
let busy = false;
let idleTimer = null; // RAM courtesy: 7.4GB machine - warm session self-terminates after idle
const IDLE_MS = 5 * 60 * 1000;

function armIdleShutdown() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    if (proc && !busy) { tlog('idle shutdown (freeing RAM)'); try { proc.stdin.end(); proc.kill(); } catch {} proc = null; }
  }, IDLE_MS);
}

function ensureSession() {
  if (proc && !proc.killed) return;
  buf = '';
  proc = spawn(CLAUDE_EXE, [
    '-p',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--append-system-prompt', PERSONA,
    '--model', 'sonnet',                                          // butler errands: fast model, not the flagship
    '--permission-mode', 'acceptEdits',
    '--allowedTools', 'Read Write Edit Bash Glob Grep',
    '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',   // skip MCP servers: chat needs none
  ], {
    windowsHide: true,
    env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: getToken() },
  });
  proc.stdout.on('data', (d) => {
    buf += d.toString();
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      let ev;
      try { ev = JSON.parse(line); } catch { continue; }
      tlog('event: ' + ev.type + (ev.subtype ? '/' + ev.subtype : '') +
        (ev.type === 'assistant' && ev.message ? ' (' + JSON.stringify(ev.message.content || '').slice(0, 80) + ')' : ''));
      if (ev.type === 'result' && pending) {
        clearTimeout(pending.timer);
        const text = (ev.result || '').trim();
        pending.resolve({ ok: !ev.is_error, text: text || '(done, Sir)' });
        pending = null; busy = false;
        armIdleShutdown();
      }
    }
  });
  proc.on('exit', () => {
    if (pending) { clearTimeout(pending.timer); pending.resolve({ ok: false, text: 'My session dropped, Sir. Say that again?' }); pending = null; }
    proc = null; busy = false;
  });
}

function sendViaSession(message) {
  return new Promise((resolve) => {
    const wasAlive = !!(proc && !proc.killed);
    ensureSession();
    tlog('send (session ' + (wasAlive ? 'REUSED' : 'SPAWNED') + '): ' + String(message).slice(0, 60));
    busy = true;
    pending = {
      resolve,
      timer: setTimeout(() => {
        if (pending) { pending = null; busy = false; try { proc.kill(); } catch {} proc = null;
          resolve({ ok: false, text: 'That took too long, Sir - I have reset myself. Try once more.' }); }
      }, 180000),
    };
    const line = JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: String(message) }] } }) + '\n';
    try { proc.stdin.write(line); }
    catch { clearTimeout(pending.timer); pending = null; busy = false; proc = null;
      resolve({ ok: false, text: 'Session write failed, Sir. Try again.' }); }
  });
}

// ---------- one-shot fallback ----------
function sendOneShot(message) {
  return new Promise((resolve) => {
    const prompt = PERSONA + '\nAlex says: <<<' + String(message) + '>>>';
    execFile(CLAUDE_EXE, ['-p', prompt,
      '--permission-mode', 'acceptEdits',
      '--allowedTools', 'Read Write Edit Bash Glob Grep',
      '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
      '--output-format', 'text'],
      { timeout: 180000, maxBuffer: 4 * 1024 * 1024, windowsHide: true,
        env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: getToken() } },
      (err, stdout, stderr) => {
        if (err) return resolve({ ok: false, text: 'That errand failed, Sir: ' + (stderr || err.message).slice(0, 300) });
        resolve({ ok: true, text: String(stdout).trim() || '(done, Sir)' });
      });
  });
}

async function sendChat(message) {
  if (!fs.existsSync(CLAUDE_EXE)) return { ok: false, text: 'claude.exe not found, Sir.' };
  try { getToken(); } catch { return { ok: false, text: 'No Claude token found, Sir. Run claude setup-token.' }; }
  if (busy) return { ok: false, text: 'One errand at a time, Sir - still working on the last one.' };
  try {
    const res = await sendViaSession(message);
    // streaming session hard-failed at transport level -> try one cold shot
    if (!res.ok && /session dropped|write failed/i.test(res.text)) return await sendOneShot(message);
    return res;
  } catch { return await sendOneShot(message); }
}

module.exports = { sendChat };
