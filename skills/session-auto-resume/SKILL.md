---
name: session-auto-resume
description: Use at session start (loaded via SessionStart hook) to arm the usage-limit auto-resume timer, and whenever a prompt beginning with "[session-auto-resume timer]" fires.
---

# Session Auto-Resume

**Type:** internal skill

Keeps long-running work moving when a session hits the account's 5-hour usage
limit. A one-shot in-session cron job is armed at the moment the current limit
window resets (+ a small buffer). Limit-paused sessions sit idle, cron jobs
fire while the REPL is idle, so the timer lands right after the reset and
continues whatever was interrupted. Each firing re-arms the next window's
timer, so coverage is continuous for as long as the session stays open.

The reset timestamp comes from `~/.claude/state/rate-limit-resets.json`,
which is continuously refreshed by the statusline script
(`~/.claude/scripts/statusline-limit-tracker.sh`) from any active session —
limits are account-wide, so any session's data is valid for all.

## Procedure: Arming (at session start)

Do this silently before or immediately after handling the first user message.
Do not narrate it beyond a brief mention if it fits naturally.

1. **Duplicate check:** Call `CronList`. If any job's prompt contains
   `[session-auto-resume timer]`, STOP — already armed. (The SessionStart
   hook re-fires on resume/clear/compact; this check makes re-arming a no-op.)

2. **Compute the fire time** (reset + 4-minute buffer; falls back to
   now + 5h04m when the state file is missing, stale, or already past):

   ```bash
   RESET=$(jq -r '.rate_limits.five_hour.resets_at // 0' ~/.claude/state/rate-limit-resets.json 2>/dev/null)
   NOW=$(date +%s)
   if [ "${RESET:-0}" -gt "$NOW" ]; then FIRE=$((RESET + 240)); else FIRE=$((NOW + 18240)); fi
   date -r "$FIRE" "+%M %H %d %m"
   ```

3. **Arm the one-shot:** Call `CronCreate` with `recurring: false`, cron set
   to the four fields from step 2 plus `*` for day-of-week (`"M H D M *"`),
   and exactly this prompt:

   > [session-auto-resume timer] Invoke the Skill tool with
   > skill=session-auto-resume and follow its "When the timer fires"
   > procedure.

## Procedure: When the timer fires

Order matters — re-arm before resuming, so that resumed work which burns
through the *next* window too still has a live timer behind it.

1. **Re-arm first:** Run the Arming procedure above (the just-fired one-shot
   has auto-deleted, so the duplicate check will pass). The state file now
   holds the next window's reset time.

2. **Then decide whether anything needs resuming.** Resume only work that
   was interrupted mid-execution — a turn cut off by a usage-limit /
   rate-limit error, or a task left visibly half-done with no user
   interaction since. If you resume, see the task through to completion.

3. **Otherwise reply with exactly `⏳` and nothing else.** No summary, no
   status report. Cases that are NOT unfinished work:
   - the user already resumed the task manually (it's done or progressing)
   - the user deliberately stopped, cancelled, or redirected the work
   - the last exchange was conversational or completed normally
   - you are unsure whether the user wanted the work continued — an
     unwanted zombie resume is worse than a missed one

## Limitations (known and accepted)

- Only protects sessions whose terminal/REPL stays open. A closed terminal
  needs manual `claude --resume`.
- A one-shot that fires while the account is still limited (e.g. the weekly
  7-day cap is also exhausted) fails without retry — the chain breaks for
  that session. The 4-minute buffer makes clock-skew breaks rare, but the
  7-day cap is a genuine gap.
- In-session cron jobs expire after 7 days.
- Each ⏳ no-op costs one full-context turn in that session (~5h apart).
