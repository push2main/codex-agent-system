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

- Keep single-file tasks narrowly scoped: if a task targets one file, do not expand writable scope beyond that file, and split mixed "investigate plus implement" work into bounded steps only when necessary.
- For review-rejection retries on single-file tasks, require minimal structured context from the rejection: target file, a concrete edit anchor, and the reason for retry; if that context is missing, route to inventory instead of retrying implementation.
- Suppress near-duplicate implementation tasks when a very recent open or successful task already targets the same file and intent; prefer emitting a single verification or inventory task instead.
- Treat low-confidence successes conservatively: if success follows multiple attempts or weak review evidence, require bounded verification before using that success to suppress related follow-up work.
- Reject rules that depend on specific filenames, exact word counts, exact hour windows, exact score cutoffs, or exact phrase patterns; generalize them before adoption.

## Provider Routing

Use `claude` provider for UI tasks. Use `codex` for all other categories.
See `codex-learning/provider-routing.json` for detailed routing rules.

## Key Learnings by Topic

- **code_quality**: 125/261 success
- **dashboard**: 27/25 success | Rule: In the orchestrator step-builder, reject any generated step as `missing_source_file` before dispatch
- **general**: 16/16 success | Rule: In the task generator function that builds step text for self-improve tasks, if the declared file pa
- **memory**: 2/3 success | Rule: In `orchestrator` task pre-check, if a task title/body contains `Start with` and exactly 1 file path
- **performance**: 0/2 success | Rule: Shell scripts must pass bash -n, Python must pass ast.parse, JSON must pass json.tool. Never return 
- **planning**: 5/6 success | Rule: In the planner pre-check that builds self-improve tasks, if `declared files` contains any `*.json` p
- **provider**: 1/2 success | Rule: In `agents/planner.sh`, reject any self-improve task whose title or failed step text exceeds 220 cha
- **queue-handling**: 0/0 success
- **queue**: 27/25 success | Rule: In the orchestrator pre-step builder, reject any generated step whose instruction text introduces a 
- **stability**: 27/25 success | Rule: In the orchestrator task-to-step compiler, reject any generated step whose instruction text contains
- **testing**: 28/25 success | Rule: In the planner task-to-step compiler, hard-block any task whose `files:` annotation contains exactly
- **timeout-patterns**: 0/0 success
- **timeout**: 0/1 success | Rule: In `agents/planner.sh`, reject any proposed step whose text exceeds `400` characters or contains mor
- **ui**: 0/0 success

## System Health

All-time success rate: 0.24. Recent (last 50): 0.92. Q4 (last 132): 0.92. First-pass: 0.76. Timeout rate: 0.3.
Focus: maintain improvement trend, reduce loop effort (28 wasted step attempts).
Trend: IMPROVING (+61.7pp first-half vs second-half success rate).
Waste: 20 zombie tasks (5+ repeated failures), 227 zero-step timeouts (planning overhead).

