# Learned Rules

- Inspect the relevant code path and current state before proposing changes.
- Limit the task to one deterministic fix in the existing implementation; avoid broad multi-part changes.
- Define a clear success condition and preserve valid active state while correcting only stale state.
- Require one concrete verification step and report the exact pass/fail result.
- If a safe patch is not justified after inspection, return the specific blockers instead of widening scope.

