#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import tempfile
from typing import Any

from task_metrics import build_persisted_metrics


DEFAULT_SCORE = 8


def read_json(path: str, fallback: dict[str, Any]) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return dict(fallback)


def read_json_lines(path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not os.path.exists(path):
        return records

    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except Exception:
                continue
            if isinstance(payload, dict):
                records.append(payload)
    return records


def write_json(path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, path)


def append_json_lines(path: str, records: list[dict[str, Any]]) -> None:
    if not records:
        return

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


def normalize_status(value: Any) -> str:
    return str(value or "").strip().lower()


def safe_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def safe_int(value: Any, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def manual_recovery_entry(task: dict[str, Any]) -> dict[str, Any] | None:
    if normalize_status(task.get("status")) != "completed":
        return None

    history = task.get("history")
    if not isinstance(history, list):
        return None

    manual_entries = [
        entry
        for entry in history
        if isinstance(entry, dict) and str(entry.get("action") or "").strip() == "manual_complete"
    ]
    if not manual_entries:
        return None

    latest_manual = manual_entries[-1]
    task_id = str(task.get("id") or "").strip()
    title = str(task.get("title") or latest_manual.get("queue_task") or "").strip()
    project = str(task.get("project") or latest_manual.get("project") or "codex-agent-system").strip() or "codex-agent-system"
    recovery_at = str(latest_manual.get("at") or task.get("completed_at") or task.get("updated_at") or "").strip()
    if not recovery_at or not title:
        return None

    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    attempts = safe_int(execution.get("attempt"), 1)
    if attempts < 1:
        attempts = 1

    return {
        "timestamp": recovery_at,
        "project": project,
        "task": title,
        "result": "SUCCESS",
        "attempts": attempts,
        "score": DEFAULT_SCORE,
        "branch": "",
        "pr_url": "",
        "run_id": f"manual-recovery::{task_id}::{recovery_at}",
        "duration_seconds": 0,
        "source": "manual_recovery",
        "task_id": task_id,
    }


def build_metrics(tasks: list[dict[str, Any]], records: list[dict[str, Any]]) -> dict[str, Any]:
    return build_persisted_metrics(tasks, records)


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: sync-task-artifacts.py <tasks.json> <tasks.log> <metrics.json>", file=sys.stderr)
        return 2

    tasks_path, task_log_path, metrics_path = sys.argv[1:]

    registry = read_json(tasks_path, {"tasks": []})
    tasks = registry.get("tasks")
    if not isinstance(tasks, list):
        tasks = []

    records = read_json_lines(task_log_path)
    existing_run_ids = {
        str(record.get("run_id") or "").strip()
        for record in records
        if isinstance(record, dict)
    }

    appended_records: list[dict[str, Any]] = []
    for task in tasks:
        if not isinstance(task, dict):
            continue
        record = manual_recovery_entry(task)
        if not record:
            continue
        run_id = str(record.get("run_id") or "").strip()
        if not run_id or run_id in existing_run_ids:
            continue
        appended_records.append(record)
        existing_run_ids.add(run_id)

    append_json_lines(task_log_path, appended_records)
    records.extend(appended_records)
    metrics = build_metrics([task for task in tasks if isinstance(task, dict)], records)
    write_json(metrics_path, metrics)

    print(
        json.dumps(
            {
                "appended_records": len(appended_records),
                "manual_recovery_records": metrics["manual_recovery_records"],
                "total_tasks": metrics["total_tasks"],
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
