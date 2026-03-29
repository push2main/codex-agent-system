# Self-Learning Diagnostic Report — 2026-03-29

## Question: Is the system learning efficiently? Is it measurably improving?

**Answer: No.** The system was in a complete deadlock with 0% recent success rate.

## Diagnosis

### System State Before Fixes
- All-time success rate: 14% (81/581 tasks)
- Recent success (last 50): **0%** — complete deadlock
- Trend: DETERIORATING at -4.0pp per window
- Pipeline: stale since 2026-03-25 (4 days)
- Emergency brake: ACTIVE (blocking all new task generation)
- All 3 active tasks: FAILED with `review_rejection`
- 20 zombie tasks consuming 166 wasted execution slots

### Root Cause Identified
**Overly verbose plan steps cause review_rejection.** The planner (both LLM and fallback) generated individual step instructions of 1000-2000+ characters. The coder agent cannot parse and execute such detailed instructions within its time budget, so the reviewer rejects the output.

Evidence:
- Task 002: Step 1 was ~1200 chars describing 5 sub-tasks (a-e) in one step
- Task 003: Step 1 was ~2000 chars listing 30+ test cases inline
- Task 004: Step 1 was ~800 chars with nested escape sequences

### Secondary Issues
1. **Dedup threshold too aggressive**: Rules sharing common preambles were being deduplicated at 80% similarity, suppressing distinct rules. Learning rate was only 1.38 rules/100 tasks.
2. **No pipeline recovery mechanism**: When all tasks fail and emergency brake activates, the system has no way to seed fresh simple work.
3. **Learner rules are prompt-only**: The 7 prompt-rules exist only as text guidance to the LLM, not as code-enforced gates.

## Fixes Applied

### 1. Step-level character cap (planner.sh)
- Added `MAX_STEP_CHARS=600` constant
- Post-validation now truncates each plan step to 600 chars at sentence boundaries
- **Impact**: All 3 new recovery task plans have steps under 600 chars (461-531 chars vs. 1000-2000+ before)

### 2. Dedup threshold lowered (learner.sh)
- Changed from 80% to 65% similarity threshold
- Allows more distinct rules to accumulate while still blocking true duplicates

### 3. Pipeline recovery mechanism
- Shelved all 3 failed tasks (root cause fixed, can be re-attempted later)
- Seeded 3 ultra-simple recovery tasks (single-file comment edits, basic tests)
- Pipeline immediately picked up and started executing them

### 4. Rules and documentation updated
- Added 3 new learned rules to rules.md (step cap, recovery seeding, dedup threshold)
- Updated CLAUDE.md with diagnostic findings and fix descriptions
- Updated System Health section with 2026-03-29 fixes

## Verification
- `bash -n agents/planner.sh` — PASS
- `bash -n agents/learner.sh` — PASS
- `tasks.json` valid JSON — PASS
- Pipeline status: RUNNING (executing recovery tasks)
- Step lengths in new plans: 161-531 chars (all under 600 cap)

## Expected Impact
- The step-cap fix addresses the #1 cause of recent failures (review_rejection)
- Recovery tasks should break the 0% deadlock
- Lower dedup threshold should improve learning rate from 1.38 to ~3-5 rules/100 tasks
- Success rate should recover to at least the 10-26% range seen in windows 201-500
