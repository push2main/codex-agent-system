# Self-Learning Audit Report — 2026-04-03

## Diagnosis: Measurement Blindness

The system has reached a **97-98% task execution success rate** (up from 4% at its lowest) but has been **unable to measure value produced** since approximately task #733. All 50 most recent tasks scored 0, making the system effectively blind to whether its work produces useful output.

### Root Cause

The evaluator agent prompt in `agents/evaluator.sh` contained a JSON template with a literal `"score": 0` value. The LLM copied this placeholder verbatim instead of calculating an actual score. The fallback evaluator (used when the LLM fails) has correct scoring logic (8 for approved, 3 for retry, 1 for invalid), but since the LLM succeeded in returning valid JSON, the fallback was never triggered.

### Impact

Without meaningful scores, the system could not:
- Distinguish productive tasks from wasteful repetitions
- Prioritize task families that produce value
- Detect when detection logic was broken (same task succeeding 5+ times with no effect)
- Close the learning feedback loop (score → strategy → better tasks)

This led to **57+ repetitive tasks** across 3 families (verify-dashboard-incident, verify-credential-recovery, inventory-decision-path) consuming slots with zero value.

## Fixes Applied

### 1. Evaluator Scoring (Critical Fix)
**File:** `agents/evaluator.sh`

Replaced the hardcoded template value with explicit scoring instructions:
- Added 0-10 scoring rubric with clear value definitions
- Replaced literal `"score": 0` with `<integer 0-10 — CALCULATE THIS>`
- Added rule: "If review approved, score ≥ 5 unless trivial"
- Added rule: "If review rejected, score 0-3 based on partial progress"

### 2. Value-Gate Metrics (Prevention)
**File:** `scripts/self-improve.sh`

Added three new metrics to the self-improve pipeline:
- `recent_avg_score`: Average score of recent successful tasks
- `recent_zero_score_count`: Count of zero-score tasks in recent window
- `recent_zero_score_rate`: Fraction of recent tasks scoring zero

### 3. Value-Gate Improvement Detection (Self-Healing)
**File:** `scripts/self-improve.sh`

Added automatic detection: if `recent_zero_score_rate >= 80%` with ≥10 successful tasks, the system generates a critical improvement task to fix the evaluator. This prevents future measurement blindness from going undetected.

### 4. Documentation Updates
- **CLAUDE.md**: Updated active issue status (resolved)
- **codex-memory/index.md**: Added 3 learned rules about template values in LLM prompts
- **codex-memory/learnings.md**: Documented root cause, fix, and key insight

## Expected Outcomes

After the next task execution cycle:
- Successful tasks should score 5-8 (meaningful work)
- Failed tasks should score 0-3 (appropriate low values)
- `recent_avg_score` should rise above 4.0
- `recent_zero_score_rate` should drop below 20%
- Strategy generation should have signal to prioritize high-value task families

## System Health Summary

| Metric | Before Fix | Expected After |
|--------|-----------|----------------|
| Execution success rate | 98% | 98% (unchanged) |
| Recent avg score | 0.0 | >4.0 |
| Zero-score rate | 100% | <20% |
| Learning feedback loop | Broken | Active |
| Value measurement | Blind | Functional |
| Self-improve stall | Cooldown/idle | Should resume |

## Learned Rules (New)

1. Template values in LLM prompts are copied verbatim — use `<CALCULATE>` markers, not literal defaults
2. Track `recent_zero_score_rate` — if >80%, evaluator or task quality is broken
3. Always verify that LLM-facing templates don't contain values that look "correct enough" to copy
