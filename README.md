# Jarvis

<p align="center"><img src="docs/media/hero.gif" width="820" alt="Asking Jarvis about job applications, by voice"></p>
<p align="center"><i>"How are my job applications looking?" - spoken aloud, transcribed locally, answered from the real
tracker in ~5s of model time. <b>Full trailer, sound on: <a href="docs/media/trailer.mp4">docs/media/trailer.mp4</a></b>
(arc-reactor cold open rendered frame-by-frame from the app's own UI) &#183; raw demo: <a href="docs/media/voice.mp4">voice.mp4</a></i></p>

A butler-style personal AI assistant, built as a **Claude Code agent skill** plus a set of
PowerShell automations. Every morning at 08:30 it researches my life and emails me a briefing.
The rest of the day it answers on demand: budgeting, job hunting, project status, honest coaching.

Built solo by [Aleksandrs Drozdovs](https://www.linkedin.com/in/aleksandrs-drozdovs-13b730331/),
CS & Software Engineering graduate (Maynooth University, 2026), Dublin.

## What it does, unattended, every morning

- Discovers git repos recursively and reports yesterday's commits (with hashes; every claim in a
  briefing must cite its source or say "unavailable")
- Reads my Obsidian vault for goals, budget and trackers
- Sweeps job boards (Jooble for Dublin; Adzuna for UK/other regions) for fresh roles, ranked by seniority tier
- Reads job-alert emails (LinkedIn, Indeed, gradireland, Workday) via raw IMAP, headers only
- Computes my weekly budget and savings pace
- Assembles a "Today's Focus" top-3, writes the briefing to my vault, and delivers it to me over
  **Telegram** (or email, or both - set by `debrief_delivery` in CONFIG); long briefings are chunked
- I can also text the bot `/debrief` or `/status` from my phone (a 3-min scheduled poller picks it up)
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
   |         +-- search-jobs.ps1        Jooble/Adzuna job-board APIs (raw results; tiering is in the skill)
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

## Phase 3 (scaffolded): read-only bank feed

The finance module can read real balances via Enable Banking (PSD2 AIS - this build calls only the
account-information side of the API; a payment-initiation endpoint exists on the same API and is
never referenced anywhere in this codebase, enforced by a test). The collector emits aggregates
only: masked IBAN, balance, 30-day money in/out. Auth is an RS256 JWT signed with a locally
generated key that never leaves this machine - only the public certificate is uploaded. One
certificate registration + one consent click (mine, in my own browser - the agent is not allowed to
do either) activates it; consents expire ~90 days. Off by default until then.

(First scaffolded against GoCardless Bank Account Data, same day - turned out GoCardless closed
that product to new signups in mid-2025. Rebuilt against Enable Banking within the hour.)

## Voice in, voice out

Press `Ctrl+Shift+Space` anywhere: the desktop orb turns amber and listens, auto-stops when you
stop talking (the silence gate calibrates to the room's noise floor at the start of each listen,
rather than a fixed threshold), transcribes **locally** with whisper.cpp (speech never leaves the
machine), and routes the text through the same chat pipeline as typed commands. The reply comes
back on the HUD and spoken aloud (edge-tts). Mic capture lives in the always-resident orb window
(`backgroundThrottling:false`, so it survives the orb being hidden): getUserMedia -> silence-gated
PCM -> 16 kHz WAV -> whisper-cli. One-time setup: `scripts/setup-whisper.ps1` (fetches the CLI +
base.en model into a gitignored vendor dir).

## Optional integrations (opt-in, off by default)

Ships wired but **off** until I add my own credentials - the agent is not allowed to create accounts
or hold tokens, so activation is a manual step.

**Telegram remote.** A self-only bridge (`skill/bin/telegram-bot.ps1`) to trigger a debrief or check
status from my phone, and to push application-status alerts (interview / offer / rejection, classified
from the subject line only). It talks to exactly one chat id - mine - and the remote surface is
deliberately narrow (`/debrief`, `/status`); it is not a shell. To enable:
1. `@BotFather` -> `/newbot`, message the bot once, then `telegram-bot.ps1 -StoreCredential`
2. Set `telegram: on` in CONFIG.md. Poll with `-Once` (Task Scheduler) or `-Poll` (foreground).

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
- WakeToRun "fixed" the 08:30 briefing and worked exactly once. Night two the laptop was shut
  down, not slept - no wake timer survives a shutdown. Instead of pretending, a late briefing now
  stamps itself: subject "(late 10:04)", note footer naming the cause (powered off vs asleep,
  derived from the boot time). A miss is allowed; a quiet miss is not.
- GoCardless Bank Account Data - the vendor Phase 3 was built against - turned out to have quietly
  closed to new signups a year earlier. The product page still looks alive; only a specific "new
  signups disabled" URL admits it. Rebuilt the whole read-only feed against Enable Banking the same
  day. Separately: openssl's normal stderr chatter ("writing RSA key") gets wrapped into a
  terminating PowerShell error under `$ErrorActionPreference='Stop'` for some subcommands (`rsa
  -pubout`) but not others (`genrsa`, `req -x509`, `dgst -sign`) - no obvious pattern found, so the
  code and tests simply avoid the subcommand that trips it rather than fighting PowerShell's native
  command error-wrapping further.

## Layout

- `skill/` - the Claude agent skill (installed to `~/.claude/skills/jarvis` via `install.ps1`)
- `skill/bin/` - PowerShell collectors, senders, scheduler wrapper
- `scripts/` - Task Scheduler registration
- `tests/` - assertion tests (`powershell -File tests/<name>.Tests.ps1`)

Personal memory (goals, trackers, briefings) lives in a private Obsidian vault, not in this repo.
