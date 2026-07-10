// Jarvis Companion - main process
// Tray butler: dashboard window, HUD one-liners, voice, chat. The app shell READS and DISPLAYS;
// all writes happen through the real Jarvis skill (chat) or existing scripts. Single-writer rule.
const { app, Tray, Menu, BrowserWindow, ipcMain, nativeImage, screen, shell, globalShortcut, session } = require('electron');
const path = require('path');
const fs = require('fs');

const VAULT = 'C:/Users/Alex/ObsidianVault/claude-memory/12-jarvis';
const ROADMAP_INDEX = 'C:/Users/Alex/ObsidianVault/Life Roadmap 2026-2027/_INDEX.md';
const BIN = path.join(process.env.USERPROFILE, '.claude', 'skills', 'jarvis', 'bin');
const APP_CONFIG = path.join(__dirname, 'app-config.json');

const { runPowerShell, runCollector } = require('./lib/run');
const { speak } = require('./lib/voice');
const { sendChat, prewarm } = require('./lib/chat');
const { transcribe, sttAvailable } = require('./lib/stt');

let tray = null;
let dashboard = null;
let hud = null;
let hudTimer = null;
let orb = null;
let summon = null;
let state = loadState();

function loadState() {
  try { return JSON.parse(fs.readFileSync(APP_CONFIG, 'utf8')); }
  catch { return { muted: false, voice: 'en-US-AndrewMultilingualNeural' }; }
}
function saveState() { try { fs.writeFileSync(APP_CONFIG, JSON.stringify(state, null, 2)); } catch {} }

// ---------- tray ----------
function todayNotePath() {
  const d = new Date();
  const iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  return path.join(VAULT, 'debriefs', `${iso}.md`);
}

function createTray() {
  const icon = nativeImage.createFromPath(path.join(__dirname, 'assets', 'tray.png'));
  tray = new Tray(icon);
  tray.setToolTip('Jarvis');
  refreshTrayMenu();
  tray.on('click', () => toggleSummon());
}

