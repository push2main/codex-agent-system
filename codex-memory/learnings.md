# Learnings

## What worked

- Reading the memory and learning files first made the missing approval workflow visible before changing runtime code.
- The dashboard API already exposed enough status and queue data to recover a usable mobile control page with a small UI change.
- Grouping task registry items by status and surfacing one next action makes the backlog easier to triage on mobile.
- Stable task IDs and timestamps make the backlog easier to audit and discuss between runs.
- Reusing the existing queue safety checks for approval handoff keeps project-management controls aligned with runtime behavior.
- Updating task-registry state from the queue loop keeps execution outcomes aligned with backlog status without changing the orchestrator contract.
- Normalizing execution and history data in the task-registry API let the dashboard show attempts, outcomes, and audit notes without changing the queue processor.
- Verifying the dirty worktree before state reconciliation made it safe to recover already-implemented approved tasks instead of replaying stale queue items.
- A deterministic reconciliation pass can backfill manual recovery success records and regenerate metrics without replaying queued work.

## What failed

- `codex-memory/tasks.json` was not surfaced anywhere, so planned work was effectively invisible.
- The dashboard HTML had regressed to a placeholder, which removed mobile observability and control.
- The dashboard still lacks task editing, so mistakes in project metadata or task text must be corrected in the file.
- Approved tasks can remain queued after manual recovery, so queue, registry, and backlog state drift unless all three are reconciled together.
- Manual recovery completions are not written back into `tasks.log`, so aggregate metrics still overrepresent the earlier failure path.
- Dashboard approval and rejection actions still leave `metrics.json` stale until the queue loop or a separate reconciliation pass runs.
