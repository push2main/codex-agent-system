#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap compact-registry

REGISTRY_FILE="${TASK_REGISTRY_FILE:-$MEMORY_DIR/tasks.json}"
ARCHIVE_FILE="$MEMORY_DIR/tasks-archive.json"
PRESSURE_THRESHOLD_BYTES=250000

compact_task_registry() {
  local current_bytes
  current_bytes="$(wc -c < "$REGISTRY_FILE" 2>/dev/null || printf '0')"

  if [ "$current_bytes" -le "$PRESSURE_THRESHOLD_BYTES" ]; then
    log_msg INFO compact-registry "Registry size ${current_bytes}B is below threshold ${PRESSURE_THRESHOLD_BYTES}B — no compaction needed"
    return 0
  fi

  log_msg INFO compact-registry "Registry pressure detected: ${current_bytes}B > ${PRESSURE_THRESHOLD_BYTES}B — compacting..."

  python3 - "$REGISTRY_FILE" "$ARCHIVE_FILE" "$PRESSURE_THRESHOLD_BYTES" <<'PY'
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path


registry_path = Path(sys.argv[1])
archive_path = Path(sys.argv[2])
threshold = int(sys.argv[3])

try:
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"ERROR: Failed to read registry: {e}", file=sys.stderr)
    raise SystemExit(1)

tasks = registry.get("tasks", [])
if not isinstance(tasks, list):
    print("ERROR: tasks field is not a list", file=sys.stderr)
    raise SystemExit(1)

original_count = len(tasks)


def normalize_text(value: object) -> str:
    return " ".join(str(value or "").strip().lower().split())


def normalize_project(value: object) -> str:
    return normalize_text(value) or "codex-agent-system"


def task_identity(task: dict) -> tuple[str, str, str]:
    project = normalize_project(task.get("project") or task.get("target_project"))
    task_key = normalize_text(task.get("id"))
    if not task_key:
        task_key = normalize_text(task.get("title") or task.get("execution_task") or task.get("task"))
    status = normalize_text(task.get("status"))
    return project, task_key, status


def task_timestamp(task: dict) -> str:
    for field in (
        "updated_at",
        "completed_at",
        "failed_at",
        "shelved_at",
        "last_retry_at",
        "last_started_at",
        "approved_at",
        "started_at",
        "created_at",
    ):
        value = str(task.get(field) or "").strip()
        if value:
            return value
    return ""


def task_richness(task: dict) -> int:
    score = 0
    for key, value in task.items():
        if value in (None, "", [], {}):
            continue
        score += 1
        if key == "history" and isinstance(value, list):
            score += len(value) * 4
        elif isinstance(value, dict):
            score += len(value) * 2
        elif isinstance(value, list):
            score += len(value)
    return score


