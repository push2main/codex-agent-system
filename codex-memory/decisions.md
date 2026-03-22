# Decisions
- 2026-03-22T13:59:32Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=188s
  task: Execute approved registry tasks through the queue processor
  failed_step: Inspect the existing queue processor, task schema, and registry-task approval fields to find the smallest safe dispatch point for approved registry tasks.
  branch: main

- 2026-03-22T14:03:11Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=181s
  task: Add approval controls and audit trail to task board
  failed_step: Inspect the current task board data flow, existing registry-task approval fields, and any queue-processor/task schema code to identify the single source of truth the board should read and write.
  branch: main

- 2026-03-22T14:07:26Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=217s
  task: Track target project metadata for registry tasks
  failed_step: Inspect the existing registry-task source of truth inside `projects/codex-agent-system` first: locate the task schema/persistence model, the registry-task creation path, and any current project identifier fields; record the concrete file paths before editing.
  branch: main

- 2026-03-22T14:15:09Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Show execution attempts and outcomes on the task board
  completed_step: Normalize task-registry execution and history data in the dashboard API, render it on mobile task cards, and reconcile stale approved queue state after verification.
  branch: main

- 2026-03-22T14:16:16Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=197s
  task: Add approval controls and audit trail to task board
  failed_step: Inspect the current task board read/write path, registry-task schema/persistence model, and any existing approval-related fields inside `projects/codex-agent-system`; identify the single source of truth the board must use before editing.
  branch: main
- 2026-03-22T14:21:50Z | project=registry-smoke | result=FAILURE | score=0 | attempts=2 | duration=210s
  task: create hello world script in shell
  failed_step: Inspect `projects/registry-smoke` for an existing script location or naming pattern; if none exists, use a single new file at the project root named `hello.sh` to avoid introducing parallel structure.
  branch: main

- 2026-03-22T14:30:58Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=210s
  task: Record manual recovery outcomes in task logs and metrics
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T14:34:31Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Record manual recovery outcomes in task logs and metrics
  completed_step: Add a deterministic reconciliation pass that backfills manual recovery successes into tasks.log and regenerates codex-learning/metrics.json.
  branch: main

- 2026-03-22T14:30:58Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=210s
  task: Record manual recovery outcomes in task logs and metrics
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T14:35:10Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=209s
  task: Verbessere das UI
  failed_step: Implement the requested change with minimal modifications.
  branch: main
- 2026-03-22T14:39:26Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=213s
  task: Safari Home Screen App. Kann nicht geöffnet werden wegen https-only
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T14:43:37Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=209s
  task: Verbessere das UI
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T14:47:49Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=210s
  task: Refresh learning metrics after dashboard task actions
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T14:51:01Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Refresh learning metrics after dashboard task actions
  completed_step: Persist codex-learning/metrics.json directly from dashboard task actions and verify the approval flow in an isolated dashboard fixture.
  branch: main
- 2026-03-22T14:52:01Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=211s
  task: Safari Home Screen App. Kann nicht geöffnet werden wegen https-only
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T14:56:10Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=208s
  task: Ui wird immer schwieriger zu bedienen je mehr Tasks angelegt werden
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:00:26Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=212s
  task: Refresh learning metrics after dashboard task actions
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:04:39Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=211s
  task: Ui wird immer schwieriger zu bedienen je mehr Tasks angelegt werden
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:08:53Z | project=registry-smoke | result=FAILURE | score=8 | attempts=3 | duration=210s
  task: create hello world script in shell
  branch: main

- 2026-03-22T15:13:09Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=212s
  task: Add mobile backlog filters and collapse completed task details
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:17:29Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=214s
  task: Repair queue-to-registry lifecycle sync for approved tasks
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:19:11Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Add mobile backlog filters and collapse completed task details
  completed_step: Add client-side task-board filters, collapse non-actionable task details by default, and verify the dashboard with lifecycle and smoke tests.
  branch: main

- 2026-03-22T15:19:11Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Repair queue-to-registry lifecycle sync for approved tasks
  completed_step: Verify the on-disk lifecycle sync behavior, reconcile stale approved tasks after stopping the old tmux session, and queue a follow-up task for runtime reload behavior.
  branch: main
