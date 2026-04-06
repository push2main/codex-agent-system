# Deployment Checklist - Pipeline Unblocking

**Date:** 2026-04-05
**Status:** Analysis Complete, Ready for Deployment
**Priority:** CRITICAL (Pipeline stalled 46+ hours)

---

## Pre-Deployment Verification

- [ ] Read and understand ANALYSIS-REPORT-2026-04-05.txt
- [ ] Review diagnosis-2026-04-05.md for root cause details
- [ ] Confirm self-improve-run-FIXED.json exists and is valid JSON
- [ ] Backup original self-improve-run.json before replacement
- [ ] Backup original provider-routing.json before modifications

---

## Step 1: Unblock Pipeline (CRITICAL)

**Action:** Replace self-improve-run.json with corrected version

```bash
# Backup original
cp /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run.json \
   /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run.json.backup-2026-04-05

# Deploy fixed version
cp /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run-FIXED.json \
   /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run.json
```

**Change Details:**
- `gating.dominant_reason`: "cooldown_active" → "meta_task_ratio_exceeded"
- `gating.analysis_reason`: "cooldown_active" → "meta_task_ratio_exceeded"
- `gating.submission_reason`: "cooldown_active" → "meta_task_ratio_exceeded"

**Verification:**
```bash
# Verify the change was applied
grep -A 2 '"gating"' /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run.json | grep "meta_task_ratio_exceeded"
```

Expected output: Should show "meta_task_ratio_exceeded" in all three gating reason fields

- [ ] Original backed up
- [ ] FIXED version deployed
- [ ] Gating reasons verified changed
- [ ] JSON validity confirmed

---

## Step 2: Fix Provider Routing (HIGH)

**Action:** Update provider-routing.json to correct provider assignments

**File:** `/sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/provider-routing.json`

**Changes Required:**

Current problematic assignments (all to codex which has 61s timeout):
- `code_quality`: codex → SHOULD BE claude
- `general`: codex → SHOULD BE claude (or consider split)
- `testing`: codex → SHOULD BE claude
- `infra`: codex → CONSIDER claude (or longer codex timeout)

**Reasoning:**
- Productive code tasks (tasks 012-015) failed on codex (61s timeout)
- Claude provider has 300-600s timeout, appropriate for complex work
- Evidence shows even task-015 needed 585 seconds

**Modification Template:**

For each category that should use claude:
```json
{
  "category": "code_quality",
  "provider": "claude",
  "enabled": true,
  "reason": "Code quality tasks need longer execution time; codex 61s timeout too short for refactoring and testing"
}
```

- [ ] Backup original provider-routing.json
- [ ] Update code_quality category to claude
- [ ] Update general category to claude
- [ ] Update testing category to claude
- [ ] Consider infra category (keep as codex or change to claude)
- [ ] Verify JSON validity
- [ ] Test with next task generation

---

## Step 3: Requeue Failed Productive Tasks (HIGH)

**Action:** Mark tasks 012, 013, 014, 015 for retry with claude provider

**Tasks to Requeue:**
1. task-012: "Add graceful error recovery to queue-worker.sh for orphaned lease cleanup"
   - Status: Change from FAILURE back to PENDING
   - Provider: Change from codex to claude

2. task-013: "Add shellcheck validation step to test runner for all agent scripts"
   - Status: Change from FAILURE back to PENDING
   - Provider: Change from codex to claude

3. task-014: "Extract repeated JSON manipulation patterns from agent scripts into lib.sh helpers"
   - Status: Change from FAILURE back to PENDING
   - Provider: Change from codex to claude

4. task-015: "Add unit tests for task_metrics.py core metric computation functions"
   - Status: Change from FAILURE back to PENDING
   - Provider: Keep as claude (already assigned correctly, but timed out)
   - Note: May need task complexity review or increased timeout

**Process:**
- [ ] Locate task registry (usually in codex-memory/tasks.json)
- [ ] Find tasks 012, 013, 014, 015
- [ ] Change status from "failed" or "completed" back to "approved" or "pending"
- [ ] Ensure provider field is set to "claude" (not "codex")
- [ ] Clear any failure state data
- [ ] Verify JSON validity after edits

---

## Step 4: Freeze Rule Modifications (HIGH)

