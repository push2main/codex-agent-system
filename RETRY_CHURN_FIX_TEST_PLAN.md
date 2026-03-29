# Retry Churn Fix - Test Plan

## Overview
This test plan validates that the cumulative_attempts tracking correctly prevents infinite retry loops from repeated task re-approvals while maintaining legitimate retry functionality.

## Test Environment Setup

### Files Modified
- `scripts/lib.sh` - Task registry state synchronization
- `scripts/queue-worker.sh` - Retry exhaustion check
- `agents/orchestrator.sh` - (No changes, but validates flow)

### Validation Performed
```bash
bash -n /sessions/intelligent-relaxed-lamport/mnt/codex-agent-system/scripts/lib.sh      # ✓ PASS
bash -n /sessions/intelligent-relaxed-lamport/mnt/codex-agent-system/scripts/queue-worker.sh  # ✓ PASS
bash -n /sessions/intelligent-relaxed-lamport/mnt/codex-agent-system/agents/orchestrator.sh   # ✓ PASS
```

## Unit Test Scenarios

### Test 1: Initial Task Failure and Requeue
**Scenario**: Task fails on first attempt
**Expected Behavior**:
- `execution.attempt` = 1
- `cumulative_attempts` = 1
- Task requeued (status → "approved")
- `get_task_retry_count()` returns 1

**Verification**:
```bash
# Monitor task registry for cumulative_attempts field
jq '.tasks[] | select(.id == "TASK_ID") | .cumulative_attempts' $TASK_REGISTRY_FILE
# Should output: 1
```

### Test 2: Manual Re-approval After Failure
**Scenario**: Human reviewer re-approves a failed task
**Expected Behavior**:
- Task transitions: "failed" → "approved"
- `cumulative_attempts` is preserved (NOT reset)
- `execution.attempt` may be 0 or current attempt number
- Next failure can requeue up to cumulative_retry_limit

**Verification**:
```bash
# Before re-approval
cumulative_before=$(jq '.tasks[] | select(.id == "TASK_ID") | .cumulative_attempts' $TASK_REGISTRY_FILE)

# After re-approval (manual action)
cumulative_after=$(jq '.tasks[] | select(.id == "TASK_ID") | .cumulative_attempts' $TASK_REGISTRY_FILE)

# Should be equal
test "$cumulative_before" = "$cumulative_after"
```

### Test 3: Cumulative Retry Limit Enforcement
**Scenario**: Task fails multiple times with human re-approvals
**Expected Behavior**:
- cumulative_retry_limit = MAX_AGENT_RETRIES * 2 (default: 4)
- Allows requeue while cumulative_attempts < 4
- Blocks requeue when cumulative_attempts >= 4
- Marks task as "retry_exhausted"

**Test Case A**: cumulative_attempts = 3, attempt to requeue
- Expected: ALLOW (3 < 4)
- Check queue-worker log: "cumulative=3/4"

**Test Case B**: cumulative_attempts = 4, attempt to requeue
- Expected: BLOCK (4 >= 4)
- Check queue-worker log: "Retry exhausted ... cumulative_attempts=4 >= limit=4"
- Task status: "failed"
- Task.execution.result: "FAILURE"

### Test 4: Complete Failure Scenario (Before Fix Simulation)
**Scenario**: task-127 reaches attempt=5 via multiple re-approvals
**Expected Behavior (After Fix)**:
1. Initial failure: cumulative=1 → requeue ✓
2. Re-approved: cumulative=1 (preserved) ✓
3. Fails again: cumulative=2 → requeue ✓
4. Re-approved: cumulative=2 (preserved) ✓
5. Fails again: cumulative=3 → requeue ✓
6. Re-approved: cumulative=3 (preserved) ✓
7. Fails again: cumulative=4 → **BLOCK** ✗
8. Status: "failed" with "retry_exhausted" classification

**Verification**:
```bash
# Check final state in task registry
jq '.tasks[] | select(.id == "task-127") | {status, cumulative_attempts, execution: {attempt, state}}' $TASK_REGISTRY_FILE
# Expected output:
# {
#   "status": "failed",
#   "cumulative_attempts": 4,
#   "execution": {
#     "attempt": 4,
#     "state": "failed"
#   }
# }
```

## Integration Test Scenarios

### Test 5: Queue Worker Retry Budget Check
**Scenario**: Multiple tasks failing and requeuing
**Expected Behavior**:
- Each requeue increments `next_retry` and updates cumulative_attempts
- Queue worker checks both `next_retry < MAX_AGENT_RETRIES` AND `cumulative_attempts < cumulative_retry_limit`
- Short-circuit prevents requeue if either condition fails

**Log Format**:
```
Requeued task on LANE_ID for PROJECT after failure (retry=1/1 cumulative=1/4)
Requeued task on LANE_ID for PROJECT after failure (retry=1/1 cumulative=2/4)
Requeued task on LANE_ID for PROJECT after failure (retry=1/1 cumulative=3/4)
Retry exhausted on LANE_ID for PROJECT: cumulative_attempts=4 >= limit=4
```

### Test 6: Success Path Resets Retries
**Scenario**: Task fails, requeued, then succeeds
**Expected Behavior**:
- `clear_task_retry_count()` called on success
- Retry count file cleared
- Task status: "completed"
- cumulative_attempts preserved in registry (for audit trail)