- 2026-03-22T15:26:05Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=219s
  task: Projects should be handled outside Codex Control workspace
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:30:26Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=218s
  task: Optimize prompts coming from UI Tasks. Role, Context, precise, effective, doable
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:34:46Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=216s
  task: Projects should be handled outside Codex Control workspace
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:39:06Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=217s
  task: Optimize prompts coming from UI Tasks. Role, Context, precise, effective, doable
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:47:46Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=200s
  task: Reload the queue session after runtime script changes
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:47:52Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=5s
  task: Require explicit external workspaces for managed projects
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:48:02Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=9s
  task: Reload the queue session after runtime script changes
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:48:08Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=3 | duration=5s
  task: Require explicit external workspaces for managed projects
  failed_step: Implement the requested change with minimal modifications.
  branch: main

- 2026-03-22T15:49:35Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Fail fast after Codex auth failures
  completed_step: Detect 401 auth failures in raw Codex logs, cache the failure reason for a short cooldown, pause the queue while auth is unavailable, and skip repeated live calls once fallback mode is active.
  branch: main
- 2026-03-22T16:02:51Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=73s
  task: Surface Codex auth health before queue execution
  failed_step: Inspect the current queue startup path and auth-failure handling to find the earliest deterministic pre-queue hook where Codex health can be checked without changing unrelated flow.
  branch: main

- 2026-03-22T16:05:19Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Surface Codex auth health before queue execution
  completed_step: Expose cached Codex auth failures through the dashboard status, metrics, and task-board next action so operators can see the blocker reason and cooldown before retrying or approving more work.
  branch: main

- 2026-03-22T16:04:33Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=87s
  task: Surface Codex auth health before queue execution
  failed_step: Inspect the queue entrypoint and the existing auth-failure/cooldown code path, then identify the earliest pre-queue hook that already runs before any task dequeue or worker start.
  branch: main
- 2026-03-22T16:11:44Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=94s
  task: Edit pending approval task text and project metadata in the dashboard
  failed_step: Inspect the dashboard code and data source that render the pending approval task text and project metadata, then identify the exact files and fields that drive those values.
  branch: main

- 2026-03-22T16:13:49Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=104s
  task: Pause approval actions while Codex auth is blocked
  failed_step: Inspect the approval-action entrypoints and the existing Codex auth-blocked state source to identify the smallest shared guard that runs before any approve action is executed.
  branch: main

- 2026-03-22T16:15:57Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=112s
  task: Warn when the tmux queue session is running stale runtime scripts
  failed_step: Inspect the queue session startup and status code paths to find the single shared place that knows which tmux session is active and where a warning can be surfaced without changing queue behavior.
  branch: main

- 2026-03-22T16:17:30Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=79s
  task: Edit pending approval task text and project metadata in the dashboard
  failed_step: Inspect the dashboard component, route, and backing data loader/store that render the pending approval task text and project metadata, and identify the exact source fields and files that control those values.
  branch: main

- 2026-03-22T16:19:22Z | project=codex-agent-system | result=FAILURE | score=0 | attempts=2 | duration=98s
  task: Restart the queue session automatically after runtime helper changes
  failed_step: Inspect the queue startup/restart path and the runtime helper files it depends on, then identify the single status source that can tell whether the active tmux queue session was started before the current helper versions.
  branch: main

- 2026-03-22T16:19:40Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Pause approval actions while Codex auth is blocked
  completed_step: Reject dashboard approval transitions while Codex auth is blocked, keep pending task edits available, and verify the behavior in auth-health and system smoke tests.
  branch: main

- 2026-03-22T16:19:40Z | project=codex-agent-system | result=SUCCESS | score=8 | attempts=1 | duration=manual
  task: Edit pending approval task text and project metadata in the dashboard
  completed_step: Add inline pending-task editing in the dashboard, persist audited task-registry updates, and verify the edited queue handoff in the system smoke test.
  branch: main
