// Jarvis dashboard renderer - reads via the preload bridge only
const $ = (id) => document.getElementById(id);

// ---- tabs ----
document.querySelectorAll('#tabs button').forEach((b) => {
  b.addEventListener('click', () => {
    document.querySelectorAll('#tabs button').forEach((x) => x.classList.remove('active'));
    document.querySelectorAll('.tab').forEach((x) => x.classList.remove('active'));
    b.classList.add('active');
    $('tab-' + b.dataset.tab).classList.add('active');
  });
});

// ---- data loads ----
function stripFrontmatter(md) { return (md || '').replace(/^---[\s\S]*?---\s*/, ''); }

async function loadToday() {
  const briefing = await window.jarvis.read('briefing');
  $('briefing').textContent = briefing ? stripFrontmatter(briefing) : 'No briefing yet today. Right-click the tray icon and choose "Debrief now".';
  try {
    const cal = await window.jarvis.calendar();
    const ul = $('calendar');
    ul.innerHTML = '';
    if (!cal || !cal.Events || cal.Events.length === 0) {
      ul.innerHTML = '<li class="dim">Clear day, Sir.</li>';
    } else {
      for (const e of cal.Events) {
        const li = document.createElement('li');
        const t = document.createElement('span'); t.className = 't';
        t.textContent = e.AllDay ? 'all day' : e.Start + (e.End ? '-' + e.End : '');
        const s = document.createElement('span'); s.textContent = e.Summary;
        li.append(t, s); ul.append(li);
      }
    }
  } catch { $('calendar').innerHTML = '<li class="dim">Calendar unavailable.</li>'; }
}

async function loadSimple(name, elId) {
  const md = await window.jarvis.read(name);
  $(elId).textContent = md ? stripFrontmatter(md) : '(empty)';
}

async function loadLive() {
  try {
    const s = await window.jarvis.liveStatus();
    $('lastRun').textContent = s.lastRun || 'never';
    const ok = $('lastRunOk');
    ok.textContent = s.lastRunOk === null ? '-' : (s.lastRunOk ? 'OK' : 'FAILED');
    ok.className = s.lastRunOk === null ? '' : (s.lastRunOk ? 'ok' : 'bad');
    $('activeSessions').textContent = s.activeSessions;
  } catch {}
  const ledger = await window.jarvis.read('ledger');
  if (ledger) {
    const open = stripFrontmatter(ledger).split('\n').filter((l) => /\|\s*open\s*\|/.test(l));
    $('ledger').textContent = open.length ? open.map((l) => '- ' + l.split('|')[1].trim() + ' (raised ' + l.split('|')[3].trim() + 'x)').join('\n') : 'Nothing open. Remarkable, Sir.';
  }
}

function refreshAll() { loadToday(); loadSimple('jobs', 'jobs'); loadSimple('finance', 'money'); loadLive(); }
window.jarvis.onRefresh(refreshAll);
refreshAll();
setInterval(loadLive, 60000);

// ---- chat ----
const log = $('chatlog');
function addMsg(cls, text) {
  const d = document.createElement('div');
  d.className = 'msg ' + cls;
  d.textContent = text;
  log.append(d);
  log.scrollTop = log.scrollHeight;
  return d;
}
$('chatform').addEventListener('submit', async (e) => {
  e.preventDefault();
  const input = $('chatinput');
  const msg = input.value.trim();
  if (!msg) return;
  input.value = '';
  addMsg('you', msg);
  const thinking = addMsg('jarvis thinking', 'thinking');
  thinking.innerHTML = '<span class="shimmer">Jarvis is on it…</span>';
  $('sendbtn').disabled = true;
  try {
    const res = await window.jarvis.chat(msg);
    thinking.remove();
    addMsg('jarvis', res.text);
    if (res.ok) {
      const file = await window.jarvis.speak(res.text.slice(0, 400));
      if (file) { const p = $('dashPlayer'); p.src = 'file:///' + String(file).replace(/\\/g, '/'); p.play().catch(() => {}); }
      refreshAll(); // he may have updated trackers
    }
  } catch (err) {
    thinking.remove();
    addMsg('jarvis', 'That errand failed, Sir: ' + err.message);
  } finally { $('sendbtn').disabled = false; }
});