def task_signature(task: dict) -> str:
    return json.dumps(task, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def prefer_task(existing: dict, candidate: dict) -> dict:
    existing_rank = (
        task_richness(existing),
        task_timestamp(existing),
        len(task_signature(existing)),
        task_signature(existing),
    )
    candidate_rank = (
        task_richness(candidate),
        task_timestamp(candidate),
        len(task_signature(candidate)),
        task_signature(candidate),
    )
    return candidate if candidate_rank > existing_rank else existing


deduped_tasks: list[dict] = []
dedupe_index: dict[tuple[str, str, str], int] = {}
duplicates_removed = 0
for task in tasks:
    if not isinstance(task, dict):
        continue
    identity = task_identity(task)
    if not identity[1]:
        deduped_tasks.append(task)
        continue
    existing_index = dedupe_index.get(identity)
    if existing_index is None:
        dedupe_index[identity] = len(deduped_tasks)
        deduped_tasks.append(task)
        continue
    deduped_tasks[existing_index] = prefer_task(deduped_tasks[existing_index], task)
    duplicates_removed += 1

tasks = deduped_tasks

# Auto-shelve stuck tasks: approved/queued tasks with many attempts or
# tasks with non-retriable failure classifications that were never properly shelved
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
STALE_HOURS = 12  # tasks approved/queued for >12 hours are stale
MAX_STUCK_ATTEMPTS = 3  # tasks with 3+ failed attempts are stuck
mutated_tasks = 0

for t in tasks:
    status = str(t.get("status", "")).strip().lower()
    exec_info = t.get("execution", {})
    attempts = exec_info.get("attempt", t.get("attempts", 0))
    updated_str = t.get("updated_at") or t.get("created_at") or ""

    # Auto-shelve approved/queued tasks that are stale
    if status in ("approved", "queued"):
        try:
            updated = datetime.fromisoformat(updated_str.replace("Z", "+00:00"))
            if (now - updated) > timedelta(hours=STALE_HOURS):
                t["status"] = "shelved"
                t["shelved_reason"] = f"auto-shelved: stale {status} for >{STALE_HOURS}h"
                mutated_tasks += 1
                continue
        except Exception:
            pass

    # Auto-shelve tasks that are stuck in approved with many past failed attempts
    if status in ("approved", "running") and attempts >= MAX_STUCK_ATTEMPTS:
        t["status"] = "shelved"
        t["shelved_reason"] = f"auto-shelved: {attempts} failed attempts"
        mutated_tasks += 1

# Partition tasks by status
active_statuses = {"running", "approved", "pending_approval", "queued"}
active = [t for t in tasks if str(t.get("status", "")).strip().lower() in active_statuses]

terminal = [
    t for t in tasks
    if str(t.get("status", "")).strip().lower() not in active_statuses
]

# Sort terminal tasks by most recent first
terminal.sort(
    key=lambda t: str(t.get("updated_at") or t.get("created_at") or ""),
    reverse=True,
)

# Keep only 5 terminal tasks in registry — aggressive compaction to stay under pressure threshold
keep_terminal = terminal[:5]
archive_terminal = terminal[5:]

# Read existing archive
existing_archive: list[dict] = []
if archive_path.exists():
    try:
        existing_archive = json.loads(archive_path.read_text(encoding="utf-8"))
        if not isinstance(existing_archive, list):
            existing_archive = []
    except Exception:
        existing_archive = []

# Strip verbose fields from archived tasks to save space
slim_fields_to_remove = [
    "queue_handoff", "provider_selection", "task_intent",
    "related_source_task_ids", "execution",
]
for t in archive_terminal:
    for field in slim_fields_to_remove:
        t.pop(field, None)

if archive_terminal:
    # Append to archive atomically
    existing_archive.extend(archive_terminal)
    archive_tmp_fd, archive_tmp_path = tempfile.mkstemp(
        dir=str(archive_path.parent), suffix=".tmp"
    )
    try:
        with os.fdopen(archive_tmp_fd, "w") as f:
            json.dump(existing_archive, f, indent=2)
            f.write("\n")
        os.replace(archive_tmp_path, str(archive_path))
    except Exception:
        try:
            os.unlink(archive_tmp_path)
        except OSError:
            pass
        raise

if not archive_terminal and duplicates_removed == 0 and mutated_tasks == 0:
    print(f"INFO: Only {len(terminal)} terminal tasks — nothing to archive")
    raise SystemExit(0)

# Update registry atomically
registry["tasks"] = active + keep_terminal
registry_tmp_fd, registry_tmp_path = tempfile.mkstemp(
    dir=str(registry_path.parent), suffix=".tmp"
)
try:
    with os.fdopen(registry_tmp_fd, "w") as f:
        json.dump(registry, f, indent=2)
        f.write("\n")
    os.replace(registry_tmp_path, str(registry_path))
except Exception:
    try:
        os.unlink(registry_tmp_path)
    except OSError:
        pass
    raise

new_bytes = registry_path.stat().st_size
print(
    f"Compacted: {original_count} → {len(active) + len(keep_terminal)} tasks "
    f"(deduped {duplicates_removed}, archived {len(archive_terminal)}, {new_bytes}B new size)"
)
PY

  local new_size
  new_size="$(wc -c < "$REGISTRY_FILE" 2>/dev/null || printf '0')"
  log_msg INFO compact-registry "Compaction complete. New registry size: ${new_size}B"
}

# Run compaction on main registry
compact_task_registry

