# Debrief procedure

Produce a debrief that opens with the answer to "what should I do today", then crisp module sections.
**Readability is a hard requirement** — ≤ ~3 lines per module; collapse no-change modules to one line.

## Steps
1. Load `JARVIS.md` (goals) and `CONFIG.md` (toggles, owner_email, projects_dir).
2. For **continuity**, read the previous 1–2 notes in `debriefs/` so you don't repeat yesterday verbatim.
3. Run each **enabled** module (CONFIG `modules:`). Local modules always run; connector modules
   (today/inbox) only if on AND reachable — else emit their "⚠️ unavailable — connect to enable" line.
4. Synthesize **Today's Focus — Top 3** across all module outputs (highest-priority actions:
   overdue weekly review, stale repos, due job follow-ups, calendar items, a finance nudge).
5. Assemble the note in the template below. **Grounding check before writing:** every fact cites a
   source (commit hash, note, tracker row); every enabled section is present.
6. Write to `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\debriefs\YYYY-MM-DD.md`. If it already
   exists, update in place and append "(re-run HH:MM)" — do not duplicate SUGGESTIONS entries (key by date).
7. Append ≤1 fresh suggestion to `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\SUGGESTIONS.md` as `### YYYY-MM-DD — <idea>` (skip if today's exists).

All vault paths below are absolute (the Bash/Read tools run from the Desktop cwd, so relative paths do not resolve).

## Module playbooks
- **📅 Today (v1.1):** Calendar read; list today's events; flag conflicts and travel gaps. If off/unreachable → "⚠️ Calendar — connect to enable".
- **📬 Inbox (v1.1):** Gmail read; sender + subject + neutral 1-line gist only; suppress sensitive (Safety 5). If off/unreachable → "⚠️ Inbox — connect to enable".
- **🚧 Projects & agents:** run `powershell -NoProfile -File C:\Users\Alex\.claude\skills\jarvis\bin\collect-activity.ps1 -SinceHours 24` via Bash; report commits (with 8-char hash), repos with no commits in >7 days (stale), and what recent Claude sessions touched (from the JSON `Transcripts` + vault SESSION_NOTES). Cite hashes.
- **💼 Job search:** read `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\JOB_SEARCH.md`; follow-ups due (date ≤ today), stale Drafting rows, next application, one LinkedIn move. THEN run the job-mail check (works headless, no connector needed):
  `powershell -NoProfile -File C:\Users\Alex\.claude\skills\jarvis\bin\check-job-mail.ps1 -SinceHours 24`
  — report job-alert emails (LinkedIn / Indeed / gradireland / Glassdoor / Workday application updates) as sender + subject lines; flag any APPLICATION STATUS email (Workday/"application update"/interview/rejection) prominently and update the tracker; flag any "Mastercard Launch" email as TOP priority. Try/observe — degrade silently on failure. If Jooble keys exist, also run ONE fresh-roles check per `references/job-hunter.md` §4 with the staleness rule.
- **🏋️ Life & discipline:** read `C:\Users\Alex\ObsidianVault\Life Roadmap 2026-2027\_INDEX.md` (phase) and the weekly-review due date; one line each on physical / mental / learning vs the charter goals; nudge if the weekly review is overdue (escalate tone if it's been overdue multiple debriefs).
- **💰 Finance:** read `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\FINANCE.md` (Snapshot + Budget per `references/finance-coach.md`); report Thailand pace (ahead/behind), weekly allowance, one nudge. If the snapshot is empty or >30 days old, ask for fresh numbers. Never a transaction.
- **💡 Suggestion:** from today's project/job activity + charter goals, one concrete idea (bias toward portfolio projects that get noticed by Dublin AI/SWE employers).

## Output template
```
Good morning, Sir. — <YYYY-MM-DD>

🎯 TODAY'S FOCUS
  1. <action>   2. <action>   3. <action>

🚧 Projects & agents  <commits (hash) since yesterday; stale repos; session activity — or "quiet">
💼 Job search         <next application / follow-ups due / one LinkedIn move — or prompt to add targets>
🏋️ Life & discipline  <phase; weekly-review status; physical/mental/learning one-liners>
💰 Finance            <goal vs current; one nudge>
💡 Suggestion         <≤1 idea>
📅 Today              <events / "connect to enable">          (when v1.1 Calendar on)
📬 Inbox              <gist / "connect to enable">            (when v1.1 Inbox on)
```
Keep it tight. On a quiet day, collapse empty modules into a single "Quiet on that front today, Sir." line.
