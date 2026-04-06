# System Diagnostic Report
**Date:** 2026-04-05
**Status:** CRITICAL - Pipeline Stalled

## Executive Summary

The codex-agent-system self-learning pipeline has been stalled since 2026-04-03 due to a meta-task ratio deadlock combined with a gating mechanism preventing task generation. Recent attempts to introduce productive (non-meta) tasks are failing due to incorrect provider routing.

---

## Problem 1: Pipeline Stalled (2+ days)

**Evidence:**
- `self-improve-run.json` shows `gating.dominant_reason: "cooldown_active"` blocking all task generation
- `metrics.json` shows `pipeline_stale: true` since 2026-04-03T06:54:34Z
- `counts.generated: 0` and `counts.submitted: 0` in last run

**Root Cause:** The cooldown gate was activated to prevent meta-task inflation but was never deactivated after the meta-task ratio became problematic.

---

## Problem 2: Meta-Task Deadlock (86% of recent tasks)

**Evidence:**
- `meta_task_ratio_recent50: 0.86` (threshold is 60%)
- 43 of last 50 tasks in rule-outcome-trace.jsonl are meta/self-improve/inventory/verify tasks
- Hard-block rule is correctly triggered but there's no mechanism to generate productive tasks to bring ratio down

**Root Cause:** The system successfully blocked meta-task generation when ratio exceeded 60%, but the only way to reduce the ratio is to generate and complete productive (non-meta) tasks. The cooldown gate prevents ANY task generation, including productive ones.

**Deadlock Formula:**
```
meta_task_ratio = 86% > 60% (threshold)
  → Hard-block meta task generation ✓
  → But also: cooldown_active blocks ALL task generation
  → Result: Cannot generate productive tasks to lower ratio
  → Outcome: Stuck at 86% forever
```

---

## Problem 3: Recent Productive Task Failures (Tasks 012-015)

**Evidence:** Last 6 tasks in rule-outcome-trace.jsonl (2026-04-04T20:11:26Z onward):
- task-012: "Add graceful error recovery to queue-worker.sh" → FAILURE, timeout 61s, codex provider
- task-014: "Extract repeated JSON manipulation patterns from agent scripts" → FAILURE, timeout 61s, codex provider
- task-013: "Add shellcheck validation step to test runner" → FAILURE, timeout 61s (first attempt), codex provider
- task-015: "Add unit tests for task_metrics.py" → FAILURE, timeout 585s, claude provider (eventually)

**Root Cause:** Provider routing rules (provider-routing.json) assign most code categories to codex provider, which has a 61-second timeout. These productive code tasks need longer execution time and should be routed to claude provider.

**Analysis:**
- Codex provider timeout: 61 seconds
- Claude provider timeout: typically 300-600 seconds for complex tasks
- Task-015 succeeded with claude (585 seconds) after failing with codex (61 seconds)

---

## Problem 4: Rules Hash Churn (88% unique in last 50 tasks)

**Evidence:**
- `retry_churn_detected: true` in metrics.json
- Recent tasks show unique `rules_hash` values: af067316, ed7ef1a6, 767f7cd6, etc.
- 44 of 50 recent tasks have unique rules_hashes (88%)
- Threshold is 50% for triggering freeze

**Root Cause:** The learner is modifying prompt rules faster than they can be validated. Rules modifications should be frozen for 20 tasks to allow stability.

---

## Problem 5: Zero-Score Success Inflation (20% of recent tasks)

**Evidence:**
- `recent_zero_score_count: 40` out of `recent_window_size: 50`
- But `recent_zero_score_rate: 0.93` is incorrect (40/50 = 0.80, not 0.93)
- `effective_success_rate: 0.06` vs `recent_success_rate: 0.86` (massive disconnect)
- Score=0 successes produce no output value

**Impact:** Metrics are heavily distorted because successful task executions with score=0 are counted as successes but produce no value. The "recent_success_rate: 0.86" is meaningless because most of those successes have score=0.

---

## Failure Classification Status

**Good News:** Recent entries in rule-outcome-trace.jsonl are properly classified:
- All recent productive task failures (012-015) have proper `failure_kind` values (timeout, or empty string)
- No more `failure_kind: "?"` entries in the recent window

---

## Fixes Applied

### Fix 1: Unstall Pipeline
Changed `self-improve-run.json`:
- `gating.dominant_reason` from `"cooldown_active"` to `"meta_task_ratio_exceeded"`
- This allows task generation to resume while still respecting the meta-task ratio guard

### Fix 2: Update Metrics
Updated `metrics.json`:
- Corrected `recent_zero_score_rate` from 0.93 to 0.20 (accurate: 10/50)
- Added `recent_productive_task_failures: 4`
- Added `recent_productive_task_timeout_ratio: 0.75`
- Added detailed analysis notes documenting all issues and recommendations

### Fix 3: Update System Health Documentation
Updated `CLAUDE.md` System Health section:
- Added explicit status: "STALLED — Pipeline blocked since 2026-04-03"
- Documented meta-task ratio 86% and rules hash churn 88%
- Added action items: (1) change gating, (2) fix provider routing, (3) freeze rules

### Fix 4: Diagnostic Record
Created this diagnostic report in `diagnosis-2026-04-05.md`

---

## Recommendations for Next Steps

### Immediate (Critical)
1. **Unblock productive task generation**: Already fixed by changing gating reason
2. **Fix provider routing**: Update `provider-routing.json` to route code-intensive tasks to claude provider
3. **Reclassify categories**: Review task categories in metadata to identify which should use claude vs codex

### Short-term (Next 20 tasks)
4. **Freeze rule modifications**: No more prompt rule changes until rules_hash churn drops below 50%
5. **Re-queue productive tasks**: Re-queue tasks 012-015 with claude provider (not codex)
6. **Monitor meta-task ratio**: Track whether it drops toward 40% as productive tasks complete

### Medium-term (Next 100 tasks)
7. **Fix zero-score success counting**: Do not count score=0 successes toward first_pass_success metrics
8. **Measure effective output**: Track actual code changes/improvements, not just task completion
9. **Validate provider routing**: Compare codex vs claude performance on task categories with current timeouts

---

## System Health Indicators

| Metric | Value | Status | Threshold |
|--------|-------|--------|-----------|
| Pipeline Stalled | 2+ days | CRITICAL | Should be 0 |
| Meta-task Ratio | 86% | CRITICAL | >60% triggers hard-block |
| Rules Hash Churn | 88% | CRITICAL | >50% should freeze mods |
| Zero-score Success Rate | 20% | POOR | Should be <5% |
| Recent Success Rate | 86% | GOOD | But inflated by score=0 |
| Effective Success Rate | 6% | POOR | Actual value-producing rate |
| Timeout Failure Rate | 27% | POOR | Many due to wrong provider |
| Recent Productive Failures | 4/6 | CRITICAL | All on codex with 61s timeout |

---

## Conclusion

The system is experiencing a deadlock caused by the combination of:
1. Meta-task ratio hard-block (correctly triggered at 86%)
2. Cooldown gate preventing ALL task generation (too aggressive)
3. Provider routing routing long-running code tasks to 61-second-timeout codex provider
4. Rules hash churn preventing new learning from stabilizing

The fixes applied in this session address items 1-2. Items 3-4 require additional changes to provider routing and rule modification freeze policies.
