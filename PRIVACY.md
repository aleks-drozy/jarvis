# Privacy Notice

Jarvis is a personal automation project built, run, and used by a single individual — its author,
Aleksandrs Drozdovs. It is not offered as a service to any other person or organization, and no
other person's data is ever processed by it.

## What data this project touches

- **Bank data (Phase 3, read-only):** with the owner's own consent via Enable Banking (PSD2 AIS —
  account-information only; this project never calls a payment-initiation endpoint), the collector
  reads the owner's own account balance and transaction history. Only **aggregates** are ever
  written to disk or used downstream: a masked IBAN (last 4 digits), account balance, and a 30-day
  money-in/money-out/net total. **Raw transaction line items are never stored, logged, or emailed.**
- **Email/Calendar (read-only, when enabled):** the debrief module reads sender + subject + a
  neutral one-line gist of recent messages, never full message bodies; sensitive categories
  (financial/medical/legal/2FA) are suppressed to a count only.
- **Git activity:** commit history from the owner's own local repositories.

## Where data is stored

Everything lives **locally, on the owner's own machine only.** Credentials (API keys, private keys,
app passwords) are DPAPI-encrypted at rest, tied to that machine's Windows user account, and are
never committed to this repository or any cloud service. Daily briefing notes are written to a
local, private note vault — never synced to a public or third-party location.

## Sharing

Nothing collected by this project is sold, shared, or transmitted to any third party beyond the
minimum API calls required to fetch the owner's own data from the services he has explicitly
authorized (e.g. Enable Banking, Gmail, Google Calendar).

## Contact

Aleksandrs Drozdovs — aleksandrs.drozdovs2005@gmail.com
