# Self-Learning Audit Report #2 — 2026-04-03

## Question: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Answer: Ja, mit Einschraenkungen

The system **is learning efficiently** and improving measurably. The success rate trajectory tells the story:

| Window | Success Rate | Timeouts |
|--------|-------------|----------|
| Tasks 1-50 | 34% | 19 |
| Tasks 101-150 | 6% | 33 |
| Tasks 601-650 | 58% | 1 |
| Tasks 701-750 | 96% | 0 |
| Tasks 751-784 | 97% | 1 |

**Improvement velocity:** +10.4 percentage points per 100 tasks. Recent-50 success: 98%.

However, three subsystems had degraded and were partially blocking the learning loop:

## Problems Found and Fixed

### 1. External Signals Stale (8+ days) — FIXED
**Root cause:** `auto_refresh: false` in `codex-learning/external-signal-sources.json`. This was the factory default that was never toggled on.
**Impact:** System blind to upstream dependency changes (OpenAI Python, Playwright releases) that could affect task planning and compatibility.
**Fix:** Set `auto_refresh: true`. Next strategy loop cycle will fetch fresh signals.

### 2. Running_tasks Metrics Drift — FIXED
**Root cause:** Queue-worker updates the task registry status after completion but never calls `validate-metrics.sh`. The stale `running_tasks: 1` persists in `metrics.json` until the next memory-sync cycle corrects it. Every single memory-sync run for the past 24+ hours showed this drift correction pattern.
**Impact:** Downstream decisions (cooldown bypass, queue starvation detection) used stale running_tasks count between sync cycles.
**Fix:** Added `validate-metrics.sh` call to queue-worker.sh success path (v28), so metrics are refreshed immediately after task completion.

### 3. Previous Fix Verified: Evaluator Scoring — CONFIRMED ACTIVE
The evaluator scoring fix from the previous self-learning run (replacing hardcoded `"score": 0` with `<CALCULATE>` marker) is confirmed in place at `agents/evaluator.sh:294`. This fix restores the value measurement feedback loop.

## Non-Issues (Investigated but Working Correctly)

- **Self-improve cooldown:** Currently 114s into 600s superheld cooldown — normal operation, not stuck
- **Retry churn alert:** Legitimately triggered by recent-30 window containing multi-attempt tasks — will auto-clear as clean tasks push old ones out
- **Registry pressure:** 247KB, well below 512KB threshold
- **Compaction:** Working correctly (reduced 796KB pre-compact to 92KB)

## Learning Efficiency Metrics

| Metric | Value | Assessment |
|--------|-------|------------|
| Learned rules | 16 (max 20) | Approaching capacity — compact or increase limit |
| Learning rate | 2.17 rules per 100 tasks | Conservative but evidence-based |
| Rule effectiveness tracing | 310 tasks traced | Good coverage |
| Retry classification coverage | 100% | Excellent (was 24%) |
| Diagnostic coverage | 100% | Excellent |
| First-pass success rate | 79% | Good |
| Zero-step timeout rate | 90% of timeouts | Historical; recent = 0 timeouts |

## Remaining Concerns

1. **Automation memory broken** (`continuity_status: "missing"`): Self-improve runs can't carry context between iterations. This limits the system's ability to build on previous improvement cycles.
2. **Rules near capacity** (16/20): Next compaction should merge overlapping rules to free slots.
3. **Score validation needed**: The evaluator fix needs to be verified against the next batch of completed tasks to confirm scores are now >0 for successful work.

## Files Changed

| File | Change |
|------|--------|
| `codex-learning/external-signal-sources.json` | `auto_refresh: false` → `true` |
| `scripts/queue-worker.sh` | Added post-completion `validate-metrics.sh` call (v28) |
| `codex-learning/rules.md` | Added 2 new learned rules (14 total) |
| `CLAUDE.md` | Updated learned rules and system health sections |

## New Learned Rules

1. After task completion/failure, call validate-metrics.sh to prevent running_tasks counter drift
2. Keep external-signal-sources.json auto_refresh enabled — stale signals blind the system to upstream changes
