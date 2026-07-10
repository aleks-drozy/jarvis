# Jarvis

<!-- Demo media: capture per docs/SHOTLIST.md into docs/media/, then uncomment.
<p align="center"><img src="docs/media/hero.gif" width="820" alt="Summoning Jarvis (Ctrl+Shift+J)"></p>
<p align="center"><i>Ctrl+Shift+J — the Summon. Voice demo with sound: see below.</i></p>
-->

A butler-style personal AI assistant, built as a **Claude Code agent skill** plus a set of
PowerShell automations. Every morning at 08:30 it researches my life and emails me a briefing.
The rest of the day it answers on demand: budgeting, job hunting, project status, honest coaching.

Built solo by [Aleksandrs Drozdovs](https://www.linkedin.com/in/aleksandrsdrozdovs/),
CS & Software Engineering graduate (Maynooth University, 2026), Dublin.

## What it does, unattended, every morning

- Discovers git repos recursively and reports yesterday's commits (with hashes; every claim in a
  briefing must cite its source or say "unavailable")
- Reads my Obsidian vault for goals, budget and trackers
- Sweeps job boards (Jooble/Adzuna APIs) for fresh Dublin roles, filtered by seniority tier
- Reads job-alert emails (LinkedIn, Indeed, gradireland, Workday) via raw IMAP, headers only
- Computes my weekly budget and savings pace
- Assembles a "Today's Focus" top-3, writes the briefing to my vault, and emails it to me
- If anything fails, it alarms loudly; a silent crash is not allowed to impersonate a quiet day

## Architecture

```
Windows Task Scheduler (08:30, catch-up if PC was off)
        |
jarvis-debrief.ps1 ------- headless run guard: note must be FRESHLY written or no send
        |                                   |
claude -p (agent skill) --> writes briefing --> send-debrief.ps1 --> Gmail SMTP --> my inbox
   |         |                                                          (UTF-8, self-only)
   |         +-- collect-activity.ps1   git discovery + commits + session activity (JSON)
   |         +-- search-jobs.ps1        Jooble/Adzuna job APIs, seniority-tiered
   |         +-- check-job-mail.ps1     raw IMAP job-alert reader (headers only)
   |
   +-- skill/SKILL.md                   personality, intents, HARD safety rules
   +-- skill/references/*.md            debrief procedure, job-hunter, finance-coach playbooks
```

## Trust engineering (the part I care most about)

Agents that act unattended need rules they cannot talk themselves out of:

- **Money:** can never initiate a transfer, payment, trade or purchase. Advice only.
- **Email:** can only email me. The recipient is effectively hard-coded; job applications and
  outreach are drafted to files stamped "REVIEW - NOT SENT" for me to send myself.
- **Secrets:** never in the repo or notes. Credentials live outside the repo, DPAPI-encrypted to
  my Windows login (Gmail app password, job-API keys, Claude OAuth token), loaded at runtime.
- **Grounding:** claims cite a commit hash, file or tracker row, or the module says "unavailable".
- **Privacy:** the inbox reader records sender + subject only, never message bodies; sensitive
  categories are suppressed.

## Voice in, voice out

Press `Ctrl+Shift+Space` anywhere: the desktop orb turns amber and listens, auto-stops after
~2s of silence, transcribes **locally** with whisper.cpp (speech never leaves the machine),
and routes the text through the same chat pipeline as typed commands. The reply comes back on
the HUD and spoken aloud (edge-tts). Mic capture lives in the always-resident orb window:
getUserMedia -> silence-gated PCM -> 16 kHz WAV -> whisper-cli. One-time setup:
`scripts/setup-whisper.ps1` (fetches the CLI + base.en model into a gitignored vendor dir).

## Stack

Claude Code (agent skill + headless `claude -p` with a long-lived token), Windows PowerShell 5.1,
Windows Task Scheduler, Gmail SMTP/IMAP, Jooble + Adzuna REST APIs, whisper.cpp (local STT),
edge-tts (neural voice out), Obsidian (markdown vault) as the memory layer. Plain-assertion test
scripts in `tests/` (no framework dependency).

## Battle scars (real bugs shipped and fixed)

- PowerShell 5.1 reads `.ps1` as ANSI: one em dash in a string broke the whole parser. Scripts are
  pure ASCII now, enforced by a byte scan.
- `ConvertTo-Json` unwraps single-element arrays: `Commits` serialized as three different shapes
  until wrapped with `@()`. Locked with a test.
- Job aggregators keep ghost listings: three fully-prepped applications turned out to be closed
  roles. The procedure now enforces a freshness rule and verify-at-source before drafting.
- A bare "Dublin" location matched Dublin, California. Locations are country-scoped now.
- The 08:30 briefing silently skipped one morning: laptop asleep at 08:30, and Task Scheduler's
  default `DisallowStartIfOnBatteries` blocked the catch-up run at wake because the machine was
  unplugged. Both battery conditions are now stripped by `scripts/register-task.ps1`.
- whisper.cpp's release zip still ships `main.exe` - as a deprecation stub that exits 1. The
  code looks only for `whisper-cli.exe`.

## Layout

- `skill/` - the Claude agent skill (installed to `~/.claude/skills/jarvis` via `install.ps1`)
- `skill/bin/` - PowerShell collectors, senders, scheduler wrapper
- `scripts/` - Task Scheduler registration
- `tests/` - assertion tests (`powershell -File tests/<name>.Tests.ps1`)

Personal memory (goals, trackers, briefings) lives in a private Obsidian vault, not in this repo.
