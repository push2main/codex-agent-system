# Prompt Rules

- Restate the exact replacement target and explicitly forbid reusing the old title, template, or signal names before making changes.
- Limit implementation to the named files and the existing saturation-recovery path; do not inspect or modify unrelated flows.
- Base the new experiment only on already-present persisted fields such as `strategy_saturation_detected` and `saturated_failed_tasks`.
- Make one small deterministic patch that changes the seeded follow-up task text/template only, without adding storage, helpers, or new branching paths.
- Verify with a focused check that confirmed saturation now produces a different bounded experiment name and no longer references `retry_churn_guard` or the old task title.