**Verification**:
```bash
# Retry count should be cleared
[ ! -f "$QUEUE_RETRY_DIR/$(task_retry_key_from_identity ...)" ] && echo "Cleared"

# Task should show completed status
jq '.tasks[] | select(.id == "TASK_ID") | .status' $TASK_REGISTRY_FILE
# Expected: "completed"
```

### Test 7: Non-Retriable Failure Path
**Scenario**: Orchestrator detects non-retriable failure (exit code 3)
**Expected Behavior**:
- Queue worker receives exit code 3
- Skips retry budget check
- Directly transitions to "failed" status
- Logs "Non-retriable failure"
- Does not increment cumulative_attempts via requeue

**Verification**:
```bash
# Check queue worker logs
grep "Non-retriable failure (exit=3)" $QUEUE_WORKER_LOG

# Task should be immediately failed
jq '.tasks[] | select(.id == "TASK_ID") | {status, execution: {attempt}}' $TASK_REGISTRY_FILE
# Expected: status="failed", attempt=0 or current
```

## Edge Cases

### Edge Case 1: Backward Compatibility
**Scenario**: Task registry contains legacy task without cumulative_attempts field
**Expected Behavior**:
- `task.get("cumulative_attempts") or 0` defaults to 0
- Code compares with `execution.get("attempt")` to find maximum
- No errors or missing data

**Verification**:
```python
# In sync_task_registry_execution_state
cumulative_attempts_prior = max(
    int(task.get("cumulative_attempts") or 0),      # Handles missing field
    int(execution.get("attempt") or 0),
    0
)
# Should work for both old and new tasks
```

### Edge Case 2: Concurrent Re-approvals
**Scenario**: Multiple users re-approve same task
**Expected Behavior**:
- Last approval wins (atomic file write)
- cumulative_attempts from task registry is preserved
- No race condition increases cumulative_attempts incorrectly

**Verification**: N/A (relies on atomic JSON write, already tested in codebase)

### Edge Case 3: MAX_AGENT_RETRIES Variation
**Scenario**: Site uses non-default MAX_AGENT_RETRIES value
**Expected Behavior**:
- cumulative_retry_limit = MAX_AGENT_RETRIES * 2
- If MAX_AGENT_RETRIES=3 → limit=6
- If MAX_AGENT_RETRIES=1 → limit=2

**Verification**:
```bash
MAX_AGENT_RETRIES=3
cumulative_retry_limit=$((MAX_AGENT_RETRIES * 2))
[ "$cumulative_retry_limit" = "6" ] && echo "Correct"
```

## Monitoring and Observability

### Metrics to Track
1. **Retry Distribution**
   - Tasks requeued at retry=0: count
   - Tasks requeued at retry=1: count
   - Tasks exhausted before limit: count

2. **Cumulative Attempts Distribution**
   - Histogram of cumulative_attempts values
   - Max cumulative_attempts observed
   - Tasks exceeding limit (should be rare)

3. **Re-approval Frequency**
   - Manual re-approvals per day
   - Re-approval to next failure ratio (ideal: low)

### Log Monitoring
```bash
# Monitor for retry exhaustion
grep "Retry exhausted" /path/to/queue-worker.log

# Monitor cumulative tracking
grep "cumulative=" /path/to/queue-worker.log | tail -20

# Alert if cumulative > 2 for repeated task
grep "cumulative=[34]" /path/to/queue-worker.log
```

## Success Criteria

✅ All tests pass without errors
✅ Shell scripts validate with `bash -n`
✅ Cumulative attempts preserved across re-approvals
✅ Retry limit enforced after cumulative_attempts >= 4
✅ Non-retriable failures bypass retry logic
✅ Backward compatible with tasks lacking cumulative_attempts
✅ No infinite retry loops (main objective)
✅ Log messages include cumulative attempt counters

## Regression Testing

### Pre-Deployment Checklist
- [ ] Run full test suite on modified scripts
- [ ] Test with representative task dataset (100+ tasks)
- [ ] Verify no tasks stuck in "approved" → "failed" → "approved" cycle
- [ ] Monitor retry rate for 24 hours
- [ ] Check for memory leaks or file handle issues
- [ ] Validate task registry file size (should not grow unexpectedly)

### Post-Deployment Validation
- [ ] Monitor retry exhaustion alerts for false positives
- [ ] Verify successful tasks complete normally
- [ ] Check re-approved tasks complete on next attempt or exhaust properly
- [ ] No new "unknown" failures introduced
- [ ] Performance metrics stable (no slowdown)

## Rollback Plan

If issues are detected:
1. Revert changes to `scripts/lib.sh` and `scripts/queue-worker.sh`
2. Clear cumulative_attempts fields from affected tasks (optional)
3. Restart queue workers
4. Tasks will fall back to simple attempt counting (may have retries enabled again)

## Documentation Updates

- [ ] Update CLAUDE.md with new cumulative_attempts field
- [ ] Add to project.json schema if applicable
- [ ] Document in developer guide: "How Retry Churn Prevention Works"
- [ ] Update incident classification system to recognize "retry_exhausted"
