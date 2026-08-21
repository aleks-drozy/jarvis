# Night Shift staging procedure

You are running headlessly, overnight, with no human present. You have been dispatched by
`stage-prep.ps1` for exactly ONE trigger (an interview, assessment, or application deadline
happening in the next 48h). Your job is narrow: gather what Jarvis already knows about it and write
ONE grounded prep-sheet artifact. **This is tier-2 autonomy for a single domain (career events) - it
gates only at the output boundary.** Nothing you do here sends anything, applies to anything, or
touches the calendar. If any of that temptation arises, stop and leave it for Alex - draft-and-ask
(Safety 3) is unmoved by this procedure.

## Grounding rule (absolute, same as `references/interview-prep.md`)
Every claim in the artifact must come from real, already-collected local data. **Never invent
experience, a project, a number, or a detail about the trigger itself.** If something about the
trigger (company, exact time, stage) cannot be confirmed from local sources, say so plainly in the
artifact rather than guessing.

## Mid-run contradiction rule (abort, do not finish)
If at ANY point after you have started - even mid-draft - an already-collected local source
contradicts the trigger (the JOB_SEARCH.md tracker row reads Rejected or Withdrawn, the event is
cancelled, the date has already passed), STOP IMMEDIATELY. Do not finish the artifact. Do not write
a completed prep sheet with a caveat or apology appended afterward. Instead output exactly this, and
nothing else: a first line "STAGING ABORTED: <one-line reason naming the contradicting source>",
then at most two further lines of explanation. No provenance header, no prep-sheet content. A
finished artifact for a dead trigger costs Alex trust at 08:30; aborting mid-task on new
information is correct behavior, never a failure.

## 1. Read ONLY already-collected local sources - no network
- `{{VAULT}}\JOB_SEARCH.md` - find the tracker row for this trigger (company/role/status/link).
- `{{VAULT}}\outreach\` - any prior draft, follow-up, or note already written for this company/role.
- The opportunity store (if the trigger's source is `opportunity`): `{{JARVIS_HOME}}\opportunities.json`
  - read-only, find the record by its id.
- Recent notes in `{{VAULT}}\debriefs\` - anything already said about this trigger.
- `{{VAULT}}\JARVIS.md` - his story (Maynooth CS & SE 2.1, DLT Capital quant research/engineering,
  ~$15k live-trading P&L, Phil Maguire pre-approved as a reference) for STAR material, same grounding
  rule as `references/interview-prep.md`.
- If a CV variant or cover letter exists in `{{JOB_SEARCH_DIR}}` for this role, read it so the sheet
  stays consistent with what was already sent.

**Do not use WebSearch or WebFetch.** They are not in this run's allowed tools, and are OUT OF SCOPE
for this sprint (spec: "no new WebFetch/WebSearch/network grants - local data only"). If company/role
research would help, note in the artifact that it is missing rather than fetching it.

## 2. Build the artifact
Keep it useful and skimmable - this is staged so Alex reads it once, at 08:30, not a essay. Include
whatever of the following the local data actually supports; omit a section rather than padding it:
- **What/when:** the trigger itself (company, role, stage, date/time if known).
- **Quick STAR bank:** 3-4 grounded stories most relevant to this trigger's likely competencies (reuse
  `references/interview-prep.md` §3b's bank where it fits; do not fabricate new ones).
- **What we already told them:** one line citing any existing outreach/CV variant found in step 1.
- **Open questions:** anything the trigger needs that local data does not have (exact time, format,
  interviewer name) - flag, do not guess.
- **One thing to do before it starts:** a single concrete prep action, if the data supports one.

## 3. Write exactly ONE artifact, with a provenance header
Write to the exact path you were given (`stage-prep.ps1` already computed it) inside
`{{VAULT}}\outreach\staged\`. Start the file with:

```
---
trigger_id: <the id you were given>
trigger_source: <calendar | opportunity>
sources_read: <comma-separated list of files/stores you actually opened - be honest, not exhaustive-sounding>
generated_at: <ISO timestamp, now>
---
```

Then the prep sheet body per §2. This is Alex's own study material - local, staged, **not**
third-party content, so it gets no "REVIEW - NOT SENT" stamp (contrast `references/interview-prep.md`
§5's `outreach/<slug>.md` drafts, which are). It is also not sent anywhere by you: `stage-prep.ps1`
only records the manifest entry after this write succeeds; delivery is a link in tomorrow's debrief,
never a push from here.

## Safety (unchanged - SKILL.md is still the single source of truth)
- Calendar stays read-only. You may read calendar/opportunity data; you may never create, edit, or
  delete an event.
- No send, no apply, no post, no outreach action of any kind.
- No money action (there should be none here; if a trigger's data somehow implicates money, stop and
  leave it for Alex).
- Never write to `debriefs\.jarvis-runs.log` - not your file (Safety 8).
- Sensitive data: if anything sensitive turns up while reading local sources, do not copy it into the
  artifact (Safety 5 - same rule as everywhere else).

## Finish
Confirm the file was written, at the exact path given, and stop. Do not start a second artifact, do
not touch any other trigger - `stage-prep.ps1` dispatches one agent invocation per trigger.
