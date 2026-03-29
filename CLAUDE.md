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

- Validate referenced files or templates before dispatch; if a required path is missing, fail early as `missing_source_file`.
- Detect unchanged-state tasks before editing; if the requested text or outcome already exists, classify as `no_change_produced` instead of retrying.
- Keep plan steps short, concrete, and single-intent; split any step that combines inspection, editing, and verification.
- Reclassify deterministic reviewer outcomes like missing anchors or already-applied changes out of `review_rejection` and into explicit non-retry categories.
- Do not start a step unless enough time budget remains to finish it and run required verification.

## Provider Routing

Use `claude` provider for UI tasks. Use `codex` for all other categories.
See `codex-learning/provider-routing.json` for detailed routing rules.

## Key Learnings by Topic

- **code_quality**: 41/143 success
- **dashboard**: 1/2 success | Rule: Prefer rules that target repeated cross-task failures, not one dashboard epic or one field.; When a 
- **general**: 2/2 success | Rule: In `agents/planner.sh`, reject any step text longer than `450` characters before dispatch, not just 
- **memory**: 0/1 success | Rule: In `agents/planner.sh`, reject any self-improve task whose title or failed step text exceeds 220 cha
- **performance**: 0/2 success | Rule: Shell scripts must pass bash -n, Python must pass ast.parse, JSON must pass json.tool. Never return 
- **planning**: 1/2 success | Rule: In `agents/planner.sh`, reject or auto-rewrite any step whose text contains `Expected:` plus a claim
- **provider**: 1/2 success | Rule: In `agents/planner.sh`, reject any self-improve task whose title or failed step text exceeds 220 cha
- **queue-handling**: 0/0 success
- **queue**: 0/1 success | Rule: In `agents/planner.sh`, reject any task title or step prompt over 24 words or containing 3 or more c
- **stability**: 0/2 success | Rule: Prefer rules that target repeated cross-task failures, not one dashboard epic or one field.; When a 
- **timeout-patterns**: 0/0 success
- **ui**: 0/0 success

## System Health

All-time success rate: 0.14. Recent (last 50): n/a. Q4 (last 132): n/a. First-pass: 0.67. Timeout rate: 0.35.
Focus: reduce timeout rate (0.35 of failures), prevent zero-step-attempt timeouts via simpler plans.

