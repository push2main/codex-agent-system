# Learnings

## What worked

- Reading the memory and learning files first made the missing approval workflow visible before changing runtime code.
- The dashboard API already exposed enough status and queue data to recover a usable mobile control page with a small UI change.
- Grouping task registry items by status and surfacing one next action makes the backlog easier to triage on mobile.
- Stable task IDs and timestamps make the backlog easier to audit and discuss between runs.
- Reusing the existing queue safety checks for approval handoff keeps project-management controls aligned with runtime behavior.
- Updating task-registry state from the queue loop keeps execution outcomes aligned with backlog status without changing the orchestrator contract.

## What failed

- `codex-memory/tasks.json` was not surfaced anywhere, so planned work was effectively invisible.
- The dashboard HTML had regressed to a placeholder, which removed mobile observability and control.
- The system still cannot approve or audit task state changes from the dashboard, so project management remains partly manual.
- Task records still lack target-project metadata, which weakens planning for multi-project operation.
- The dashboard still lacks task editing, so mistakes in project metadata or task text must be corrected in the file.
- The task board still does not render execution attempt details, so retry and completion context is hidden unless someone reads logs or raw JSON.
