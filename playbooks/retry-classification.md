Keep the task inside the deterministic retry-classification path.

- Prefer existing failure-classification helpers and context-enrichment code over new retry loops.
- Improve classification coverage before changing retry counts, cooldowns, or worker parallelism.
- Favor bounded edits in `agents/orchestrator.sh`, reviewer/evaluator context shaping, or `scripts/lib.sh`.
- Validation should prove that newly captured reviewer/evaluator/error text reaches classification deterministically.
