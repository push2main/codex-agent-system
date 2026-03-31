#!/usr/bin/env python3
"""Re-enqueue approved project-local tasks when their live queue entry disappears.

Usage: python3 scripts/strategy-approved-queue-sync.py REGISTRY_FILE PROJECT_NAME [STATUS_FILE]
"""

from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
QUEUE_DIR = REPO_ROOT / "queues"


def normalize_text(value: Any) -> str:
    return " ".join(str(value or "").strip().lower().split())


def normalize_project(value: Any) -> str:
    raw = str(value or "").strip().lower()
    collapsed = "".join(ch if ch.isalnum() or ch in "_-" else "-" for ch in raw)
    return "-".join(part for part in collapsed.split("-") if part)


def normalize_provider(value: Any) -> str:
    provider = normalize_text(value)
    return provider if provider in {"codex", "claude"} else ""


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=path.parent, encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


def task_execution_text(task: dict[str, Any]) -> str:
    execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {}
    queue_handoff = task.get("queue_handoff") if isinstance(task.get("queue_handoff"), dict) else {}
    return str(
        execution_brief.get("queue_task")
        or queue_handoff.get("task")
        or task.get("execution_task")
        or task.get("title")
        or ""
    ).strip()


def task_execution_provider(task: dict[str, Any]) -> str:
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    return normalize_provider(
        task.get("execution_provider")
        or provider_selection.get("selected")
        or execution.get("provider")
    )


def normalize_files(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(entry).strip() for entry in value if str(entry or "").strip()]


def build_execution_brief(
    *,
    approved_at: str,
    project: str,
    queue_task: str,
    provider: str,
    queue_status: str,
    task_intent: dict[str, Any] | None,
    task_shape: dict[str, Any] | None,
) -> dict[str, Any]:
    editable_files = normalize_files((task_shape or {}).get("editable_files"))
    if not editable_files:
        editable_files = normalize_files((task_intent or {}).get("affected_files"))
    return {
        "approved_at": approved_at,
        "project": normalize_project(project or "codex-agent-system"),
        "queue_task": str(queue_task or "").strip(),
        "provider": normalize_provider(provider) or "codex",
        "queue_status": str(queue_status or "").strip(),
        "status": str(queue_status or "").strip(),
        "source": str((task_intent or {}).get("source") or "").strip(),
        "objective": str((task_intent or {}).get("objective") or queue_task or "").strip(),
        "category": str((task_intent or {}).get("category") or "").strip(),
        "context_hint": str((task_intent or {}).get("context_hint") or "").strip(),
        "constraints": list((task_intent or {}).get("constraints") or []),
        "success_signals": list((task_intent or {}).get("success_signals") or []),
        "editable_files": editable_files,
        "frozen_files": normalize_files((task_shape or {}).get("frozen_files")),
        "frozen_verify_command": str((task_shape or {}).get("verification_command") or "").strip(),
        "affected_files": list((task_intent or {}).get("affected_files") or []),
        "task_intent": task_intent,
    }


def build_approval_execution_brief(
    *,
    approved_at: str,
    project: str,
    queue_task: str,
    provider: str,
    queue_status: str,
) -> dict[str, Any]:
    return {
        "approved_at": approved_at,
        "project": normalize_project(project or "codex-agent-system"),
        "queue_task": str(queue_task or "").strip(),
        "provider": normalize_provider(provider) or "codex",
        "queue_status": str(queue_status or "").strip(),
    }


def read_running_status(path: Path | None) -> tuple[str, str]:
    if path is None or not path.exists():
        return ("", "")
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key] = value
    state = str(values.get("state") or "").strip().lower()
    if state not in {"running", "retrying", "queued"}:
        return ("", "")
    return (
        normalize_project(values.get("project") or ""),
        normalize_text(values.get("task") or ""),
    )


def sync() -> list[str]:
    if len(sys.argv) < 3:
        return []

    registry_path = Path(sys.argv[1])
    project = normalize_project(sys.argv[2] or "codex-agent-system")
    status_path = Path(sys.argv[3]) if len(sys.argv) > 3 and str(sys.argv[3]).strip() else None

    payload = read_json(registry_path)
    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        return []

    queue_file = QUEUE_DIR / f"{project}.txt"
    existing_lines = []
    if queue_file.exists():
        existing_lines = [line.strip() for line in queue_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    existing_entries = set(existing_lines)
    running_project, running_task = read_running_status(status_path)
    transition_at = now_utc()
    changed = False
    requeued: list[str] = []

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if normalize_project(task.get("project") or task.get("target_project") or project) != project:
            continue
        if normalize_text(task.get("status")) != "approved":
            continue

        queue_task = task_execution_text(task)
        if not queue_task:
            continue
        if running_project == project and running_task == normalize_text(queue_task):
            continue

        queue_status = "already_queued"
        if queue_task not in existing_entries:
            queue_file.parent.mkdir(parents=True, exist_ok=True)
            with queue_file.open("a", encoding="utf-8") as handle:
                handle.write(f"{queue_task}\n")
            existing_entries.add(queue_task)
            requeued.append(queue_task)
            queue_status = "queued"

        provider = task_execution_provider(task) or "codex"
        approved_at = str(task.get("approved_at") or task.get("created_at") or transition_at).strip() or transition_at
        task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else None
        task_shape = task.get("task_shape") if isinstance(task.get("task_shape"), dict) else None
        existing_handoff = task.get("queue_handoff") if isinstance(task.get("queue_handoff"), dict) else {}
        handoff_at = transition_at if queue_status == "queued" else str(existing_handoff.get("at") or approved_at).strip() or approved_at

        desired_handoff = {
            "at": handoff_at,
            "project": project,
            "task": queue_task,
            "status": queue_status,
            "provider": provider,
        }
        if task_intent is not None:
            desired_handoff["task_intent"] = task_intent
        if existing_handoff != desired_handoff:
            task["queue_handoff"] = desired_handoff
            changed = True

        desired_approval_brief = build_approval_execution_brief(
            approved_at=approved_at,
            project=project,
            queue_task=queue_task,
            provider=provider,
            queue_status=queue_status,
        )
        if task.get("approval_execution_brief") != desired_approval_brief:
            task["approval_execution_brief"] = desired_approval_brief
            changed = True

        desired_execution_brief = build_execution_brief(
            approved_at=approved_at,
            project=project,
            queue_task=queue_task,
            provider=provider,
            queue_status=queue_status,
            task_intent=task_intent,
            task_shape=task_shape,
        )
        if task.get("execution_brief") != desired_execution_brief:
            task["execution_brief"] = desired_execution_brief
            changed = True

        if queue_status == "queued":
            history = task.get("history") if isinstance(task.get("history"), list) else []
            history.append(
                {
                    "at": transition_at,
                    "action": "queue_rehydrate",
                    "from_status": "approved",
                    "to_status": "approved",
                    "project": project,
                    "queue_task": queue_task,
                    "note": "Approved project-local task was re-enqueued because it was missing from the live project queue.",
                }
            )
            task["history"] = history[-20:]
            task["updated_at"] = transition_at
            changed = True

    if changed:
        payload["tasks"] = tasks
        write_json(registry_path, payload)

    return requeued


if __name__ == "__main__":
    requeued_tasks = sync()
    if requeued_tasks:
        print(json.dumps({"status": "success", "requeued": requeued_tasks}))
