# Task Response

Managed project discovery currently has one deterministic dashboard source of truth and several partial project-state conventions around it:

- Source of truth for the live managed-project list: `codex-dashboard/server.js:listProjects()`
  The `/api/projects` response is built from the sorted union of directory names under `projects/` and queue filenames under `queues/*.txt`.
- Queue/runtime representation: `queues/<project>.txt`
  `enqueueTask()` creates `projects/<name>/` and appends to `queues/<name>.txt`, so a queue file can make a project visible even when no metadata has been written.
- Project metadata convention: `projects/<project>/project.json`
  `scripts/lib.sh` defines this as the metadata file via `project_metadata_file()`, but it is only created when shell helpers call `ensure_project_state()`. The dashboard does not read it when building `/api/projects`.
- Project memory convention: `projects/<project>/memory.md`
  `scripts/lib.sh` defines this via `project_memory_file()`, but it is also helper-created and not consulted by `listProjects()`.

Deterministic conclusion:

The single current source of truth for the managed-project list is not `project.json`; it is the dashboard union produced by `listProjects()` from `projects/*` directory names plus `queues/*.txt` filenames. `project.json` and `memory.md` are project-state conventions that may exist for a listed project, but they are not required for that project to appear.

Current gaps between queue, dashboard, and project memory views:

1. Queue-backed visibility without metadata
   `enqueueTask()` always creates `projects/<name>/` and `queues/<name>.txt`, but it does not create `projects/<name>/project.json` or `projects/<name>/memory.md`. A project can therefore appear in `/api/projects` with only a directory and/or queue file.
2. Dashboard ignores task-registry-only projects
   `codex-memory/tasks.json` can contain tasks for a project name, but `/api/projects` does not read the task registry. If a project exists only in task history and has neither a `projects/<name>/` directory nor a queue file, the dashboard list omits it.
3. Dashboard ignores project memory presence
   A listed project may or may not have `projects/<name>/memory.md`; `listProjects()` does not validate or expose whether memory exists.
4. Helper-managed metadata is downstream from discovery
   `ensure_project_state()` can make `project.json` and `memory.md` deterministic once a shell path touches that project, but that helper runs after discovery decisions in the dashboard flow rather than defining the live project list itself.

Practical implication:

Any system behavior that needs one deterministic managed-project list today must use the same union that `listProjects()` uses. If the system later wants metadata-backed project identity, it would need to change discovery so queue files and directories map back to a required persisted project record instead of treating `project.json` as optional.
