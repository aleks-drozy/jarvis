# Jarvis — personal assistant

Butler-style assistant for Alex. Code here; memory in the Obsidian vault at
`claude-memory/12-jarvis/`. Design: see the vault's `12-jarvis/DESIGN.md`.

## Layout
- `skill/` — the Claude skill (installed into ~/.claude/skills/jarvis via install.ps1)
- `scripts/`, `skill/bin/` — PowerShell helpers (activity collector, sender, scheduler wrapper)

## Install / update the skill
```powershell
pwsh -File install.ps1   # or: powershell -File install.ps1
```
Then in Claude Code: `/jarvis debrief`.

## Milestones
- A (v1): interactive `/jarvis` debrief from local data.
- B (v1.1): automatic 08:30 email via Gmail SMTP + Task Scheduler.
