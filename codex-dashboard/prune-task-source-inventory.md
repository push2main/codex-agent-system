# Approved Task Prune Source Inventory

This note documents the current sources and markers that distinguish still-active approved tasks from approved tasks that should already be pruned before board or queue display.

## Live sources

- Registry source: `codex-memory/tasks.json`
- Queue source: `queues/*.txt`
- Queue runner status source: `status.txt`
- Dashboard prune-on-write path: `codex-dashboard/server.js`
- Shell queue reconcile path: `scripts/lib.sh`
- Shell backlog hygiene prune path: `scripts/lib.sh`

Note: the live runtime queue directory is `queues/`, not `codex-queues/`. Both `codex-dashboard/server.js` (`PATHS.queues`) and `scripts/lib.sh` (`QUEUE_DIR`) point there.

## Registry status fields

Observed registry `status` values in `codex-memory/tasks.json`:

- `pending_approval`
- `approved`
- `running`
- `completed`
- `failed`
- `rejected`

Important status handling in current code:

- New dashboard backlog tasks are created as `pending_approval`.
- Only `pending_approval` tasks can transition through the dashboard approval action into `approved`.
- Intake duplicate detection treats `pending_approval`, `approved`, and `running` as actionable duplicates.
- Persistence pruning only mutates tasks whose current `status` is `approved`.
- Pruning converts approved tasks to either `completed` or `rejected`.

## Approval and queue handoff markers

The approval path in `transitionTaskRegistryItem(..., "approve")` writes these markers onto the task:

- `status: "approved"`
- `approved_at`
- `updated_at`
- `execution_provider`
- `execution_brief.approved_at`
- `execution_brief.project`
- `execution_brief.queue_task`
- `execution_brief.queue_status`
- `queue_handoff.at`
- `queue_handoff.project`
- `queue_handoff.task`
- `queue_handoff.status`
- `queue_handoff.provider`
- `queue_handoff.task_intent`
- `task_intent`
- `history[].action = "approve"`
- `history[].from_status = "pending_approval"`
- `history[].to_status = "approved"`

Current `queue_handoff.status` values used by the code paths in `server.js`:

- `queued`: normal approved handoff and the only handoff state the shell reconcile path will requeue
- `already_queued`: approval found the task already queued or running
- `completed`: prune path found completion evidence and downgraded the approved task to completed
- `pruned`: prune path rejected the approved task as superseded or invalid

Queue files under `queues/*.txt` do not store structured markers. Each line is only queue task text, so the handoff linkage back to the registry comes from normalized `(project, queue_handoff.task || execution_task || title)`.

## Execution markers that still count as active work

The queue safety helper in `scripts/lib.sh` treats these as active/executing:

- Registry `status` in `{"approved", "running"}`
- `execution.state` in `{"running", "retrying"}`

The dashboard also preserves these execution fields when present:

- `execution.state`
- `execution.result`
- `execution.attempt`
- `execution.max_retries`
- `execution.updated_at`
- `execution.provider`
- `execution.lane`
- `execution.lease_state`
- `execution.lease_claimed_at`
- `execution.lease_released_at`

Observed active execution markers in the live registry:

- `execution.state: "retrying"` on several approved tasks still visible on the board
- `execution.lease_state: "released"` on the same retrying approved tasks
- `execution.state: "running"` with `execution.lease_state: "claimed"` on currently running tasks

## What the shell reconcile path will enqueue

`reconcile_approved_registry_tasks_to_queue()` in `scripts/lib.sh` only appends a registry task back into `queues/<project>.txt` when all of these are true:

- `status == "approved"`
- `queue_handoff.status` is empty or exactly `queued`
- normalized project resolves from `project`, `target_project`, or `queue_handoff.project`
- queue task text resolves from `queue_handoff.task` or fallback execution text
- normalized `(project, task)` is not already present in any queue file
- normalized `(project, task)` does not match `status.txt` when runtime state is `running`, `retrying`, or `queued`

