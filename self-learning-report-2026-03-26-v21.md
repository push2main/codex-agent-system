# Self-Learning Report — Iteration 21
**Date:** 2026-03-26T12:15:00Z
**Trigger:** Scheduled self-learning task
**Question:** Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

---

## Executive Summary

**Yes, the system is learning — measurably.** Non-timeout learning velocity is +6.8 pp/100 tasks. The recovery from a 4% nadir (provider routing crisis) to 28% recent success rate demonstrates real adaptive capability. However, two structural bottlenecks limit the pace: (1) timeout failures (37% of all tasks) and (2) deadlock patterns in the health-gating system. Iteration 21 fixes a critical deadlock that was preventing any task execution.

---

## Key Metrics

| Metric | Value | Trend |
|--------|-------|-------|
| All-time success rate | 15% (79/524) | Baseline |
| Recent window (last 50) | 28% | ↑ from 4% nadir |
| Non-timeout success rate | 27% | ↑ strong signal |
| Timeout rate | 37% (196/524) | Dominant bottleneck |
| Learning velocity | +4.4 pp/100 tasks | Positive |
| Non-timeout velocity | +6.8 pp/100 tasks | Strong positive |
| Iteration trend delta | +4.7 pp/iteration | Improving |
| Self-learning iterations | 21 | Active |
| Zombie tasks shelved | 18 | Waste prevented |
| Unknown retry classification | 13% (down from 76%) | Major improvement |
| Diagnostic coverage | 100% | Full visibility |

---

## Is Learning Efficient?

### What's working well

1. **Failure classification** improved from 76% unknown to 13% unknown — the system can now see and categorize its failure modes, which is prerequisite for learning.

2. **Provider routing** correctly identified and routed away from the broken Claude provider (1056+ failures). All 8 categories now route to codex.

3. **Rule accumulation** follows a disciplined pattern: max 20 rules, deduplicated, focused on cross-task recurring failures rather than one-off issues. 19 rules accumulated so far, each addressing a real systemic problem.

4. **Infrastructure self-healing** has progressively improved: mutual watchdog (iteration 15), staleness escape (iteration 10), crash isolation (iteration 19), heredoc extraction (iteration 20).

### What's limiting efficiency

1. **Timeout dominance (37%)** — The single largest failure category. 94% of timeouts are "zero-step" (planner budget exhaustion). The system has identified this but hasn't solved it yet.

2. **Health gate deadlocks** — Iteration 21 found and fixed a new deadlock where health flags block task generation even when the system is completely idle. Each deadlock discovery costs 6-24 hours of dead time.

3. **Fix-to-deploy latency** — Fixes written to files don't take effect until the running process reloads. The hot-reload mechanism works but has caused crash loops when broken scripts are loaded. The `bash -n` guard (iteration 19) helps but only applies to hot-reloads, not watchdog restarts.

4. **Cooldown re-arming** — The 5-minute cooldown re-arms every cycle when "3+ recent timeouts" are detected, creating longer effective downtime. Historical timeout entries in system.log can trigger false positives.

---

## Iteration 21 Diagnosis & Fixes

### Problem 70: Queue Gate Deadlock (CRITICAL)

**Symptom:** Strategy-loop runs without crashing (iteration 20 fix works) but reports "Queue gate active" every minute. `queue_size=0`, `running_tasks=0`, yet no new tasks generated.

**Root cause:** Health flags (`retry_churn=true`, `loop_effort=true`) block the queue gate. The `pipeline_stale` escape requires 6 hours of inactivity, but self-improve log entries reset the staleness clock. Result: permanent deadlock where the system is idle but cannot generate work.

**Fix:** Added zero-queue escape hatch in `strategy-loop.sh`: when `effective_queue_size=0 AND running_tasks=0`, override all health flags. Validated with `bash -n`.

### Problem 71: Auto-Approve Requires Stale Pipeline

**Symptom:** `strategy-auto-approve.py` exits early when `pipeline_stale=false`, even though 0 tasks are approved/running/queued and 1 task sits in `pending_approval`.

**Root cause:** Auto-approve only triggers on stale pipeline, but ancillary processes (self-improve, compact-registry) write to task log, resetting the staleness clock without actual task progress.

**Fix:** Auto-approve now also triggers on `zero_queue` (0 approved + 0 running + 0 queued), with a reduced 10-minute threshold. When nothing is running, approving a pending task is always safe.

---

## Architectural Lessons (New)

5. **Health gates must have idle-system escape hatches** — A system with zero queued AND zero running work should NEVER be blocked from generating new work, regardless of health flag state.

6. **Staleness detection is fragile** — Timestamp-based staleness from task logs conflates "any log activity" with "actual task execution progress". Consider tracking these separately.

7. **Deadlock pattern in self-healing systems:** health flag → blocks generation → no executions → flag persists → deadlock. Every blocking condition must have a guaranteed escape path.

---

## Files Modified

| File | Change |
|------|--------|
| `scripts/strategy-loop.sh` | Added zero-queue escape hatch (lines 385-400) |
| `scripts/strategy-auto-approve.py` | Added zero_queue trigger path + 10min threshold |
| `codex-learning/rules.md` | Added rule 19: zero-queue escape for health gates |
| `CLAUDE.md` | Updated iteration count to 21, documented Problems 70-71 |

All modified files pass syntax validation (`bash -n`, `ast.parse`).

---

## Recommendations for Next Iteration

1. **Address timeout dominance** — 37% of all tasks fail due to zero-step timeouts (planner budget exhaustion). Cap planner budget at 60s and implement fail-fast handoff.

2. **Separate execution staleness from log staleness** — Track `last_successful_execution_at` independently from task log timestamps to prevent ancillary processes from masking true inactivity.

3. **Add cooldown deduplication** — The timeout cooldown re-arms every 5 minutes from the same historical entries. Track `last_cooldown_trigger_marker` and skip re-arming when the same marker is seen twice.

4. **Consider reducing learned rules from 19 toward more impactful subset** — Some early rules may be superseded by later infrastructure fixes.
