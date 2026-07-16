# Contributing

Thanks for looking. Jarvis is a single-maintainer personal project; contributions
are welcome, but the bar for merging is deliberately high.

## Running the tests

Plain-assertion PowerShell scripts, no framework dependency:

    powershell -File tests/<name>.Tests.ps1

Run them all:

    Get-ChildItem tests/*.Tests.ps1 | ForEach-Object { powershell -File $_.FullName }

Plus one Node-based test for the app's live-state module:

    node tests/livestate.node.js

A failing test exits non-zero and prints what broke.

## Full local setup

You need your own copies of everything personal. Never the maintainer's:

- Your own Obsidian vault (the memory layer; paths are configured, not
  hard-coded, and a guard test enforces that)
- Your own Telegram bot (via @BotFather) if you want the phone remote
- Your own Gmail app password if you want email delivery
- Optional: your own Jooble/Adzuna API keys and Enable Banking registration

Credentials are stored DPAPI-encrypted under `~/.jarvis/` by each script's
`-StoreCredential` flow. Nothing personal belongs in the repo.

## Pull requests

- Small, focused PRs: one concern per PR.
- Big features: open an issue and discuss first. This is a single-maintainer
  project with an adversarial-review merge gate; unsolicited large diffs will
  likely stall.
- Tests are required for logic changes. TDD is the house style: write the
  failing test first.
- PowerShell files must stay pure ASCII. PowerShell 5.1 reads `.ps1` files as
  ANSI; a single em dash in a string once broke the whole parser. A byte-scan
  test enforces this.
- No hardcoded personal paths or emails (`tests/no-personal-values.Tests.ps1`
  guards this).
- The safety rules in `skill/SKILL.md` are the point of the project. A PR that
  weakens a self-only lock, the draft-never-send rule, or the read-only money
  boundary will be rejected unless the change is explicitly discussed and
  justified up front.

## Security issues

Do not open a public issue. Use the private channel described in
[SECURITY.md](SECURITY.md).
