# Incident: six days of silent debrief failures (2026-08-09 to 2026-08-15)

**Status:** resolved. **Duration:** 6 days, 10 failed runs (08:30 + 09:15 catch-up, daily).
**User impact:** no morning briefing delivered, six days running. **Root cause:** external
(an organization-level policy flag disabled Claude Code subscription access). **What actually
shipped as a result:** a code-only, no-LLM consecutive-failure alert that does not share fate with
the failure it reports on.

This is the second multi-day debrief outage this project has had (the first, 2026-07-28, is a
different failure class - three internal bugs, written up in this repo's own `DECISIONS.md`
history). This one is worth publishing separately because the interesting finding is not a code
bug at all: it's what "fail-closed" actually bought, and what it didn't.

## What happened

Every morning from 08-09 through 08-15, the scheduled 08:30 run (and the 09:15 hibernation
catch-up added after the July outage) invoked the `claude` CLI headlessly and got the same error
back: an `api_error_status` of `403`, from an organization-level policy toggle ("Claude
subscription access for Claude Code") that had been switched off upstream of this machine
entirely. Nothing in this repo caused it, and nothing in this repo could have prevented it - it
sat outside the trust boundary this project controls.

Ten consecutive runs, ten identical 403s. No debrief reached Alex's phone for six days.

## The part that worked

This is the part worth saying plainly, because "fail-closed" is easy to claim and hard to verify
without a real failure to test it against.

Every one of those ten failed runs logged a real `run FAILED` line to
`debriefs/.jarvis-runs.log` - the run-status file the wrapper script (`jarvis-debrief.ps1`), and
only the wrapper script, is allowed to write (see `SKILL.md` Safety rule 8; the agent is
structurally forbidden from writing a success line for a run it didn't complete). Nothing was
fabricated as a success. Nothing silently degraded to "probably fine." The system did the one
thing a fail-closed design is supposed to do under a failure nobody anticipated: it recorded the
failure, honestly, every single time, and never pretended otherwise.

That property was not free. It was built the hard way, after the *previous* outage (2026-07-28)
found the opposite defect - the debrief's own subagent had been forging "run ok" lines into that
same log, which is exactly why the wrapper now owns that file exclusively and the agent is told,
in writing, never to touch it. This incident is the first time that fix got tested against a real,
unplanned, multi-day failure, and it held.

## The part that didn't: alerting shared fate with the failure

Here is the gap. As of 2026-08-09, the *only* way any of this became visible to Alex was the next
morning's debrief itself reporting "Health: the last run failed" - which requires a debrief to
*succeed* in order to report that the *previous* debrief failed. When every run is failing for the
same external reason, that mechanism never fires. The failure-reporting channel was downstream of
the exact thing that was broken. Six days of correctly-logged, honestly-recorded failures produced
zero pushes to Alex's phone, because the only messenger available was the same messenger that
kept getting turned away at the door.

This is a distinct failure mode from July's: that outage was a bug in the system doing the work.
This one is a *design* gap - a working, honest fail-closed system with no independent channel to
say "I have been failing for six days" out loud.

## The fix: an alert that cannot inherit the failure it reports

The shipped fix (`Send-FailureAlert` in `skill/bin/jarvis-debrief.ps1`) is deliberately narrow and
deliberately dumb:

- It is a **fixed, code-composed string** - never LLM output, never a Claude invocation of any
  kind. The alert cannot 403 the same way the debrief did, because it doesn't call anything the
  debrief calls.
- It fires on **2+ consecutive `run FAILED` lines** in the wrapper's own log (the same log this
  incident proved trustworthy), read by plain PowerShell, not by an agent.
- It pushes over **both existing self-only senders independently** - Telegram and email - so one
  channel being down doesn't silence the other.
- It **dedupes same-day**, so the 08:30 run and the 09:15 catch-up don't double-alert on the same
  underlying failure.
- Safety rules 2 and 8 are both preserved by construction: the send targets are locked in code
  (self-only), and the agent is never in this code path at all - there is nothing for it to forge.

What was explicitly **not** done, and why:

- **No auto-retry.** The incident data itself argues against it: 08:30 and 09:15 failed
  identically for five straight days. A 403 from a disabled org policy is not transient - retrying
  it just delays a human noticing, which is the opposite of the fix.
- **No automatic fallback to API-key auth.** Silently switching from flat subscription billing to
  metered per-token billing, with no human in the loop, is not a decision this code should make
  for Alex. If this recurs, that's a deliberate call he makes, not a fallback path baked in.

## Two things this incident left unexplained, stated honestly

Not every question this outage raised got answered, and pretending otherwise would be exactly the
kind of "quiet confident wrong" this project keeps refusing to ship elsewhere. Two gaps, open as of
this writing:

1. **2026-08-13 has no `.jarvis-runs.log` entries at all** - not a failure line, not anything.
   Neither trigger appears to have run, or logged, anything that day. The Windows Task Scheduler
   diagnostic log was disabled at the time (it logs scheduler-side trigger/run events
   independently of anything this repo writes), so there is no corroborating evidence either way.
   Enabling it (`wevtutil sl "Microsoft-Windows-TaskScheduler/Operational" /e:true`, needs
   elevation) is a known follow-up, not yet done.
2. **2026-08-16 09:26:25 has a "run start" with no terminal "run ok" / "run FAILED" line** before
   the log resumes cleanly the next day. An un-terminated run record, cause unknown.

Neither has recurred since. Both are recorded here rather than smoothed over, and revisited if
either happens again.

## What this incident is evidence of, and what it isn't

It is evidence that a fail-closed design, once actually pressure-tested by a real six-day outage
instead of a unit test, recorded every single failure honestly and fabricated nothing - the exact
property it was built for. It is not evidence that the system is now fully self-monitoring: it
took a human noticing six missing mornings, on top of the alert this incident produced, for the
gap to surface at all. The alert closes the specific hole this outage found. It does not claim to
close every hole a *different* outage might find next.

See also: `evals/scenarios/silence/` for the flagship eval this project runs alongside its
deterministic suites - proving the model stays *quiet* on a genuinely uneventful day is the
positive-space twin of this incident's negative-space lesson (an assistant that goes silent when
it has nothing to say, and one that goes silent when something is wrong, must never look the same
from the outside; this incident is the reason the alert exists at all).
