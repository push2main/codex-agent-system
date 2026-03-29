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
- Require every generated task to name at least one existing file path and one concrete function, branch, or section anchor.

## Learned Rules
- Keep plan steps concrete, bounded, and single-intent; split any step that combines inspection with editing or packs in excessive detail.
- Validate every referenced file, anchor, or template before dispatch; fail planning immediately if the source cannot be found.
- Treat unchanged-state outcomes such as “already exists” or “no changes needed” as deterministic non-retriable results, not retry candidates.
- Do not retry an unchanged plan after repeated reviewer schema or parsing failures; require replanning with a different approach.
- Preserve plan structure limits: small incremental steps only, with verification as the final step.