That means anything changed by prune to `status != "approved"` or `queue_handoff.status = "pruned"` / `completed` stops requeue handoff.

The live queue file currently contains plain-text lines for five approved tasks:

- `Surface per-project health metrics, queue state, and memory summaries`
- `Store acceptance evidence and regression checks for completed work`
- `Retrieve reusable implementation patterns across managed projects without leaking project context`
- `Um die UI zu verbessern, Vergleiche mit anderen tools`
- `Leite davon ein Design ab https://www.proofhub.com/articles/top-project-management-tools-list`

## Implemented evidence for pruning

`completionEvidenceForApprovedTask()` in `server.js` prunes an approved task to `completed` when any of these markers show success already happened:

- `task.completed_at`
- latest `history[].to_status == "completed"`
- `execution.state == "completed"` and `execution.updated_at`
- `execution.result == "SUCCESS"` and `execution.updated_at`
- `execution_context.result == "SUCCESS"` and `task.updated_at`

When this triggers, the task is rewritten with:

- `status: "completed"`
- `completed_at`
- `updated_at`
- `queue_handoff.status: "completed"` when handoff exists
- a `history` entry with `action: "prune"` and `to_status: "completed"`

## Superseded evidence for pruning

`supersedingEvidenceForApprovedTask()` prunes an approved task to `rejected` when another task in the same normalized project has the same normalized execution text and that other task is already:

- `running`, or
- `completed`

The chooser prefers:

- `completed` over `running`
- then the newest `updated_at` / `created_at`

When this triggers, the approved task is rewritten with:

- `status: "rejected"`
- `rejected_at`
- `updated_at`
- `queue_handoff.status: "pruned"` when handoff exists
- a `history` entry with `action: "prune"` and `to_status: "rejected"`

## Invalid evidence for pruning

`invalidEvidenceForApprovedTask()` currently rejects approved tasks as invalid only when:

- queue task text is empty after `execution_task || title`, or
- prompt-intake sourced task title is still a raw instruction blob
- prompt-intake sourced task title still contains a raw URL

The prompt-intake invalidation is gated by `prompt_intake.source` or `task_intent.source` resolving to `dashboard_prompt_intake`.

The raw-instruction blob rule currently requires:

- title length greater than `240`, and
- title starts with `You are`, or contains `---`, `#`, or `*`

`prune_invalid_actionable_registry_tasks()` in `scripts/lib.sh` is a separate backlog-hygiene path. It rejects both `pending_approval` and `approved` tasks, removes matching queue lines from `queues/<project>.txt`, and appends `history` with `action: "reject"` and `to_status: "rejected"`. Its current invalid reasons are broader than the dashboard write-time prune path:

- prompt-intake title longer than `180`
- prompt-intake title still starts with prompt framing like `You are`, `Role:`, `Goal:`, `Core principles`, or `System behavior`
- prompt-intake title still contains prompt-spec formatting or policy text such as `---`, markdown headings, bullet markers, `core principles`, `system behavior`, or `operate under human supervision`
- prompt-intake task is still a generic planning/meta step after a meta prompt
- prompt-intake title still carries numbered-list spillover from the source prompt
- file-creation task title targets a relative artifact path that already exists

Unlike the dashboard prune-on-write path, the shell backlog-hygiene path does not update `queue_handoff.status`; it removes the queue line directly and relies on the registry `status: "rejected"` plus the rejection history note.

Current live approved examples that match the invalid URL rule:

- `task-072-leite-davon-ein-design-ab-https-www-proo`

Current live approved examples that remain active under existing rules:

- `task-064-surface-per-project-health-metrics-and-m`
- `task-069-store-acceptance-evidence-and-regression`
- `task-070-retrieve-reusable-patterns-across-manage`
- `task-071-um-die-ui-zu-verbessern-vergleiche-mit-a`

## Current live queue handoff state

These queue lines align with the currently approved tasks whose `queue_handoff.status` is still `queued`, which is why they remain eligible for `reconcile_approved_registry_tasks_to_queue()` no-op dedupe rather than prune.
