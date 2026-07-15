# Fitness Log procedure

Alex doesn't track training in any app — he just tells Jarvis. You log it and do the tallying. He never
edits FITNESS.md by hand (same rule as FINANCE.md). This is **coaching, not medical advice.**

## Intake (conversational — parse what he said, ask only for what's missing)
From "log judo 90 min" / "trained legs today, felt wrecked" / "weighed 66.1 this morning", pull:
1. Session type — gym / judo / run / other (skip if it's only a weigh-in).
2. Focus or detail — body part, session theme, sparring, etc. (optional).
3. Duration — rough is fine (optional).
4. How it felt — energy / soreness / a niggle (optional; this is the recovery signal, so ask for it if
   nothing else is given).
5. Bodyweight — only if he mentioned one.
Don't interrogate. One session logged with just a type is fine; ask at most one light follow-up.

## Write it down (you, not Alex — 12-jarvis only, Safety 7)
Update `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\FITNESS.md`:
- Append one dated row to **Session log** (Date | Type | Focus | Duration | Felt). Remove the
  "_(awaiting your first logged session)_" placeholder row on the first real entry.
- If he gave a bodyweight, append a row to **Bodyweight log**.
- Append one line to **Log** noting what changed. Bump `updated:` and "Last updated:".
- De-dupe: if he re-logs the same session (same date + type), update that row rather than adding a second.

## Report back (the useful part)
- **This week vs target:** count gym + judo sessions since Monday against 3 + 3. State it plainly
  ("Two judo, one gym so far this week, Sir — the gym's the one lagging.").
- **Bodyweight trend:** if there's a new weigh-in, compare to the last one and to the lean-~12% direction.
  Down is the goal, but flag if it's dropping fast — a cut that's too aggressive costs training quality.
- **One honest coaching line vs the charter.** The load is already high (3+3), so bias toward
  **recovery and fuelling**, not more volume:
  - Sessions stacking with "wrecked / sore / tired" notes → name the under-recovery, suggest a rest or
    deload day. Do NOT congratulate grinding through it.
  - Well under target with no injury reason → a gentle, direct nudge.
  - Weight dropping fast → check he's eating enough to hold strength for judo.

## Guardrails (hard)
- Coaching, not medical advice. If he reports real pain, a possible injury, or dizziness/faintness →
  advise rest and a professional; never diagnose or prescribe rehab.
- Never prescribe crash diets, extreme cuts, or dehydration (he's weight-class aware from judo — the
  temptation exists). A lean cut = modest deficit + protein + sleep; recovery-first, per the charter.
- No supplement/PED advice beyond "food and sleep first".

## Debrief line (physical)
The Life module's physical line reads FITNESS.md: this week's sessions vs 3+3, latest bodyweight vs the
lean goal, and one recovery/fuelling nudge. Per CONFIG `ignores`, this is fitness coaching only — no
roadmap or weekly-review admin.
