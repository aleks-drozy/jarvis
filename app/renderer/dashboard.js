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

// generic markdown-table extractor: [{header:[...], rows:[[cells]]}]
function mdTables(md) {
  const tables = [];
  const lines = (md || '').split('\n');
  for (let i = 0; i < lines.length - 1; i++) {
    if (/^\s*\|/.test(lines[i]) && /^\s*\|[\s\-|]+\|\s*$/.test(lines[i + 1])) {
      const parse = (l) => l.split('|').slice(1, -1).map((c) => c.trim());
      const header = parse(lines[i]);
      const rows = [];
      let j = i + 2;
      while (j < lines.length && /^\s*\|/.test(lines[j])) { rows.push(parse(lines[j])); j++; }
      tables.push({ header, rows });
      i = j;
    }
  }
  return tables;
}

async function loadMoney() {
  const md = stripFrontmatter(await window.jarvis.read('finance'));
  const el = $('money');
  const tables = mdTables(md);
  const kv = [];
  for (const t of tables) {
    for (const r of t.rows) {
      const [item, amount] = r;
      if (!item || !amount || amount.startsWith('(')) continue;
      const isBig = /weekly allowance/i.test(item);
      kv.push({ k: item.replace(/\*/g, ''), v: amount.replace(/\*/g, ''), big: isBig });
    }
  }
  if (!kv.length) { el.textContent = 'No numbers yet. Tell Jarvis your balance in Chat.'; return; }
  kv.sort((a, b) => (b.big ? 1 : 0) - (a.big ? 1 : 0));
  el.innerHTML = '<ul class="kv">' + kv.map((x) =>
    `<li><span>${x.k}</span><b class="${x.big ? 'big' : ''}">${x.v}</b></li>`).join('') + '</ul>';
}

async function loadJobs() {
  const md = stripFrontmatter(await window.jarvis.read('jobs'));
  const el = $('jobs');
  const apps = mdTables(md).find((t) => /company/i.test(t.header[0] || ''));
  const items = [];
  if (apps) {
    for (const r of apps.rows) {
      const [co, role, , applied, status, followup] = r;
      if (!co || co.replace(/[~\s]/g, '') === '') continue;
      const st = (status || '').replace(/[*✅⏰~]/g, '').trim();
      const cls = /applied/i.test(st) ? 'applied' : /draft/i.test(st) ? 'drafting' : /closed|reject|skip/i.test(st) ? 'closed' : '';
      const meta = [applied && applied !== '—' ? 'applied ' + applied : '', followup && followup !== '—' ? 'follow-up ' + followup.replace(/[*⏰]/g, '').trim() : '']
        .filter(Boolean).join(' · ');
      items.push(`<li><span class="co">${co.replace(/~~/g, '')}</span> — ${role.replace(/~~/g, '')}` +
        `<span class="st ${cls}">${st.split('(')[0].trim()}</span>` +
        (meta ? `<div class="meta">${meta}</div>` : '') + '</li>');
    }
  }
  el.innerHTML = items.length
    ? '<ul class="joblist">' + items.join('') + '</ul>'
    : 'No applications tracked yet, Sir.';
}

async function loadLive() {
  try {
    const s = await window.jarvis.liveStatus();
    if (s.lastRun) {
      const d = new Date(s.lastRun);
      const today = new Date().toDateString() === d.toDateString();
      $('lastRun').textContent = isNaN(d) ? s.lastRun
        : (today ? 'today ' : d.toLocaleDateString('en-IE', { day: 'numeric', month: 'short' }) + ' ')
          + d.toLocaleTimeString('en-IE', { hour: '2-digit', minute: '2-digit' });
    } else $('lastRun').textContent = 'never';
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

function refreshAll() { loadToday(); loadJobs(); loadMoney(); loadLive(); }
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
