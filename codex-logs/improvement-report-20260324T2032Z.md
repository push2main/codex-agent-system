# System Improvement Report — 2026-03-24T20:32Z

## 1. Identified Weakness: Chronic Task Failure Loop (88% failure rate)

The system has a **273 failure / 37 success** ratio in `decisions.md` — an 88% failure rate. The task registry shows 81 failed out of 117 tasks (69%). The same tasks fail repeatedly:

- "Tighten the mobile dashboard into an enterprise control surface" — **17 failures**
- "Persist structured failure context for strategy follow-ups" — **14 failures**
- "Detect low first-pass success before repeated retries dominate the board" — **11 failures**
- "Keep an executable system-work buffer when the queue drains" — **9 failures**

The coder agent consistently fails with exit code 1 or times out at 90s. Strategy then generates replacement/follow-up tasks that also fail, creating a cascading failure loop that consumes all queue capacity.

The system's own learnings already acknowledge this: *"Re-persisting equivalent strategy experiments under new task ids lets the board accumulate duplicate retry-burners"* and *"Auto-approving strategy-seeded tasks bypasses the intended human gate and correlates with repeated retry exhaustion."*

## 2. Improvement Proposed: Failure-Count Task Demotion

**Problem**: Once a task fails 2 queue retries, the strategy loop generates a follow-up with a new ID. That follow-up also fails, generating yet another follow-up. There is no hard ceiling on how many times the same underlying goal can be re-attempted under different task IDs.

**Proposed change** (small, safe, reversible): Add a `root_failure_count` check to the strategy seeding path in `codex-dashboard/server.js`. Before creating a new follow-up experiment from a failed task:

1. Count how many tasks in `tasks.json` share the same `root_source_task_id` and have `status: "failed"`.
2. If that count exceeds **3**, mark the root goal as `shelved` instead of seeding another follow-up.
3. Log the shelving decision to `codex-memory/decisions.md`.

This prevents the board from accumulating unbounded retry-burners while still allowing 3 genuine attempts at each root goal.

**Why this is safe**: It only prevents *new* task creation; it does not modify any running task, queue entry, or existing code path. The shelved state is reversible — a human can un-shelve via the dashboard.

## 3. Outcome: Not yet executed

This is proposed only. The system is currently running a task (`status.txt` shows `state=running`) and modifying the strategy seeding path while it's active would be unsafe.

## 4. Knowledge Gained

- The coder agent's primary failure mode is exit code 1 on complex multi-file edits, especially when the task description references code paths the coder can't locate within its timeout window.
- The strategy loop's saturation recovery correctly *detects* the problem but its response (generate a replacement experiment) perpetuates it.
- The learned rules in `codex-learning/rules.md` are narrow (focused on naming/template changes) and don't address the structural issue of unbounded retry cascading.
- Successful tasks tend to be simpler, more concrete, and focused on a single file change.

## 5. Next Best Improvement

After implementing root-failure-count demotion, the next highest-impact improvement would be **task complexity scoring at planning time**: before the planner generates steps, estimate the task's complexity (number of files to edit, code path depth, dependency count) and reject tasks that exceed the coder agent's demonstrated capability envelope. This would prevent wasted cycles at the source rather than after multiple failed attempts.
