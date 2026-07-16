# Security Policy

## Supported versions

Jarvis is a rolling-release personal project. Only the latest commit on `master`
is supported. There are no versioned releases and no backported fixes.

## Reporting a vulnerability

Report privately through GitHub Security Advisories: open the **Security** tab on
github.com/aleks-drozy/jarvis and click **"Report a vulnerability"**.

Do NOT open a public issue for security problems.

You will get an acknowledgment within 48 hours. This is a single-maintainer
project, so fixes land as fast as one person can verify and ship them; you will
be kept informed in the advisory thread.

## Scope

All of the following are in scope:

- **Credential handling.** Everything DPAPI-encrypted under `~/.jarvis/` (Gmail
  app password, Telegram bot token, job-API keys, Claude OAuth token, bank
  signing key). Any path that could leak a credential into the repo, logs,
  notes, or model output.
- **The self-only locks.** The hard-coded email recipient and the Telegram
  chat-id lock. Any way to make Jarvis send anything to anyone other than its
  owner is a serious finding.
- **The Telegram command whitelist** (`/debrief`, `/status`, `note`, `/notes`).
  Any way to turn a texted message into code execution or an action outside the
  whitelist.
- **Electron IPC** in the desktop app (`app/`): renderer-to-main escalation,
  overexposed preload surface, navigation escapes.
- **The read-only bank boundary.** Any route from this codebase to a
  payment-initiation call would be a critical finding (a test currently asserts
  the endpoint is never referenced).

## Prompt injection: in scope, and especially welcome

Jarvis ingests untrusted content by design: email subject lines, job-listing
titles and descriptions, calendar entries. All of it flows into an LLM prompt.
If you can craft an email subject or a job posting that makes the agent break a
safety rule (contact a third party, exfiltrate data, run a command), that is
exactly the class of bug this project most wants reported. Use the same private
channel above.
