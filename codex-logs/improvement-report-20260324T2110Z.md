# System Improvement Report — 2026-03-24T21:10Z

## 1. Identified Weakness: Unbounded Retry Cascading Across Templates

**Core problem**: The strategy loop's per-template saturation guard (`STRATEGY_SATURATED_FAILURE_THRESHOLD = 2`) prevents more than 2 failures per template key, but the enterprise-readiness root generates tasks across 8 different templates. Each template gets its own 2-failure budget, allowing the same root to accumulate **26 total failures** — consuming queue capacity, polluting the board, and drowning successful tasks.

**Evidence**:
- `enterprise-readiness::codex-agent-system` root: **26 failures** across 8 templates
- `strategy::retry-churn` root: **9 failures**
- `strategy::saturation-recovery` root: **9 failures**
- Overall success rate: **12%** (38 successes / 313 total)
- Today's rate: **14 successes / 91 failures** (13%)

The per-template guard correctly limits each individual template, but no mechanism caps the total failures from a single root goal, allowing infinite retry cascading via template rotation.

## 2. Improvement Applied: Root-Level Total Failure Ceiling

**Changes made** (small, safe, reversible):

1. **New constant**: `ROOT_TOTAL_FAILURE_CEILING = 6` in `agents/strategy.sh` — caps total failed tasks from any single root regardless of template variation.

2. **New function**: `count_total_failed_by_root(tasks, project, root_id)` — counts all failed tasks sharing the same `root_source_task_id`, ignoring template differences.

3. **Guard on follow-up creation** (line ~3290): Before creating a follow-up from a failed task, check if the root has already exceeded 6 total failures. If so, skip creation.

4. **Guard on enterprise seed loop** (line ~3443): Before entering the enterprise template iteration, compute the root's total failure count. Skip the entire loop if the ceiling is reached.

5. **Updated learned rules** in `codex-learning/rules.md` to document the pattern and fix.

**Why 6**: Allows 3 templates × 2 failures each (the existing per-template threshold) before the root is considered exhausted. This is generous enough to give genuine variety a chance while preventing the 26-failure cascades observed.

**Safety**: The change only prevents *new* task creation. It does not modify running tasks, queue entries, or existing code paths. The ceiling is easily adjustable.

## 3. Outcome: Applied (pending next strategy loop cycle)

The change will take effect on the next strategy loop iteration. Expected immediate effects:
- Enterprise-readiness root (26 failures) will be blocked from generating further tasks
- Other saturated roots (retry-churn at 9, saturation-recovery at 9) will also be blocked
- Queue capacity freed for genuinely new or successful task paths

Pre-existing test failures (from other uncommitted changes) remain unaffected by this patch.

## 4. Knowledge Gained

- Per-template saturation guards are necessary but insufficient for roots that spawn across many templates.
- The enterprise-readiness seeding mechanism creates tasks across 8+ template keys, each with independent saturation budgets — this is the primary mechanism for unbounded retry accumulation.
- The auto-repair loop (994 events) is a secondary symptom: stuck pending-approval tasks get repeatedly "repaired" but never progress because the underlying goals keep failing.
- Score=8 failures (48 tasks) indicate partial step completions — the coder succeeds on step 1 but fails on step 2 or 3, suggesting task decomposition quality is the next bottleneck after retry cascading is controlled.

## 5. Next Best Improvement

**Task complexity gating at planning time**: Before the planner generates steps, estimate task complexity (number of files to edit, code path depth) and reject tasks that exceed the coder agent's demonstrated capability envelope (single-file, concrete, <300s tasks succeed at ~60%; multi-file complex tasks succeed at <10%). This would prevent wasted cycles at the source rather than after multiple failed attempts.
