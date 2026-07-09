# Job Hunter procedure

Legal-first: jobs come from aggregator APIs via `bin/search-jobs.ps1` — **Jooble** for Ireland
(default; key at `~/.jarvis/jooble.cred.xml`), Adzuna for UK/other countries (does NOT cover Ireland).
NEVER scrape LinkedIn/Indeed directly — ToS violation, account-ban risk (see 2026 Proxycurl lawsuit).

## 1. Find roles ("find roles / find jobs / job search")
1. Read `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\JOB_SEARCH.md` — the "Search targets" list
   holds the queries. If empty, propose defaults from the charter: "graduate software engineer",
   "junior software developer", "AI engineer", "project manager graduate" (all Where=Dublin) and confirm.
2. For each target (max 4 per session), run:
   `powershell -NoProfile -File C:\Users\Alex\.claude\skills\jarvis\bin\search-jobs.ps1 -What "<query>" -Where "Dublin"`
   (defaults: -Provider jooble -Country ie). If it throws "No key", give Alex the one-minute Jooble
   setup from the script header (register at jooble.org/api/about) and stop.
3. Dedupe against the tracker (same company+role = skip; already-seen URLs = skip).
4. Rank by fit vs the charter (SWE/AI first, then PM/adjacent; grad-friendly; Dublin/hybrid).
5. Present a shortlist, max 8: **Title — Company** | location | salary if given | posted date | link.
   One line each. End with: "Say the word and I'll prep the application for any of these, Sir."

## 2. Prep an application ("apply to #N / prep the CV for X")
1. Add a row to the tracker: Company | Role | link | today | status **Drafting**.
2. CV: hand off to the cv-adjuster app (`C:\Users\Alex\Projects\cv-adjuster`) — tell Alex the exact
   command/task to tailor his CV for this role, or draft the tailoring notes yourself.
3. Cover letter / outreach message: write to
   `C:\Users\Alex\ObsidianVault\claude-memory\12-jarvis\outreach\<company>-<role>.md`
   stamped "REVIEW - NOT SENT" (Safety 3). NEVER submit or email it yourself.
4. Alex clicks submit himself. When he says he applied, set status **Applied** + date, and set
   "Follow-up due" = applied date + 10 days.

## 3. Track from email ("check my applications / any news")
Interactive sessions only (Gmail connector). Search recent mail for application-related messages:
confirmations, rejections, interview invites, recruiter replies.
- Match to tracker rows by company name; update Status (Applied -> Interview / Rejected / Offer),
  citing the email subject + date as the source.
- Unmatched application emails: add a row (Alex may have applied outside Jarvis).
- Never quote sensitive salary/personal details into the tracker beyond status; per Safety 5.

## 4. Debrief line (job module)
- Read the tracker: due follow-ups (due date <= today), stale Drafting rows, next action.
- If Adzuna keys exist: run ONE search for the top target with -MaxDaysOld 2 -ResultsPerPage 5 and
  mention up to 3 fresh roles by title+company. Wrap in try/observe — degrade silently to
  tracker-only if the API/network fails (never block the debrief).
