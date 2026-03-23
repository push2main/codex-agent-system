# Learnings

## What worked

- Reading the memory and learning files first made the missing approval workflow visible before changing runtime code.
- Checking `status.txt` and the live system log before editing showed when registry-backed work had finished and exposed that direct dashboard queueing still bypasses the approval path.
- The dashboard API already exposed enough status and queue data to recover a usable mobile control page with a small UI change.
- Grouping task registry items by status and surfacing one next action makes the backlog easier to triage on mobile.
- Stable task IDs and timestamps make the backlog easier to audit and discuss between runs.
- Reusing the existing queue safety checks for approval handoff keeps project-management controls aligned with runtime behavior.
- Updating task-registry state from the queue loop keeps execution outcomes aligned with backlog status without changing the orchestrator contract.
- Normalizing execution and history data in the task-registry API let the dashboard show attempts, outcomes, and audit notes without changing the queue processor.
- Verifying the dirty worktree before state reconciliation made it safe to recover already-implemented approved tasks instead of replaying stale queue items.
- A deterministic reconciliation pass can backfill manual recovery success records and regenerate metrics without replaying queued work.
- Verifying dashboard approval behavior in an isolated temp workspace made it safe to test persisted metric writes without disturbing the live queue processor.
- Refreshing `codex-learning/metrics.json` in the dashboard task-action handler keeps the persisted learning snapshot aligned with approval and rejection changes between queue runs.
- Inspecting the current dashboard render path before proposing more work kept the next UI task specific to the mobile backlog bottleneck instead of adding another generic design request.
- Adding board-level filters and collapsing non-actionable task details improved mobile triage without changing the dashboard API contract.
- Stopping the tmux queue session before reconciling registry state kept the worktree stable long enough to verify approved tasks and remove stale queue entries safely.
- Comparing `project.json` metadata with the runtime workspace helper exposed the project-isolation bug quickly without touching queue execution.
- Classifying 401 auth failures from the raw Codex log let the queue pause new work and let later agent steps fall back immediately instead of spending another full cycle on doomed live requests.
- Reusing the cached auth-failure file in the dashboard API made the queue blocker visible on mobile without changing the queue loop or the approval flow.
- Keeping the auth-block guard in the dashboard transition handler made approvals stop immediately while still allowing pending task edits to stay available on mobile.
- Verifying the edit endpoint through the full system smoke test proved that pending task text and project updates persist into the approval handoff without disturbing the live queue processor.
- Routing legacy `/api/task` submissions into the approval backlog preserved API compatibility while restoring human review and keeping the live queue untouched.

## What failed

- `codex-memory/tasks.json` was not surfaced anywhere, so planned work was effectively invisible.
- The dashboard HTML had regressed to a placeholder, which removed mobile observability and control.
- Approved tasks can remain queued after manual recovery, so queue, registry, and backlog state drift unless all three are reconciled together.
- Manual recovery completions are not written back into `tasks.log`, so aggregate metrics still overrepresent the earlier failure path.
- Queue execution can record a FAILURE for an approved dashboard task in `tasks.log` without demoting the matching registry item, so registry state can stay stale after retries exhaust.
- The task board still has no filter, search, or collapse controls, so reviewing older completed items on an iPhone turns into long scrolling as the registry grows.
- The long-running tmux queue session keeps the shell helpers it sourced at startup, so runtime fixes on disk do not take effect until the session is restarted.
- Non-system projects still default to `projects/<name>` inside the control repo, so managed project work can land in Codex Control state instead of the intended external workspace.
- The dashboard and queue still accept non-system project work without validating an explicit external workspace first, so one approval can still target the wrong repository.
- The dashboard still accepts fresh task submissions while Codex auth is blocked, so backlog can keep growing even after approvals are paused.
- Approved backlog items still reach execution as raw task text, so review quality and runtime determinism still depend on unstructured prompts until server-side task shaping exists.
- Letting malformed prompt-intake spillover tasks reach approval wastes both retry attempts and board capacity, so validation has to happen before `tasks.json` persistence rather than during later backlog cleanup.
- Auto-approving strategy-seeded tasks at creation bypasses the intended human gate and correlates with repeated retry exhaustion, so strategy work should stay in `pending_approval` until an explicit approval action occurs.
- Re-persisting equivalent strategy experiments under new task ids lets the board accumulate duplicate retry-burners like task-001/task-010/task-011 and task-006/task-008, so strategy needs deterministic equivalence checks before writing another task to `codex-memory/tasks.json`.
