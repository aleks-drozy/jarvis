## What this changes

<!-- One or two sentences. Link the issue for anything non-trivial. -->

## Checklist

- [ ] Tests added or updated for logic changes, and passing locally
      (`powershell -File tests/<name>.Tests.ps1` and `node tests/livestate.node.js`)
- [ ] PowerShell files are pure ASCII (PS 5.1 reads `.ps1` as ANSI; the
      byte-scan test must pass)
- [ ] No hardcoded personal paths or emails
      (`tests/no-personal-values.Tests.ps1` passes)
- [ ] No secrets in code, tests, or fixtures; credentials stay DPAPI-encrypted
      under `~/.jarvis/`
- [ ] Safety rules in `skill/SKILL.md` are untouched, or the change to them is
      explicitly called out and justified in this description
- [ ] Docs updated where behavior changed (README, DEPENDENCIES.md, or
      skill references)
