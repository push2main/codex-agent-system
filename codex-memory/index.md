# Codex Agent System — Memory Index
# This file is always loaded into agent context (max 200 lines).
# Detailed learnings are stored in codex-memory/topics/<category>.md

## Core Architecture Rules
- All agents must return valid JSON with status, message, data fields
- Maximum 6 steps per plan, last step must be verification
- Never break the system — all changes must be incremental and reversible
- Queue workers execute in parallel — avoid file conflicts
- Task registry is the single source of truth for task state

## Known Failure Patterns
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

## Operational Rules
- Shell scripts must pass bash -n before deployment
- Python must pass ast.parse before deployment
- JSON must pass json.tool before deployment
- Classify failures as retriable vs non-retriable before retrying
- Non-retriable errors (auth, syntax, missing dependency, missing environment) should not consume retries
- Strategy-generated tasks that fail should have 24h cooldown before regeneration
- Metrics accuracy is the foundation of learning — always refresh after state changes

## Learned Rules
- Require every generated task to name at least one existing file path and one concrete function, branch, or section anchor.
- Reject or rewrite tasks that span multiple files or multiple objectives into a single-file, single-outcome task before execution.
- Fail fast with `missing_source_file` when a task references files that do not exist; do not spend retries on ungrounded prompts.
- Keep inspection or inventory tasks to at most two steps: identify one concrete edit location, then verify.
- Ban meta-improvement tasks when recent execution success is very low; prioritize concrete source-file edits and tests instead.
