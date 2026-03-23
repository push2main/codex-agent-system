# Completed Task Evidence Spec

This note defines the smallest deterministic JSON shape for storing acceptance evidence and regression checks for completed tasks only.

## Write target

- Durable file: `codex-memory/tasks.json`
- Durable object: `task.execution_context`
- Write condition: only when `task.status == "completed"` and `execution_context.result == "SUCCESS"`
- Non-targets: `codex-memory/tasks.log`, `failure_context`, queue files, and non-completed task states

## Exact fields

Add these two fields under `execution_context` for completed tasks only:

```json
{
  "acceptance_evidence": [
    {
      "summary": "",
      "files": [],
      "checks": []
    }
  ],
  "regression_checks": [
    {
      "status": "not_run",
      "commands": [],
      "notes": []
    }
  ]
}
```

## Stable key rules

`execution_context.acceptance_evidence`

- Field type: array
- Deterministic shape: either `[]` or a single object entry with these stable keys:
- `summary`: string
- `files`: array of strings
- `checks`: array of strings

`execution_context.regression_checks`

- Field type: array
- Deterministic shape: either `[]` or a single object entry with these stable keys:
- `status`: string constrained to `not_run`, `passed`, or `failed`
- `commands`: array of strings
- `notes`: array of strings

All values remain JSON-only scalars, arrays, or objects. No multiline shell blobs, no mixed-type arrays, and no timestamp-derived dynamic keys. The array wrapper is part of the current writer contract and must remain stable unless the writer and every reader are updated together.

## Write and read map

- `agents/orchestrator.sh`
  - `finalize_run()` remains the completion gate.
  - It does not write the new fields directly; it continues to call `persist_task_run_context(...)` only after the final task result is known.
- `scripts/lib.sh`
  - `persist_task_run_context()` is the only writer for the new fields in `codex-memory/tasks.json`.
  - On `SUCCESS`, it currently preserves and writes `execution_context.acceptance_evidence` and `execution_context.regression_checks` through `normalize_json_array(...)`, so both fields must stay array-shaped in the persisted record.
  - On non-success results, it does not add either field and continues writing `failure_context` exactly as today.
- `codex-dashboard/server.js`
  - `readTaskRegistryPayload()` and the task-registry normalization path continue to read `execution_context` as a plain object.
  - The new fields are therefore available to API consumers via the existing `execution_context` pass-through as arrays without changing unrelated task-state handling.

## Isolation rules

- `pending_approval`, `approved`, `running`, `retrying`, `failed`, and `rejected` records do not gain these fields.
- Existing completion fields stay unchanged: `status`, `completed_at`, `execution.state`, `execution.result`, `execution.updated_at`, and existing `execution_context` keys remain in place.
- `codex-memory/tasks.log` stays append-only and unchanged so historical log readers are not affected.
