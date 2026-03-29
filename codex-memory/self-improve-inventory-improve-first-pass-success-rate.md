# Self-Improve Inventory: Improve First-Pass Success Rate

Generated: 2026-03-28T08:00:00Z

## Live weakness

- `codex-learning/metrics.json` reports `first_pass_success_rate: 0` while `retry_churn_detected` and `pending_approval_blocked_detected` are both true.
- Recent retries for `Inventory current decision path for improve first-pass success rate` failed because the required inspection deliverable never named a concrete control point in `agents/planner.sh`.
- Existing learning already says to keep inspection retries bounded to one file and one exact edit site before another implementation attempt.

## Primary edit site

- File: `agents/planner.sh`
- Function: `fallback_planner()`
- Narrow branch: the inventory-only fallback path entered by `if inventory_only_step(implementation_step):`

This branch is the current control point for first-pass self-improve inventory tasks because it rewrites bounded inventory work into the first inspection step that later agents must satisfy.

## Decision path

1. `planner_inventory_fallback_signal()` detects bounded inventory-only tasks and forces deterministic planner fallback instead of provider planning.
2. `fallback_planner()` builds the concrete inspection step through `concrete_inspection_step()`.
3. For inventory-only work, `fallback_planner()` immediately uses that inspection step before the artifact-writing step.
4. Review evidence in `codex-learning/retry-failure-analysis.jsonl` identifies this same area as the missing exact control point for the failed first-pass-success inventory retries.

## Secondary surfaces

- `tests/planner-self-improve-inventory-artifact-filter.sh`
  Guardrail: preserve the existing behavior that step 1 references only `agents/planner.sh` and does not mention the generated inventory artifact path.
- `tests/planner-bounded-learning-inventory-fallback.sh`
  Guardrail: preserve the deterministic three-step bounded-inventory fallback with artifact verification.
- `agents/coder.sh`
  Relevant only after the planner fix lands, because bounded inventory tasks depend on the planner emitting a sufficiently concrete inspection step before coder execution.

## Next implementation hypothesis

Apply the smallest safe planner-only change in `agents/planner.sh` so bounded inventory inspection steps can include one repository-grounded anchor when the task already narrows to a single existing file. For the current weakness, start with `fallback_planner()` and the `inventory_only_step(implementation_step)` branch without changing queue behavior, provider routing, or generic fallback semantics.

## Verification targets for the next retry

- `bash tests/planner-self-improve-inventory-artifact-filter.sh`
- `bash tests/planner-bounded-learning-inventory-fallback.sh`

## Do not change in the next retry

- Do not reintroduce generated inventory artifact paths into the first inspection step.
- Do not expand the bounded inventory fallback beyond one primary file unless a new failure proves the single-file scope is wrong.
- Do not change coder or orchestrator behavior before the planner control point is tightened.