function refreshTrayMenu() {
  const menu = Menu.buildFromTemplate([
    { label: 'Summon Jarvis  (Ctrl+Shift+J)', click: () => toggleSummon() },
    { label: 'Read briefing aloud', click: () => readBriefingAloud() },
    { label: 'Debrief now', click: () => debriefNow() },
    { label: 'Classic dashboard', click: () => toggleDashboard(true) },
    { type: 'separator' },
    { label: state.muted ? 'Unmute voice' : 'Mute voice', click: () => { state.muted = !state.muted; saveState(); refreshTrayMenu(); } },
    { label: (state.orbHidden ? 'Show orb' : 'Hide orb') + '  (Ctrl+Shift+O)', click: () => toggleOrb() },
    { label: 'Open vault folder', click: () => shell.openPath(VAULT.replace(/\//g, '\\')) },
    { type: 'separator' },
    { label: 'Quit Jarvis', click: () => app.quit() },
  ]);
  tray.setContextMenu(menu);
}

// ---------- orb (constant presence, owns audio playback) ----------
function createOrb() {
  const wa = screen.getPrimaryDisplay().workArea;
  orb = new BrowserWindow({
    width: 104, height: 104,
    x: wa.x + wa.width - 124, y: wa.y + wa.height - 124,
    frame: false, transparent: true, resizable: false, alwaysOnTop: true,
    skipTaskbar: true, hasShadow: false, show: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
  });
  orb.loadFile(path.join(__dirname, 'renderer', 'orb.html'));
  orb.setAlwaysOnTop(true, 'screen-saver');
  if (state.orbHidden) orb.hide();   // hidden orb still plays audio (window lives, invisible)
}
function toggleOrb() {
  if (!orb || orb.isDestroyed()) return;
  state.orbHidden = !state.orbHidden;
  if (state.orbHidden) orb.hide(); else orb.showInactive();
  saveState();
  refreshTrayMenu();
}
function orbPlay(file) {
  if (orb && !orb.isDestroyed()) orb.webContents.send('audio:play', file);
}

// ---------- summon (full-screen HUD overlay) ----------
function toggleSummon() {
  if (summon && !summon.isDestroyed() && summon.isVisible()) { summon.hide(); return; }
  prewarm();                       // claude session boots while Alex reads the HUD and types
  if (!summon || summon.isDestroyed()) {
    const b = screen.getPrimaryDisplay().bounds;
    summon = new BrowserWindow({
      x: b.x, y: b.y, width: b.width, height: b.height,
      frame: false, transparent: true, resizable: false, movable: false,
      alwaysOnTop: true, skipTaskbar: true, hasShadow: false, show: false,
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
    });
    summon.loadFile(path.join(__dirname, 'renderer', 'summon.html'));
    summon.once('ready-to-show', () => { summon.show(); summon.focus(); summon.webContents.send('summon:show'); });
  } else {
    summon.show(); summon.focus(); summon.webContents.send('summon:show');
  }
}

// ---------- dashboard ----------
function toggleDashboard(forceShow) {
  if (dashboard && !dashboard.isDestroyed()) {
    if (forceShow || !dashboard.isVisible()) { dashboard.show(); dashboard.focus(); }
    else dashboard.hide();
    return;
  }
  dashboard = new BrowserWindow({
    width: 980, height: 680, show: true, autoHideMenuBar: true,
    title: 'Jarvis', backgroundColor: '#0b0f14',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  dashboard.loadFile(path.join(__dirname, 'renderer', 'dashboard.html'));
  dashboard.on('close', (e) => { e.preventDefault(); dashboard.hide(); }); // stay resident in tray
}

// ---------- HUD one-liner ----------
function showHud(text, opts = {}) {
  const { width } = screen.getPrimaryDisplay().workAreaSize;
  const hudW = 560, hudH = 92;
  if (!hud || hud.isDestroyed()) {
    hud = new BrowserWindow({
      width: hudW, height: hudH, x: Math.round((width - hudW) / 2), y: 28,
      frame: false, transparent: true, resizable: false, movable: false,
      alwaysOnTop: true, skipTaskbar: true, focusable: false, show: false, hasShadow: false,
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
    });
    hud.loadFile(path.join(__dirname, 'renderer', 'hud.html'));
    hud.once('ready-to-show', () => pushHud(text, opts));
  } else {
    pushHud(text, opts);
  }
}
function pushHud(text, opts) {
  hud.showInactive();
  hud.webContents.send('hud:show', { text, kind: opts.kind || 'info' });
  clearTimeout(hudTimer);
  hudTimer = setTimeout(() => {
    if (!hud || hud.isDestroyed()) return;
    hud.webContents.send('hud:hide');                       // quiet 200ms fade (texts-reveal exit)
    setTimeout(() => { if (hud && !hud.isDestroyed()) hud.hide(); }, 260);
  }, opts.holdMs || 7000);
  if (!state.muted && opts.speak !== false) {
    speak(opts.say || text, state.voice).then(file => orbPlay(file)).catch(() => {});
  }
}

// ---------- actions ----------
async function readBriefingAloud() {
  const p = todayNotePath();
  if (!fs.existsSync(p)) { showHud('No briefing yet today, Sir.', { speak: true }); return; }
  let text = fs.readFileSync(p, 'utf8')
    .replace(/^---[\s\S]*?---\s*/, '')            // frontmatter
    .replace(/[#*`|>\[\]]/g, ' ')                  // md noise
    .replace(/[\u{1F300}-\u{1FAFF}☀-➿]/gu, '') // emoji
    .replace(/\s{2,}/g, ' ').trim();
  if (text.length > 2600) text = text.slice(0, 2600) + ' ... and further detail is in the written briefing, Sir.';
  if (state.muted) { showHud('Voice is muted, Sir. The briefing is on screen.', { speak: false }); toggleDashboard(true); return; }
  const file = await speak(text, state.voice).catch(() => null);
  if (file) { showHud('Reading your briefing, Sir.', { speak: false }); orbPlay(file); }
}

function debriefNow() {
  showHud('Preparing a fresh debrief, Sir. Give me a minute or two.', { speak: true });
  runPowerShell(path.join(BIN, 'jarvis-debrief.ps1'), [])
    .then(() => showHud('Debrief refreshed and emailed, Sir.', { speak: true }))
    .catch(() => showHud('The debrief run failed, Sir. Check the log.', { kind: 'alert', speak: true }));
}

// ---------- voice input (Ctrl+Shift+Space: press to talk, auto-stops on silence) ----------
let listening = false;
function toggleListen() {
  if (!orb || orb.isDestroyed()) return;
  if (!listening && !sttAvailable()) {
    showHud('Voice input needs Whisper, Sir - run scripts/setup-whisper.ps1 once.', { kind: 'alert', speak: false });
    return;
  }
  listening = !listening;
  if (listening) {
    prewarm();                                  // session boots while Alex speaks
    if (state.orbHidden) toggleOrb();           // listening deserves a visible ear
    orb.webContents.send('mic:start');
  } else {
    orb.webContents.send('mic:stop');           // manual stop: transcribe whatever was said
  }
}

async function handleSpeech(wavBuf) {
  listening = false;
  const tmp = path.join(require('os').tmpdir(), `jarvis-mic-${Date.now()}.wav`);
  try {
    fs.writeFileSync(tmp, Buffer.from(wavBuf));
    const text = await transcribe(tmp);
    if (!text || text.length < 2) { showHud('I caught nothing intelligible, Sir.', { speak: false, holdMs: 3000 }); return; }
    showHud('“' + text + '”', { speak: false, holdMs: 5000 });
    const res = await sendChat(text);
    // chips on screen, natural sentence aloud
    showHud(res.text, { kind: res.ok ? 'info' : 'alert', holdMs: 9000, say: res.say });
  } catch (err) {
    showHud('Transcription failed, Sir: ' + String(err.message).slice(0, 120), { kind: 'alert', speak: false });
  } finally { try { fs.unlinkSync(tmp); } catch {} }
}

// ---------- watchers ----------
function startWatchers() {
  const debriefDir = path.join(VAULT, 'debriefs');
  let lastNoteMtime = 0;
  try { if (fs.existsSync(todayNotePath())) lastNoteMtime = fs.statSync(todayNotePath()).mtimeMs; } catch {}
  fs.watch(debriefDir, { persistent: true }, (_e, filename) => {
    if (!filename || !filename.endsWith('.md')) return;
    const p = path.join(debriefDir, filename);
    try {
      const m = fs.statSync(p).mtimeMs;
      if (p === todayNotePath() && m > lastNoteMtime + 1000) {
        lastNoteMtime = m;
        showHud('Your briefing is ready, Sir.', { kind: 'info' });
        if (dashboard && !dashboard.isDestroyed()) dashboard.webContents.send('data:refresh');
      }
    } catch {}
  });
  // failure alarm: tail .jarvis.log for FAILED lines
  const log = path.join(debriefDir, '.jarvis.log');
  let lastSize = fs.existsSync(log) ? fs.statSync(log).size : 0;
  fs.watch(path.dirname(log), (_e, f) => {
    if (f !== '.jarvis.log' || !fs.existsSync(log)) return;
    try {
      const size = fs.statSync(log).size;
      if (size > lastSize) {
        const tail = fs.readFileSync(log, 'utf8').slice(lastSize);
        lastSize = size;
        if (/FAILED/i.test(tail)) showHud('A scheduled run failed, Sir. The log has details.', { kind: 'alert' });
      } else lastSize = size;
    } catch {}
  });
}

// ---------- IPC ----------
function registerIpc() {
  ipcMain.handle('vault:read', (_ev, name) => {
    const allow = {
      briefing: todayNotePath(),
      jobs: path.join(VAULT, 'JOB_SEARCH.md'),
      finance: path.join(VAULT, 'FINANCE.md'),
      ledger: path.join(VAULT, 'LEDGER.md'),
      suggestions: path.join(VAULT, 'SUGGESTIONS.md'),
      config: path.join(VAULT, 'CONFIG.md'),
      roadmap: ROADMAP_INDEX,
    };
    const p = allow[name];
    if (!p) return null;
    try { return fs.readFileSync(p, 'utf8'); } catch { return null; }
  });
  ipcMain.handle('collector:calendar', () => runCollector(path.join(BIN, 'get-calendar.ps1'), []));
  ipcMain.handle('collector:inbox', () => runCollector(path.join(BIN, 'check-job-mail.ps1'), ['-Mode', 'inbox', '-SinceHours', '24']));
  ipcMain.handle('collector:activity', () => runCollector(path.join(BIN, 'collect-activity.ps1'), ['-SinceHours', '24']));
  ipcMain.handle('live:status', () => {
    const out = { lastRun: null, lastRunOk: null, activeSessions: 0 };
    try {
      const log = fs.readFileSync(path.join(VAULT, 'debriefs', '.jarvis.log'), 'utf8').trim().split('\n');
      const last = log[log.length - 1] || '';
      out.lastRun = last.slice(0, 19); out.lastRunOk = /run ok/.test(last);
    } catch {}
    try {
      const projRoot = path.join(process.env.USERPROFILE, '.claude', 'projects');
      const cutoff = Date.now() - 30 * 60 * 1000;
      const walk = (dir, depth) => {
        if (depth > 2) return;
        for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
          const p = path.join(dir, f.name);
          if (f.isDirectory()) walk(p, depth + 1);
          else if (f.name.endsWith('.jsonl') && fs.statSync(p).mtimeMs > cutoff) out.activeSessions++;
        }
      };
      walk(projRoot, 0);
    } catch {}
    return out;
  });
  ipcMain.handle('chat:send', async (_ev, message) => sendChat(message));
  ipcMain.handle('voice:speak', async (_ev, text) => state.muted ? null : speak(text, state.voice));
  ipcMain.handle('app:state', () => state);
  ipcMain.handle('app:setVoice', (_ev, v) => { state.voice = v; saveState(); return state; });
  ipcMain.handle('mic:audio', (_ev, wavBuf) => handleSpeech(wavBuf));
  ipcMain.on('mic:cancelled', (_ev, reason) => {
    listening = false;
    if (reason === 'denied') showHud('Microphone blocked, Sir - allow it in Windows privacy settings.', { kind: 'alert', speak: false });
    else showHud('Never mind, Sir.', { speak: false, holdMs: 2200 });
  });
  ipcMain.on('hud:clicked', () => { if (hud && !hud.isDestroyed()) hud.hide(); toggleSummon(); });
  ipcMain.on('summon:toggle', () => toggleSummon());
  ipcMain.on('orb:hide', () => { if (!state.orbHidden) toggleOrb(); });
  ipcMain.on('summon:hide', () => { if (summon && !summon.isDestroyed()) summon.hide(); });
}

// ---------- lifecycle ----------
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) app.quit();
else {
  app.setAppUserModelId('com.alexdrozdovs.jarvis');   // R-C: required for Windows notifications
  app.whenReady().then(() => {
    // mic only, and only for our own file:// renderers (voice input lives in the orb)
    session.defaultSession.setPermissionRequestHandler((_wc, permission, cb) => cb(permission === 'media'));
    createTray();
    createOrb();
    registerIpc();
    startWatchers();
    if (!globalShortcut.register('Control+Shift+J', toggleSummon)) {
      console.error('summon hotkey registration failed');
    }
    globalShortcut.register('Control+Shift+O', toggleOrb);
    globalShortcut.register('Control+Shift+Space', toggleListen);
    if (process.argv.includes('--show')) toggleSummon();
    prewarm();                       // first chat of the session shouldn't pay boot cost either
    showHud('At your service, Sir.', { speak: true, holdMs: 5000 });
  });
  app.on('will-quit', () => globalShortcut.unregisterAll());
  app.on('window-all-closed', (e) => e.preventDefault()); // tray app: never quit on window close
}
