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


def normalize_project_name(value: Any) -> str:
    text = str(value or "").strip()
    return text or "codex-agent-system"


def discover_task_registry_targets(primary_tasks_path: str) -> list[dict[str, str]]:
    primary_path = os.path.abspath(primary_tasks_path)
    repo_root = os.path.dirname(os.path.dirname(primary_path))
    projects_dir = os.path.join(repo_root, "projects")

    registry_targets: list[dict[str, str]] = []
    seen: set[str] = set()

    def append_target(project: str, candidate: str) -> None:
        if not candidate:
            return
        resolved = os.path.realpath(candidate)
        if resolved in seen:
            return
        seen.add(resolved)
        registry_targets.append(
            {
                "project": normalize_project_name(project),
                "file_path": candidate,
                "resolved_path": resolved,
            }
        )

    if os.path.isdir(projects_dir):
        for entry in sorted(os.scandir(projects_dir), key=lambda item: item.name):
            if not entry.is_dir():
                continue
            metadata = read_json(os.path.join(entry.path, "project.json"), {})
            registry_path = str(metadata.get("task_registry_file") or "").strip() or primary_path
            project_name = metadata.get("project") or metadata.get("project_id") or entry.name
            append_target(str(project_name), registry_path)

    append_target("codex-agent-system", primary_path)
    return registry_targets


def discover_task_registry_paths(primary_tasks_path: str) -> list[str]:
    return [target["file_path"] for target in discover_task_registry_targets(primary_tasks_path)]


def read_registry_tasks(targets: list[dict[str, str]], primary_tasks_path: str = "") -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    primary_resolved_path = os.path.realpath(primary_tasks_path) if primary_tasks_path else ""
    for target in targets:
        registry_path = str(target.get("file_path") or "").strip()
        resolved_path = os.path.realpath(str(target.get("resolved_path") or registry_path))
        source_project = normalize_project_name(target.get("project"))
        is_cross_project = bool(primary_resolved_path) and resolved_path != primary_resolved_path
        registry = read_json(registry_path, {"tasks": []})
        registry_tasks = registry.get("tasks")
        if not isinstance(registry_tasks, list):
            continue
        for task in registry_tasks:
            if not isinstance(task, dict):
                continue
            task_record = dict(task)
            if is_cross_project:
                task_record["_cross_project"] = True
                task_record["_source_project"] = source_project
            tasks.append(task_record)
    return tasks


def registry_payload_bytes(targets: list[dict[str, str]]) -> int:
    total = 0
    seen: set[str] = set()
    for target in targets:
        resolved = os.path.realpath(str(target.get("resolved_path") or target.get("file_path") or ""))
        if resolved in seen:
            continue
        seen.add(resolved)
        try:
            total += os.path.getsize(resolved)
        except OSError:
            continue
    return total


def registry_payload_sources(targets: list[dict[str, str]]) -> list[dict[str, Any]]:
    sources: list[dict[str, Any]] = []
    seen: set[str] = set()
    for target in targets:
        resolved = os.path.realpath(str(target.get("resolved_path") or target.get("file_path") or ""))
        if resolved in seen:
            continue
        seen.add(resolved)
        try:
            payload_bytes = os.path.getsize(resolved)
        except OSError:
            continue
        sources.append(
            {
                "project": normalize_project_name(target.get("project")),
                "file": resolved,
                "payload_bytes": payload_bytes,
            }
        )
    return sorted(
        sources,
        key=lambda item: (-int(item.get("payload_bytes") or 0), str(item.get("project") or ""), str(item.get("file") or "")),
    )


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


def build_metrics(
    tasks: list[dict[str, Any]],
    records: list[dict[str, Any]],
    external_signals: dict[str, Any] | None = None,
    task_registry_payload_bytes: int | None = None,
    task_registry_pressure_sources: list[dict[str, Any]] | None = None,
    primary_registry_path: str | None = None,
) -> dict[str, Any]:
    return build_persisted_metrics(
        tasks,
        records,
        external_signals,
        task_registry_payload_bytes,
        task_registry_pressure_sources,
        primary_registry_path,
    )


def preserve_empty_history_signals(
    metrics: dict[str, Any],
    existing_metrics: dict[str, Any],
    tasks: list[dict[str, Any]],
    records: list[dict[str, Any]],
) -> dict[str, Any]:
    if tasks or records or not isinstance(existing_metrics, dict) or not existing_metrics:
        return metrics

    preserved_fields = (
        "success_rate",
        "recent_success_rate",
        "timeout_failure_rate",
        "first_pass_success_rate",
        "retry_classification_coverage",
        "retry_classified_count",
        "retry_total_count",
        "zero_step_timeout_rate",
        "total_tasks",
    )
    for field in preserved_fields:
        if field in existing_metrics:
            metrics[field] = existing_metrics[field]
    return metrics


def preserve_missing_external_signal_snapshot(
    metrics: dict[str, Any],
    existing_metrics: dict[str, Any],
    external_signals: dict[str, Any] | None,
) -> dict[str, Any]:
    if (
        not isinstance(existing_metrics, dict)
        or not existing_metrics
        or (isinstance(external_signals, dict) and external_signals)
    ):
        return metrics

    preserved_fields = (
        "external_signal_status",
        "external_signal_count",
        "fresh_external_signal_count",
        "external_signal_error_count",
        "external_signal_updated_at",
        "latest_external_signal_source",
        "latest_external_signal_title",
        "latest_external_signal_url",
        "latest_external_signal_published_at",
    )
    for field in preserved_fields:
        if field in existing_metrics:
            metrics[field] = existing_metrics[field]
    return metrics


def main() -> int:
    if len(sys.argv) not in {4, 5}:
        print("usage: sync-task-artifacts.py <tasks.json> <tasks.log> <metrics.json> [external-signals.json]", file=sys.stderr)
        return 2

    tasks_path, task_log_path, metrics_path = sys.argv[1:4]
    external_signals_path = sys.argv[4] if len(sys.argv) == 5 else ""

    registry_targets = discover_task_registry_targets(tasks_path)
    tasks = read_registry_tasks(registry_targets, tasks_path)
    task_registry_payload_bytes = registry_payload_bytes(registry_targets)
    task_registry_pressure_sources = registry_payload_sources(registry_targets)

    records = read_json_lines(task_log_path)
    external_signals = read_json(external_signals_path, {}) if external_signals_path else {}
    existing_metrics = read_json(metrics_path, {})
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
    metrics = build_metrics(
        [task for task in tasks if isinstance(task, dict)],
        records,
        external_signals,
        task_registry_payload_bytes,
        task_registry_pressure_sources,
        tasks_path,
    )
    metrics = preserve_empty_history_signals(metrics, existing_metrics, tasks, records)
    metrics = preserve_missing_external_signal_snapshot(metrics, existing_metrics, external_signals)
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
