# Dependencies and External Integrations

Every external service Jarvis talks to, what flows through it, where its
credential lives, and what its license or terms mean for this MIT-licensed repo.
All credentials are DPAPI-encrypted under `~/.jarvis/`, tied to the local
Windows user account, and never committed.

| Integration | Used for | Data through it | Credential | License/ToS status | Swap-out path |
|---|---|---|---|---|---|
| Claude Code | Agent runtime (headless `claude -p`) | Briefing context, prompts | Long-lived OAuth token | Anthropic terms; behavior may shift across Claude Code versions | Any runtime that can execute the skill |
| Gmail SMTP/IMAP | Briefing delivery, job-alert reading | Outbound briefings (self-only), inbound headers only | App password | Standard Gmail ToS | Any SMTP/IMAP provider |
| Enable Banking | Read-only bank feed (PSD2 AIS) | Balance, 30-day in/out/net aggregates | RS256 private key + app config | Client code original; EB sample code is Apache-2.0 (MIT-compatible) | Another PSD2 AIS provider |
| Telegram Bot API | Phone remote, status alerts | Briefings, status, notes (one chat id) | Bot token | Telegram permits publishing bot code under any license | Email delivery (`debrief_delivery`) |
| whisper.cpp | Local speech-to-text | Mic audio, never leaves the machine | None | MIT, unrestricted; fetched, not redistributed | Any local STT CLI |
| edge-tts | Spoken replies | Reply text to a Microsoft endpoint | None | GPL-3.0, external process (aggregation, not linking) | Azure Speech API (official) |
| Jooble API | Ireland job search | Search queries, job listings | Free API key | Terms silent on publishing integration code | Adzuna or another job API |
| Adzuna API | UK/other job search | Search queries, job listings | Free app id + key | Commercial use limited to a 14-day trial; personal use assumed | Jooble or another job API |

## Claude Code

The runtime everything else hangs off: the skill runs via headless `claude -p`
with a long-lived token stored DPAPI-encrypted. Claude Code's behavior can
change between versions, so a briefing that worked yesterday can degrade after
an update; pin your version if that matters to you.

## Gmail SMTP/IMAP

SMTP delivers the briefing; IMAP reads job-alert emails (headers only, never
bodies). The send path has a self-only lock: the recipient is effectively
hard-coded to the owner's address. Auth is a Gmail app password. Any standard
SMTP/IMAP provider would work with minor script changes.

## Enable Banking (PSD2 AIS)

Read-only account information only. The collector emits aggregates: masked
IBAN, balance, and 30-day money in/out/net. Raw transaction lines are never
stored. A test enforces that the payment-initiation endpoint (which exists on
the same API) is never referenced anywhere in this codebase. The client code
here is original; Enable Banking's own published sample code is Apache-2.0,
which is compatible with this repo's MIT license. Swap-out: any PSD2 AIS
provider (this module was first built against GoCardless Bank Account Data,
which closed to new signups).

## Telegram Bot API

The phone remote and alert channel. Telegram explicitly permits publishing bot
integration code under any license, so the MIT bot script is unproblematic. A
self-only chat-id lock is enforced in code: the bot talks to exactly one chat
id, the owner's, and the command surface is a short whitelist. Swap-out: set
`debrief_delivery` to email and skip Telegram entirely.

## whisper.cpp

Local speech-to-text. MIT, unrestricted. It is not vendored in this repo:
`scripts/setup-whisper.ps1` fetches the CLI and model into a gitignored vendor
directory, so this repo redistributes nothing. Speech audio never leaves the
machine.

## edge-tts

NOT bundled. Jarvis invokes it as an external, user-installed Python package
via subprocess (`python -m edge_tts`). edge-tts itself is GPL-3.0 and is an
unofficial wrapper around a Microsoft endpoint. Because it runs as a separate
process and is separately installed, this is aggregation, not linking, and does
not affect this repo's MIT license; but you should know its status before
relying on it. The documented alternative is Azure's official Speech API with
your own subscription.

## Jooble API

Ireland job search. Free API key. Jooble's terms are silent on publishing
integration code: no known restriction, but no explicit permission either. A
clarifying inquiry to Jooble is reasonable before any heavy redistribution of
this integration.

## Adzuna API

UK and other-region job search. IMPORTANT: Adzuna restricts commercial use to a
14-day trial. Hobby/personal use of a free key is the working assumption here.
Anyone building a commercial product on the Adzuna integration needs their own
agreement with Adzuna.

---

Spotted a licensing or ToS edge case not covered here? Reports are welcome:
open an issue (or use the SECURITY.md channel if it is sensitive).
