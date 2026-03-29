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

- Reject edit plans that only confirm an existing state instead of making the requested change; classify these as non-retriable no-op mismatches.
- Require each plan step to be concrete, bounded, and focused on a single file or action; split overly dense steps before execution.
- Classify "already exists", "no changes needed", and similar outcomes as deterministic non-retriable failures rather than retry candidates.
- Validate referenced files and anchors before dispatch; fail planning immediately when the source or quoted anchor cannot be found.
- Do not requeue an unchanged plan after reviewer-output/schema failures; classify the review result explicitly and require a changed approach.

## Provider Routing

Use `claude` provider for UI tasks. Use `codex` for all other categories.
See `codex-learning/provider-routing.json` for detailed routing rules.

## Key Learnings by Topic

- **code_quality**: 39/141 success
- **dashboard**: 1/2 success | Rule: Prefer rules that target repeated cross-task failures, not one dashboard epic or one field.; When a 
- **general**: 1/1 success | Rule: In `agents/planner.sh`, add a preflight `detect_noop_anchor_task()` that runs before step generation
- **memory**: 0/1 success | Rule: In `agents/planner.sh`, reject any self-improve task whose title or failed step text exceeds 220 cha
- **performance**: 0/2 success | Rule: Shell scripts must pass bash -n, Python must pass ast.parse, JSON must pass json.tool. Never return 
- **planning**: 1/2 success | Rule: In `agents/planner.sh`, reject or auto-rewrite any step whose text contains `Expected:` plus a claim
- **provider**: 0/1 success | Rule: In `agents/planner.sh`, reject any self-improve task whose title or failed step text exceeds 220 cha
- **queue-handling**: 0/0 success
- **queue**: 0/1 success | Rule: In `agents/planner.sh`, reject any task title or step prompt over 24 words or containing 3 or more c
- **stability**: 0/2 success | Rule: Prefer rules that target repeated cross-task failures, not one dashboard epic or one field.; When a 
- **timeout-patterns**: 0/0 success
- **ui**: 0/0 success

## System Health

All-time success rate: 0.14. Recent (last 50): 0.06. Q4 (last 132): 0.06. First-pass: 1.0. Timeout rate: 0.35.
Focus: reduce timeout rate (0.35 of failures), prevent zero-step-attempt timeouts via simpler plans.
Trend: NOT IMPROVING (-1.7pp first-half vs second-half success rate).
Waste: 20 zombie tasks (5+ repeated failures), 224 zero-step timeouts (planning overhead).

