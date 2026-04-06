# CLAUDE.md — Project Intelligence for Claude Code
# Auto-generated from codex-memory by memory-sync.sh
# Last sync: SYNC_TIMESTAMP
#
# This file is loaded into every Claude Code session.
# Keep under 200 lines for optimal adherence.

## Core Rules

- All agents must return valid JSON with status, message, data fields
- Maximum 6 steps per plan, last step must be verification
- Never break the system — all changes must be incremental and reversible
- Queue workers execute in parallel — avoid file conflicts
- Task registry is the single source of truth for task state
- Timeout failures often caused by oversized context or missing dependencies
- Retry loops occur when the same approach is repeated without failure analysis
- Strategy saturation signals that the system is generating tasks faster than completing them
- Registry pressure above 512KB degrades dashboard read performance
- Unknown retry classification reduced from 76% to 13% — auto-reclassify at write time using combined error+reviewer+evaluator text
- Re-approving failed tasks can cause infinite retry churn — track cumulative_attempts across approval cycles
- Learner must accumulate rules over time, not overwrite with each run (max 20, deduplicated)
- Per-project registry compaction needed when one project dominates pressure
- Zombie task guard: if a task title has failed 5+ times across all attempts, shelve it permanently — do not requeue or re-approve
- Zero-step timeouts (100 of 235 timeouts) mean orchestrator planning consumes the entire budget — cap planning to 60s before first step execution

## Learned Rules

- If the same task fails twice in a row, reduce scope for the next attempt instead of retrying the same approach.
- Prioritize learning work using the most common recent failure category, not isolated incidents.
- Verify source-of-truth logic before correcting metrics or derived state.
- Skip automatic corrections when the environment cannot reliably observe complete cross-project data.
- Pause or slow rule changes when rules are changing too quickly to measure their impact reliably.

## Provider Routing

Use `claude` provider for UI tasks. Use `codex` for all other categories.
See `codex-learning/provider-routing.json` for detailed routing rules.

## Key Learnings by Topic

- **code_quality**: 52/64 success
- **dashboard**: 37/25 success | Rule: Learner priority should always target the dominant failure category from retry-failure-analysis.json
- **general**: 16/17 success | Rule: Learner priority should always target the dominant failure category from retry-failure-analysis.json
- **memory**: 5/6 success | Rule: Keep prompt changes minimal and tied to repeated evidence.; Prefer prompt rules that improve determi
- **performance**: 0/2 success | Rule: Shell scripts must pass bash -n, Python must pass ast.parse, JSON must pass json.tool. Never return 
- **planning**: 5/7 success | Rule: Learner priority should always target the dominant failure category from retry-failure-analysis.json
- **provider**: 1/2 success | Rule: In `agents/planner.sh`, reject any self-improve task whose title or failed step text exceeds 220 cha
- **queue-handling**: 0/0 success
- **queue**: 35/25 success | Rule: Keep prompt changes minimal and tied to repeated evidence.; Prefer prompt rules that improve determi
- **stability**: 35/25 success | Rule: Keep prompt changes minimal and tied to repeated evidence.; Prefer prompt rules that improve determi
- **testing**: 31/25 success | Rule: Learner priority should always target the dominant failure category from retry-failure-analysis.json
- **timeout-patterns**: 0/0 success
- **timeout**: 0/1 success | Rule: In `agents/planner.sh`, reject any proposed step whose text exceeds `400` characters or contains mor
- **ui**: 0/0 success

## System Health

All-time success rate: 0.3. Recent (last 50): 0.76. Q4 (last 132): 0.76. First-pass: 0.67. Timeout rate: 0.28.
Focus: maintain improvement trend, reduce loop effort (4 wasted step attempts).
Trend: IMPROVING (+58.7pp first-half vs second-half success rate).
Waste: 20 zombie tasks (5+ repeated failures), 231 zero-step timeouts (planning overhead).

