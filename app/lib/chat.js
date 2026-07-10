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
  'Be FAST: read only files each request needs; act (write your usual vault files per your rules). ' +
  'REPLY FORMAT (hard rule - the app parses it): EXACTLY two lines. ' +
  'Line 1: "SPOKEN: " then your natural butler reply, 1-2 short sentences, read aloud to Alex. ' +
  'Line 2: "CHIPS: " then 2-6 telegraph key phrases separated by " · ", 15 words total max, shown on screen. ' +
  'Plain text, no markdown. Example:\n' +
  'SPOKEN: Gym at noon, Sir, and your allowance holds at forty-two euro.\n' +
  'CHIPS: gym 12:00 · allowance EUR 42 · Vodafone follow-up Thu';

// the model returns SPOKEN (voice) + CHIPS (screen); tolerate a misformatted reply gracefully
function splitReply(res) {
  const m = String(res.text).match(/SPOKEN:\s*([\s\S]*?)\s*CHIPS:\s*([\s\S]*)/i);
  if (!m) return res;
  return { ...res, say: m[1].trim(), text: m[2].trim() || m[1].trim() };
}

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
    '--verbose',        // REQUIRED with -p + stream-json output; without it the CLI exits 1 in ~3s
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
  // stderr goes to the log, never to the void - this exact blindness hid the --verbose bug for 2 days
  proc.stderr.on('data', (d) => tlog('session stderr: ' + d.toString().trim().slice(0, 200)));
  proc.on('error', (e) => {
    tlog('session spawn error: ' + e.message);
    if (pending) { clearTimeout(pending.timer); pending.resolve({ ok: false, text: 'My session dropped, Sir. Say that again?' }); pending = null; }
    proc = null; busy = false;
  });
  proc.on('exit', (code) => {
    tlog('session exit code=' + code);
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
    const child = execFile(CLAUDE_EXE, ['-p', prompt,
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
    child.stdin.end();   // open-but-silent stdin makes the CLI stall 3s and warn; close it outright
  });
}

async function waitNotBusy(ms) {
  const t0 = Date.now();
  while (busy && Date.now() - t0 < ms) await new Promise((r) => setTimeout(r, 200));
  return !busy;
}

async function sendChat(message) {
  if (!fs.existsSync(CLAUDE_EXE)) return { ok: false, text: 'claude.exe not found, Sir.' };
  try { getToken(); } catch { return { ok: false, text: 'No Claude token found, Sir. Run claude setup-token.' }; }
  if (busy) {
    // a warmup in flight is not a real errand: wait it out, then proceed
    if (!warming || !(await waitNotBusy(45000)))
      return { ok: false, text: 'One errand at a time, Sir - still working on the last one.' };
  }
  try {
    const res = await sendViaSession(message);
    // streaming session hard-failed at transport level -> try one cold shot
    if (!res.ok && /session dropped|write failed/i.test(res.text)) return splitReply(await sendOneShot(message));
    return splitReply(res);
  } catch { return splitReply(await sendOneShot(message)); }
}

// Warm the session ahead of need (app start / summon / mic press). A REAL turn is sent, not a bare
// spawn: an idle stream-json session self-terminates ("no stdin data received in 3s"), and the
// warmup turn also pre-pays the SKILL.md read so the first real reply is fast.
let warming = false;
function prewarm() {
  if (busy || warming || (proc && !proc.killed)) return;
  try { getToken(); } catch { return; }
  warming = true;
  tlog('prewarm: sending warmup turn');
  sendViaSession('Warmup ping, no user present. Read your skill file now so later replies are fast, then reply with exactly: ready')
    .then((r) => { warming = false; tlog('prewarm done ok=' + !!(r && r.ok)); })
    .catch(() => { warming = false; });
}

module.exports = { sendChat, prewarm };