**Action:** No prompt rule changes for next 20 tasks

**Reason:** Rules hash churn is at 88% (threshold 50%), rules changing too fast

**Implementation:**
- [ ] Update CLAUDE.md to document rule modification freeze
- [ ] Add comment to prompt-rules.md: "FROZEN until task-XXX, churn control"
- [ ] Alert team: No rule changes for next 20 tasks

**Duration:** Next 20 tasks (approximately)

**Validation:**
- Monitor rules_hash_churn in subsequent task runs
- Should decrease from 88% toward <50%
- When churn stabilizes, can resume careful rule modifications

---

## Step 5: Verify Pipeline Resumption

**Action:** Monitor first task generation after fixes

**Expected Outcomes:**
1. self-improve-run.json shows:
   - `gating.dominant_reason`: "meta_task_ratio_exceeded" ✓
   - `counts.generated`: > 0 (was 0 before)
   - `counts.submitted`: > 0 (was 0 before)

2. rule-outcome-trace.jsonl shows:
   - New tasks being generated (timestamps after 2026-04-05)
   - Mix of meta and productive tasks
   - Productive tasks mostly on claude provider

3. Meta-task ratio begins declining
   - Should move from 86% toward lower values
   - As productive tasks are generated and completed

- [ ] Pipeline resumes task generation
- [ ] Counts.generated and counts.submitted increase
- [ ] New tasks appear in rule-outcome-trace.jsonl
- [ ] Productive tasks visible in new generation
- [ ] Meta-task ratio trend downward

---

## Post-Deployment Monitoring (24-48 hours)

**Track These Metrics:**

| Metric | Before | Target | Check |
|--------|--------|--------|-------|
| Pipeline stalled | 46+ hours | Active | [ ] |
| Meta-task ratio | 86% | <70% | [ ] |
| Productive tasks | 0 in queue | >0 | [ ] |
| Rules hash churn | 88% | <70% | [ ] |
| Recent failures | 75% timeout | <20% | [ ] |
| Task generation | 0/run | >0/run | [ ] |
| Task completion | Stalled | Improving | [ ] |

**Success Criteria:**
- Pipeline shows task generation for 3+ consecutive runs
- Meta-task ratio decreases (tracking downward)
- Productive tasks appearing in queue
- Timeout failures decrease
- Zero-step timeouts not increasing

---

## Rollback Plan

If issues emerge:

**Rollback Step 1 (Pipeline):**
```bash
cp /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run.json.backup-2026-04-05 \
   /sessions/gifted-relaxed-galileo/mnt/codex-agent-system/codex-learning/self-improve-run.json
```

**Rollback Step 2 (Provider Routing):**
```bash
# Revert provider-routing.json from version control or backup
```

**Rollback Step 3 (Task Queue):**
```bash
# If tasks become unworkable, restore task registry from backup
```

---

## Sign-Off

- [ ] All analysis documents reviewed
- [ ] All steps understood
- [ ] Ready to deploy fixes
- [ ] Deployment completed
- [ ] Monitoring active

---

## Timeline Estimate

| Phase | Time | Status |
|-------|------|--------|
| Pre-deployment checks | 15 min | [ ] |
| Step 1: Replace config | 5 min | [ ] |
| Step 2: Update routing | 10 min | [ ] |
| Step 3: Requeue tasks | 10 min | [ ] |
| Step 4: Freeze rules | 5 min | [ ] |
| Step 5: Verify resume | 5 min | [ ] |
| Monitor (first run) | 10 min | [ ] |
| Post-deployment monitor | 24-48h | [ ] |

**Total:** ~1 hour to deploy + 24-48h to monitor

---

## References

**Analysis Documents:**
- ANALYSIS-REPORT-2026-04-05.txt - Executive summary
- diagnosis-2026-04-05.md - Root cause analysis
- metrics-analysis-2026-04-05.json - Structured metrics analysis
- FIXES-APPLIED-2026-04-05.md - Detailed fix documentation

**Configuration Files:**
- self-improve-run-FIXED.json - Ready to deploy
- Original self-improve-run.json - Backup before replacement

**Updated Documentation:**
- CLAUDE.md - System Health section updated

---

**Prepared:** 2026-04-05
**Status:** READY FOR DEPLOYMENT
**Priority:** CRITICAL