# ─── Per-project compaction: compact external project registries that cause pressure ───
# The main metrics.json tracks per-project pressure sources. Superheld alone was 982KB.
# Compact each external project registry that exceeds the threshold.
compact_external_project_registries() {
  local metrics_file="${LEARNING_DIR}/metrics.json"
  [ -f "$metrics_file" ] || return 0

  python3 - "$metrics_file" "$PRESSURE_THRESHOLD_BYTES" "$REGISTRY_FILE" <<'PYEXT'
import json, os, sys, tempfile
from pathlib import Path

metrics_file = Path(sys.argv[1])
threshold = int(sys.argv[2])
primary_registry = Path(sys.argv[3]).resolve()

try:
    metrics = json.loads(metrics_file.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

sources = metrics.get("task_registry_pressure_sources", [])
for source in sources:
    file_path = Path(source.get("file", ""))
    payload_bytes = source.get("payload_bytes", 0)
    project = source.get("project", "unknown")

    if payload_bytes <= threshold:
        continue
    if not file_path.exists():
        continue
    try:
        resolved_file_path = file_path.resolve()
    except OSError:
        continue
    if resolved_file_path == primary_registry:
        continue

    print(f"Compacting external project registry: {project} ({payload_bytes}B > {threshold}B)")

    try:
        registry = json.loads(file_path.read_text(encoding="utf-8"))
    except Exception:
        continue

    tasks = registry.get("tasks", [])
    if not isinstance(tasks, list):
        continue

    original_count = len(tasks)

    # Active tasks to keep
    active_statuses = {"running", "approved", "pending_approval", "queued"}
    active = [t for t in tasks if str(t.get("status", "")).strip().lower() in active_statuses]
    terminal = [t for t in tasks if str(t.get("status", "")).strip().lower() not in active_statuses]

    # Sort terminal by recency, keep only 5
    terminal.sort(key=lambda t: str(t.get("updated_at") or t.get("created_at") or ""), reverse=True)
    keep_terminal = terminal[:5]
    archive_terminal = terminal[5:]

    if not archive_terminal:
        continue

    # Strip verbose fields from kept tasks to reduce size further
    slim_fields = ["queue_handoff", "provider_selection", "task_intent", "related_source_task_ids",
                   "execution_brief", "approval_execution_brief", "task_shape"]
    for t in keep_terminal + active:
        # Trim history to last 3 entries
        history = t.get("history", [])
        if isinstance(history, list) and len(history) > 3:
            t["history"] = history[-3:]
            t["history_trimmed"] = True

    # Archive to sibling file
    archive_path = file_path.parent / "tasks-archive.json"
    existing_archive = []
    if archive_path.exists():
        try:
            existing_archive = json.loads(archive_path.read_text(encoding="utf-8"))
            if not isinstance(existing_archive, list):
                existing_archive = []
        except Exception:
            existing_archive = []

    for t in archive_terminal:
        for field in slim_fields + ["execution", "history"]:
            t.pop(field, None)

    existing_archive.extend(archive_terminal)
    registry["tasks"] = active + keep_terminal

    try:
        with tempfile.NamedTemporaryFile("w", delete=False, dir=str(archive_path.parent), encoding="utf-8") as handle:
            json.dump(existing_archive, handle, indent=2)
            handle.write("\n")
            archive_tmp_path = handle.name
        os.replace(archive_tmp_path, archive_path)

        with tempfile.NamedTemporaryFile("w", delete=False, dir=str(file_path.parent), encoding="utf-8") as handle:
            json.dump(registry, handle, indent=2)
            handle.write("\n")
            registry_tmp_path = handle.name
        os.replace(registry_tmp_path, file_path)
    except OSError as exc:
        for candidate in ("archive_tmp_path", "registry_tmp_path"):
            temp_path = locals().get(candidate)
            if temp_path:
                try:
                    os.unlink(temp_path)
                except OSError:
                    pass
        print(f"  skipped {project}: {exc}")
        continue

    new_bytes = file_path.stat().st_size
    print(f"  {project}: {original_count} → {len(active) + len(keep_terminal)} tasks, "
          f"archived {len(archive_terminal)}, new size {new_bytes}B")
PYEXT
}

compact_external_project_registries

# After compaction, refresh metrics so self-improve and strategy-loop
# see accurate registry pressure, task counts, and saturation signals.
# Without this, stale metrics block the learning loop after compaction.
refresh_post_compaction_metrics() {
  local metrics_file="${LEARNING_DIR}/metrics.json"
  local task_log="${MEMORY_DIR}/tasks.log"
  local signals_file="${EXTERNAL_SIGNALS_FILE:-$LEARNING_DIR/external-signals.json}"

  if [ -f "$ROOT_DIR/scripts/sync-task-artifacts.py" ] && [ -f "$ROOT_DIR/scripts/task_metrics.py" ]; then
    log_msg INFO compact-registry "Refreshing metrics after compaction..."
    PYTHONPATH="$ROOT_DIR/scripts" python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" \
      "$REGISTRY_FILE" "$task_log" "$metrics_file" "$signals_file" 2>/dev/null \
      && log_msg INFO compact-registry "Metrics refreshed successfully" \
      || log_msg WARN compact-registry "Metrics refresh failed (non-fatal)"
  fi
}

refresh_post_compaction_metrics
