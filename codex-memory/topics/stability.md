# Stability Learnings
- 2026-03-24T20:25:07Z | FAILURE | Inventory current state for Generate bounded successor UI tasks from failed dashboard epics until the requirement
  Rules: Prefer rules that target repeated cross-task failures, not one dashboard epic or one field.; When a task is inventory-only, state explicitly: inspect named files, write one compact artifact, and do not implement code changes.; Require each step to name exact files, outputs, and verification commands so planner/coder/reviewer stay aligned.
- 2026-03-24T21:00:00Z | IMPROVEMENT | Failure classification (MAST taxonomy) added to orchestrator retry loop.
  Rules: Classify failures as retriable vs non-retriable before retrying. Non-retriable errors (auth, syntax, missing deps) abort immediately. Unknown errors become non-retriable after 2 attempts. Use exponential backoff with jitter between retries to prevent thundering herd.
