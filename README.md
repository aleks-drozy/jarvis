# Jarvis

<p align="center"><img src="docs/media/hero.gif" width="820" alt="Asking Jarvis about job applications, by voice"></p>
<p align="center"><i>"How are my job applications looking?" - spoken aloud, transcribed locally, answered from the real
tracker in ~5s of model time. <b>Full trailer, sound on: <a href="docs/media/trailer.mp4">docs/media/trailer.mp4</a></b>
(arc-reactor cold open rendered frame-by-frame from the app's own UI) &#183; raw demo: <a href="docs/media/voice.mp4">voice.mp4</a></i></p>

A butler-style personal AI assistant, built as a **Claude Code agent skill** plus a set of
PowerShell automations. Every morning at 08:30 it researches my life and sends me a briefing on
Telegram. The rest of the day it answers on demand, at the desk or from my phone: budgeting, job
hunting, interview prep, project status, honest coaching.

Built solo by [Aleksandrs Drozdovs](https://www.linkedin.com/in/aleksandrs-drozdovs-13b730331/),
CS & Software Engineering graduate (Maynooth University, 2026), Dublin.

## Run it yourself

Jarvis is built for one person per install - it reads YOUR vault, emails only YOU, and answers to
your charter. Nothing in this repo carries my paths or my email (a guard test enforces it); the
installer writes your own into `~/.jarvis/config.json` and renders the skill against them.

**Requirements:** Windows 10/11, Windows PowerShell 5.1 (preinstalled), Node.js, git,
[Claude Code](https://claude.com/claude-code) with a subscription (`claude setup-token` for the
headless morning run), and ~8GB RAM (the reference machine is a 7.4GB laptop - heavy always-on
processes are deliberately avoided).

```powershell
git clone https://github.com/aleks-drozy/jarvis && cd jarvis
powershell -File install.ps1 -InitVault      # prompts for your paths + email, seeds a starter vault
powershell -File scripts/register-task.ps1   # the 08:30 briefing (optional)
```

Then talk to him: `/jarvis debrief` in Claude Code. Everything else is opt-in, each with its own
one-time setup, all credentials DPAPI-encrypted outside the repo (see `DEPENDENCIES.md` for exactly
what data flows where): Gmail app password (inbox module + email delivery), a secret iCal URL
(calendar), Jooble/Adzuna keys (job boards), a Telegram bot (`telegram-bot.ps1 -StoreCredential` +
`scripts/register-telegram-poller.ps1`), Enable Banking (`setup-bank.ps1`, read-only), whisper.cpp
(`scripts/setup-whisper.ps1`) + `pip install edge-tts` (voice), and the desktop app (`cd app && npm
install && npm start`). Each module degrades gracefully when unconfigured - the briefing simply says
what is not connected. Personalize the voice by copying `skill/templates/SOUL.template.md` (and
TASTE) into your vault: a fork should sound like its owner, not like me.

**Model/cost note:** the desktop chat deliberately runs a fast model (sonnet); the daily briefing
uses your Claude Code default. One briefing plus casual chat fits comfortably inside a normal Claude
subscription; there is no metering built in. Claude Code's headless behavior can change between
versions (it has once - see battle scars); the briefing logs `claude --version` on every run so a
broken morning is diagnosable.

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
claude -p (agent skill) --> writes briefing --> delivery (CONFIG debrief_delivery, self-only)
   |         |                                    |-- telegram-bot.ps1 -> Telegram -> my phone (chunked)
   |         |                                    +-- send-debrief.ps1  -> Gmail SMTP -> my inbox
   |         |
   |         +-- collect-activity.ps1   git discovery + commits + session activity (JSON)
   |         +-- search-jobs.ps1        Jooble/Adzuna job-board APIs (raw results; tiering is in the skill)
   |         +-- check-job-mail.ps1     raw IMAP job-alert reader (headers only) + status classification
   |         +-- get-bank-data.ps1      Enable Banking read-only aggregates
   |
   +-- skill/SKILL.md                   personality, intents, HARD safety rules
   +-- skill/references/*.md            debrief, job-hunter, interview-prep, finance-coach, fitness-log

Windows Task Scheduler (every 3 min)
        |
telegram-bot.ps1 -Once --> /debrief · /status · "note <text>" · /notes
        (one chat id only; a closed command whitelist, not a shell)
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

## Telegram (where the briefing actually lands)

The 08:30 briefing is delivered to my phone over Telegram (`debrief_delivery: telegram | email | both`
in CONFIG; long briefings are chunked rather than truncated). A scheduled poller runs
`telegram-bot.ps1 -Once` every 3 minutes so I can also talk back:

- `/debrief` - generate and send a fresh briefing now
- `/status` - scheduler health, bank feed, whether today's briefing was written
- `note <text>` (or `idea` / `remember` / `todo`) - jot something down when I'm out; it lands
  timestamped in the vault and the next morning's briefing surfaces it for triage
- `/notes` - read recent captures back

**The design constraint that matters:** it talks to exactly one chat id (mine, enforced in code before
the network call), and the remote surface is a **closed whitelist, not a shell**. Unknown text gets the
help reply, never execution. A texted note is stored as data via `Add-Content`; `note delete everything`
saves the string "delete everything" and does nothing else.

Setup for a clone: `@BotFather` -> `/newbot`, message the bot once, `telegram-bot.ps1 -StoreCredential`
(it refuses to bind an owner if more than one chat id has messaged the bot), set `telegram: on`, then
`scripts/register-telegram-poller.ps1`.

## Stack

Claude Code (agent skill + headless `claude -p` with a long-lived token), Windows PowerShell 5.1,
Windows Task Scheduler, Telegram Bot API (self-only remote), Gmail SMTP/IMAP, Enable Banking (PSD2,
read-only), Jooble + Adzuna REST APIs, whisper.cpp (local STT), edge-tts (neural voice out), Electron
(tray orb + HUD), Obsidian (markdown vault) as the memory layer. Plain-assertion test scripts in
`tests/` (no framework dependency).

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
- **The worst one so far: I wrote a command injection into my own assistant.** Jarvis classifies
  job-alert emails and pushes interview/rejection news to my phone. The push was built by
  interpolating the email's *subject line* into a command string. An email subject is written by
  whoever emails you, and both bash and PowerShell evaluate `$( )` inside a double-quoted argument.
  A stranger could have emailed me a subject containing a command and my own machine would have run
  it at 08:30, with no click from me. Every test passed; the feature worked perfectly. It was caught
  by a review pass whose only job is to attack the diff, not by the tests. The rule it cost me:
  **never build a command line out of data.** The push text is now composed inside the script, where
  the subject is a variable and never a token a shell can parse.
- A wake word built on a vendor's "free tier" that the vendor had discontinued two weeks earlier.
  The signup page still exists; it just quietly wants a company email and a card now. Rather than pay
  for a hobby feature or bolt on a heavier engine, the wake word was deleted the same day it shipped.
  A free tier is a policy, not a guarantee - verify it is still alive at build time, not at research time.
- GoCardless Bank Account Data - the vendor Phase 3 was built against - turned out to have quietly
  closed to new signups a year earlier. The product page still looks alive; only a specific "new
  signups disabled" URL admits it. Rebuilt the whole read-only feed against Enable Banking the same
  day. Separately: openssl's normal stderr chatter ("writing RSA key") gets wrapped into a
  terminating PowerShell error under `$ErrorActionPreference='Stop'` for some subcommands (`rsa
  -pubout`) but not others (`genrsa`, `req -x509`, `dgst -sign`) - no obvious pattern found, so the
  code and tests simply avoid the subcommand that trips it rather than fighting PowerShell's native
  command error-wrapping further.

## Layout

- `skill/` - the Claude agent skill; `install.ps1` renders `{{VAULT}}`-style placeholders with your
  configured paths and mirrors it to `~/.claude/skills/jarvis`
- `skill/bin/` - PowerShell collectors, senders, the scheduler wrapper (all read `~/.jarvis/config.json`)
- `skill/templates/` - SOUL/TASTE identity templates to copy into your vault and make yours
- `app/` - the Electron companion (tray, Orb, Summon HUD, dashboard)
- `scripts/` - Task Scheduler registration + one-time setup helpers
- `tests/` - plain-assertion tests (`powershell -File tests/<name>.Tests.ps1`), run by CI on every push;
  includes a guard test that fails the build if a personal path or email ever lands in tracked source

Personal memory (goals, trackers, briefings) lives in a private vault OUTSIDE this repo, and secrets
live DPAPI-encrypted in `~/.jarvis/` - neither is ever committed. See `SECURITY.md` for reporting,
`CONTRIBUTING.md` before opening a PR, `DEPENDENCIES.md` for what each integration can see.

## Versioning & maturity

Semantic versioning from **v3.0.0** (this repo tagged v2.0 before adopting semver; v3 is the
config-file breaking change). Feature maturity is tiered honestly: **battle-tested** (morning
briefing, job-mail classification, Telegram bridge, the safety locks - all have survived real
incidents documented above) / **works, lightly used** (bank feed, fitness log, interview prep,
voice) / **experimental** (proactivity gate, Sunday retrospective - instruction-level, tuned by use).
