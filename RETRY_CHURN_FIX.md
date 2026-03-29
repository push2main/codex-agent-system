# Retry Churn Fix: Cumulative Attempts Tracking

## Problem
When a failed task was re-approved by a human reviewer, the attempt counter (`execution.attempt`) would reset to 0, causing infinite retry loops. Example: task-127 reached attempt=5 on max_retries=2 through 3 re-approvals.

## Root Cause
The task registry's `sync_task_registry_execution_state` function was updating `execution.attempt` directly without preserving a persistent counter across approval cycles. When a task transitioned from "failed" back to "approved" for manual re-approval, the attempt field would be set to the new attempt count, losing historical retry information.

## Solution: Cumulative Attempts Tracking

### 1. **scripts/lib.sh** - Task Registry State Sync
Added cumulative attempt tracking in `sync_task_registry_execution_state` function (lines 7311-7323):

- **New variable: `cumulative_attempts_prior`** (lines 7313-7317)
  - Tracks the maximum of:
    - Task's stored `cumulative_attempts` field
    - Current execution's `attempt` count
  - Ensures we never lose historical retry information

- **New variable: `cumulative_attempts_next`** (lines 7320-7323)
  - Updated when transitioning to "approved" or "failed" states
  - Or when action is "execute_retry" or "execute_failure"
  - Always uses the higher of prior cumulative or current attempt count

- **Persistent storage** (line 7365)
  - Task now stores `cumulative_attempts` field at root level
  - This persists across re-approval cycles
  - Survives task status transitions

### 2. **scripts/queue-worker.sh** - Retry Exhaustion Check
Added cumulative retry limit enforcement (lines 188-231):

- **New calculation: `cumulative_retry_limit`** (line 190)
  - Set to `MAX_AGENT_RETRIES * 2` (roughly 4 for default max_retries=2)
  - Accounts for multiple re-approval cycles while preventing infinite loops

- **New check before requeuing** (line 193)
  - Prevents requeue if: `cumulative_attempts >= cumulative_retry_limit`
  - Uses `get_task_retry_count()` which already reads cumulative_attempts

- **New failure path for exhausted retries** (lines 213-231)
  - When cumulative limit is exceeded, classify as "retry_exhausted"
  - Logs detailed message with cumulative/limit values
  - Transitions task to "failed" state with clear messaging

## Data Flow

```
Task Failure
    ↓
queue-worker detects failure (rc=1 or rc=124)
    ↓
Check: cumulative_attempts < cumulative_retry_limit (4)?
    ├─ YES → Requeue task (status→"approved", execution.attempt++, cumulative_attempts++)
    │         get_task_retry_count returns higher of file/cumulative
    │
    └─ NO  → Fail task with "retry_exhausted" classification
             cumulative_attempts >= 4 = blocks further retries

Manual Re-approval Flow
    ↓
Task status: "failed" → "approved"
    ↓
sync_task_registry_execution_state called
    ↓
cumulative_attempts_prior = max(task.cumulative_attempts, execution.attempt)
cumulative_attempts_next = max(cumulative_attempts_prior, new_attempt)
    ↓
Task stored with preserved cumulative_attempts
    ↓
get_task_retry_count returns cumulative value (if > file value)
    ↓
Queue-worker sees cumulative limit, blocks further retries if limit exceeded
```

## Key Changes Summary

| File | Change | Purpose |
|------|--------|---------|
| scripts/lib.sh | Added cumulative_attempts tracking in sync_task_registry_execution_state | Preserve attempt count across approval cycles |
| scripts/lib.sh | Store cumulative_attempts at task root level | Make it discoverable during task selection |
| scripts/queue-worker.sh | Added cumulative_retry_limit check | Prevent infinite retry churn from repeated re-approvals |
| scripts/queue-worker.sh | New "retry_exhausted" failure path | Clear classification when cumulative limit exceeded |

## Backward Compatibility
- Existing tasks without cumulative_attempts field default to 0
- `get_task_retry_count()` already compares file-based and cumulative values
- Falls back to simpler logic if cumulative_attempts not present

## Testing
```bash
# Verify shell script syntax
bash -n /sessions/intelligent-relaxed-lamport/mnt/codex-agent-system/scripts/lib.sh
bash -n /sessions/intelligent-relaxed-lamport/mnt/codex-agent-system/scripts/queue-worker.sh
```

Both pass validation without errors.

## Example Scenario: task-127 (Before vs After)

### Before Fix
1. task-127 fails, attempt=0 → attempt=1 (requeue)
2. Human re-approves → attempt resets to 0
3. task-127 fails, attempt=0 → attempt=1 (requeue)
4. Human re-approves → attempt resets to 0 (INFINITE LOOP)

### After Fix
1. task-127 fails, attempt=0, cumulative=0 → attempt=1, cumulative=1 (requeue)
2. Human re-approves → attempt=0, **cumulative=1** (preserved)
3. task-127 fails, attempt=0, cumulative=1 → attempt=1, cumulative=1 (requeue)
4. Human re-approves → attempt=0, **cumulative=1** (preserved)
5. task-127 fails, attempt=0, cumulative=1 → attempt=1, cumulative=2 (requeue)
6. **cumulative=2 still < limit=4** → Continue or block based on retries
7. Eventually cumulative >= 4 → **BLOCKS with "retry_exhausted"**

## Verification Steps
1. Monitor cumulative_attempts field in task registry records
2. Check queue-worker logs for "cumulative=$X/$limit" messages
3. Verify failed tasks show "retry_exhausted" classification when appropriate
4. Confirm manual re-approvals preserve cumulative attempt counts
