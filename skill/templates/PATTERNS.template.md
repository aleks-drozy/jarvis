# PATTERNS.md - Jarvis's semantic memory (template)

Not shipped filled-in. This file is REWRITTEN weekly by `skill/bin/consolidate-memory.ps1` (Sunday
~21:00, opt-in via config `consolidation_enabled` - see `scripts/register-consolidation.ps1`), never
hand-edited during the week. It is the DISTILLED layer above the raw episodic log
(`{{VAULT}}\debriefs\*.md`, which consolidation only ever READS, never writes): a small, durable,
cited set of facts, not a growing diary.

**Loaded next to `SOUL.md`/`TASTE.md`** on every invocation (see `SKILL.md` step 3) - it shapes what
Jarvis already knows and which suggestions it should keep making vs quietly stop making. Nothing here
can loosen a `SKILL.md` Safety rule.

A candidate rewrite is only ever installed after it passes a schema check in PowerShell (every
required header present below, every fact line cited) - a malformed agent output is rejected and the
existing file is kept untouched. See `Test-PatternsSchema` in `skill/bin/consolidate-memory.ps1`.

---

## Durable facts

Each line is one atomic, durable fact about Alex, his projects, or his habits - the kind of thing that
would otherwise have to be re-derived from scratch by re-reading weeks of debriefs. **Every line MUST
end with a citation** in the exact form `(source: <episode file(s)>)`, e.g. `(source:
debriefs/2026-08-17.md, debriefs/2026-08-20.md)`. A fact with no citation is invalid and will be
rejected by the schema gate.

When a fact changes, the line is REPLACED in place - it is never left alongside a contradicting older
line. This file should read as "what's true now," not a log of everything ever noted.

A fact with no fresh supporting evidence in the last 4 weeks is auto-flagged `(stale -- last evidenced
<date>)` by a separate, deterministic pass (`Add-StaleFactFlags`) - never by the agent's own date math,
and never auto-deleted. Only Alex removes a stale fact; consolidation only flags it.

- Example: Alex trains judo Sundays 18:00-20:00 and gym most weekdays. (source: debriefs/2026-08-17.md)

## Suggestion weights

One line per suggestion category, computed directly from `Measure-SuggestionOutcomes`'s ledger for the
trailing window: how many times a category's suggestions were raised, and what fraction were actually
acted on (`acted: true` - real evidence found in the vault or git log, not just repetition). A category
with a persistently low act-rate and a high times_raised should be RANKED LOWER, or actively suppressed,
the next time a new suggestion in that category is about to be raised (see `references/debrief.md`
step 7) - this is the restraint mechanism: Jarvis learns which of its own advice lands and talks less
about the categories that don't.

- Example: portfolio-registration: 6 raised, 0 acted (0%) - demote; stop re-raising without new
  information, per SOUL.md's value hierarchy (truth over being interesting).

## Weekly learning report

Exactly 5 lines. Plain facts about what this consolidation pass found, no narrative padding. This is
what the Sunday debrief's Week section quotes verbatim (see `references/debrief.md`).

1.
2.
3.
4.
5.
