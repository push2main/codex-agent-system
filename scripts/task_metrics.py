from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any

FIRST_PASS_SUCCESS_RATE_THRESHOLD = 0.5
STRATEGY_SATURATED_FAILURE_THRESHOLD = 2
RETRY_CHURN_ATTEMPT_THRESHOLD = 2
RECENT_RETRY_CHURN_WINDOW = 30
TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000


def normalize_status(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


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


def parse_timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def first_non_empty_text(*values: Any) -> str:
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def manual_recovery_records(records: list[dict[str, Any]]) -> int:
    return sum(1 for record in records if str(record.get("source") or "").strip() == "manual_recovery")


def task_has_persisted_success(task: dict[str, Any]) -> bool:
    if not isinstance(task, dict):
        return False

    status = normalize_status(task.get("status"))
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    return (
        status in {"completed", "success"}
        or str(execution.get("result") or "").strip().upper() == "SUCCESS"
        or str(execution_context.get("result") or "").strip().upper() == "SUCCESS"
    )


def build_task_index_by_id(tasks: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    index: dict[str, dict[str, Any]] = {}
    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_id = normalize_text(task.get("id"))
        if not task_id or task_id in index:
            continue
        index[task_id] = task
    return index


def task_log_identity_key(record: dict[str, Any]) -> str:
    if not isinstance(record, dict):
        return ""
    project = normalize_text(record.get("project"))
    task = normalize_text(record.get("task"))
    if not project or not task:
        return ""
    return f"{project}::{task}"


def build_latest_success_timestamp_by_identity(records: list[dict[str, Any]]) -> dict[str, datetime]:
    latest_by_identity: dict[str, datetime] = {}
    for record in records:
        if not isinstance(record, dict):
            continue
        if str(record.get("result") or "").strip().upper() != "SUCCESS":
            continue
        identity = task_log_identity_key(record)
        timestamp = parse_timestamp(record.get("timestamp"))
        if not identity or timestamp is None:
            continue
        existing_timestamp = latest_by_identity.get(identity)
        if existing_timestamp is None or timestamp > existing_timestamp:
            latest_by_identity[identity] = timestamp
    return latest_by_identity


def is_unresolved_timeout_record(
    record: dict[str, Any],
    tasks_by_id: dict[str, dict[str, Any]],
    latest_success_by_identity: dict[str, datetime],
) -> bool:
    if not isinstance(record, dict):
        return False
    if str(record.get("result") or "").strip() != "FAILURE":
        return False
    if str(record.get("failure_kind") or "").strip() != "timeout":
        return False

    task_id = normalize_text(record.get("task_id"))
    if not task_id:
        identity = task_log_identity_key(record)
        record_timestamp = parse_timestamp(record.get("timestamp"))
        latest_success_timestamp = latest_success_by_identity.get(identity)
        if (
            identity
            and record_timestamp is not None
            and latest_success_timestamp is not None
            and latest_success_timestamp > record_timestamp
        ):
            return False
        return True

    linked_task = tasks_by_id.get(task_id)
    if not isinstance(linked_task, dict):
        return True

    return not task_has_persisted_success(linked_task)


def derive_resolved_attempt_record(task: dict[str, Any]) -> dict[str, Any] | None:
    if not isinstance(task, dict):
        return None

    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    status = normalize_status(task.get("status"))
    resolved_result = str(execution.get("result") or "").strip().upper()
    if status != "completed" or resolved_result != "SUCCESS":
        return None

    attempt = max(safe_int(execution.get("attempt")), 0)
    return {
        "result": resolved_result,
        "attempt": attempt,
    }


def derive_loop_effort_record(task: dict[str, Any]) -> dict[str, int] | None:
    if not isinstance(task, dict):
        return None

    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    attempt = max(
        safe_int(
            execution.get("attempt")
            if execution.get("attempt") is not None
            else execution_context.get("attempts")
            if execution_context.get("attempts") is not None
            else failure_context.get("attempts"),
            0,
        ),
        0,
    )
    total_step_attempts = max(
        safe_int(
            execution.get("total_step_attempts")
            if execution.get("total_step_attempts") is not None
            else execution_context.get("total_step_attempts")
            if execution_context.get("total_step_attempts") is not None
            else failure_context.get("total_step_attempts"),
            attempt,
        ),
        attempt,
    )
    if total_step_attempts <= attempt:
        return None

    return {
        "attempt": attempt,
        "total_step_attempts": total_step_attempts,
    }


def build_first_pass_success_signal(tasks: list[dict[str, Any]]) -> dict[str, Any]:
    successful_records = [
        record
        for record in (derive_resolved_attempt_record(task) for task in tasks)
        if isinstance(record, dict) and record.get("result") == "SUCCESS"
    ]
    first_pass_success_count = sum(1 for record in successful_records if safe_int(record.get("attempt")) <= 1)
    multi_attempt_resolved_count = sum(1 for record in successful_records if safe_int(record.get("attempt")) > 1)
    first_pass_success_rate = round(first_pass_success_count / len(successful_records), 2) if successful_records else 0
    return {
        "detected": bool(successful_records) and first_pass_success_rate < FIRST_PASS_SUCCESS_RATE_THRESHOLD,
        "first_pass_success_rate": first_pass_success_rate,
        "first_pass_success_count": first_pass_success_count,
        "multi_attempt_resolved_count": multi_attempt_resolved_count,
    }


def build_loop_effort_signal(tasks: list[dict[str, Any]]) -> dict[str, Any]:
    loop_effort_records = [
        record for record in (derive_loop_effort_record(task) for task in tasks) if isinstance(record, dict)
    ]
    loop_effort_task_count = len(loop_effort_records)
    loop_effort_extra_step_attempts = sum(
        max(0, safe_int(record.get("total_step_attempts")) - safe_int(record.get("attempt")))
        for record in loop_effort_records
    )
    return {
        "detected": loop_effort_task_count > 0,
        "loop_effort_task_count": loop_effort_task_count,
        "loop_effort_extra_step_attempts": loop_effort_extra_step_attempts,
    }


def derive_persisted_execution_state(task: dict[str, Any]) -> dict[str, Any]:
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    status = normalize_status(task.get("status") or "unknown") or "unknown"
    execution_state = normalize_status(execution.get("state") or "unknown") or "unknown"
    attempt = max(0, safe_int(execution.get("attempt"), 0))
    max_retries = max(0, safe_int(execution.get("max_retries"), 0))
    will_retry = execution.get("will_retry") is True or execution_state == "retrying"
    return {
        "status": status,
        "execution_state": execution_state,
        "attempt": attempt,
        "max_retries": max_retries,
        "will_retry": will_retry,
    }


def persisted_task_outcome_timestamp(task: dict[str, Any]) -> str:
    for key in ("completed_at", "failed_at", "updated_at", "approved_at", "created_at"):
        value = str(task.get(key) or "").strip()
        if value:
            return value
    return ""


def build_persisted_board_health_signals(tasks: list[dict[str, Any]]) -> dict[str, Any]:
    registry_tasks = [task for task in tasks if isinstance(task, dict)]
    active_execution_count = 0
    executable_backlog_count = 0
    active_retry_churn_count = 0
    pending_approval_count = 0

    recent_retry_churn_count = sum(
        1
        for entry in sorted(
            (
                {
                    "execution": derive_persisted_execution_state(task),
                    "result": str(
                        (task.get("execution") if isinstance(task.get("execution"), dict) else {}).get("result") or ""
                    ).strip().upper(),
                    "timestamp": persisted_task_outcome_timestamp(task),
                }
                for task in registry_tasks
            ),
            key=lambda item: str(item.get("timestamp") or ""),
            reverse=True,
        )[:RECENT_RETRY_CHURN_WINDOW]
        if entry["execution"]["status"] in {"completed", "success", "failed"}
        and entry["result"] in {"SUCCESS", "FAILURE"}
        and entry["execution"]["attempt"] >= RETRY_CHURN_ATTEMPT_THRESHOLD
    )

    # Match dashboard logic: queue starvation should only reflect executable work that is not making progress.
    # Pending approval is intentionally excluded because manual review can pause the queue without starvation.
    for task in registry_tasks:
        execution = derive_persisted_execution_state(task)
        if execution["status"] == "pending_approval":
            pending_approval_count += 1
        if execution["status"] in {"approved", "running"}:
            executable_backlog_count += 1
        if execution["execution_state"] in {"running", "retrying"}:
            active_execution_count += 1
        if (
            execution["status"] in {"approved", "running"}
            or execution["execution_state"] in {"running", "retrying"}
        ) and (
            execution["execution_state"] == "retrying"
            or (
                execution["attempt"] >= RETRY_CHURN_ATTEMPT_THRESHOLD
                and (execution["max_retries"] == 0 or execution["attempt"] <= execution["max_retries"])
            )
        ):
            active_retry_churn_count += 1

    return {
        "retry_churn_detected": active_retry_churn_count > 0 or recent_retry_churn_count > 0,
        "queue_starvation_detected": executable_backlog_count > 0 and active_execution_count == 0,
        "pending_approval_blocked_detected": (
            pending_approval_count > 0 and executable_backlog_count == 0 and active_execution_count == 0
        ),
    }


def strategy_task_source(task: dict[str, Any]) -> str:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    return normalize_status(task_intent.get("source") or task.get("taskIntentSource") or task.get("task_intent_source"))


def is_saturable_strategy_task(task: dict[str, Any]) -> bool:
    source = strategy_task_source(task)
    if source in {"strategy_seed", "strategy_anomaly"}:
        return True
    strategy_template = str(task.get("strategy_template") or task.get("strategyTemplate") or "").strip()
    root_source_task_id = str(
        task.get("root_source_task_id") or task.get("rootSourceTaskId") or task.get("source_task_id") or ""
    ).strip()
    return bool(strategy_template) and root_source_task_id.startswith("strategy::")


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def strategy_saturation_key(task: dict[str, Any]) -> str:
    if not is_saturable_strategy_task(task):
        return ""
    project = normalize_text(task.get("project") or "codex-agent-system") or "codex-agent-system"
    strategy_template = str(task.get("strategy_template") or task.get("strategyTemplate") or "").strip()
    title = normalize_text(task_execution_text(task))
    if not strategy_template and not title:
        return ""
    return f"{project}::{strategy_template}::{title}"


def build_strategy_failure_saturation_counts(tasks: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for task in tasks:
        if not isinstance(task, dict) or normalize_status(task.get("status")) != "failed":
            continue
        key = strategy_saturation_key(task)
        if not key:
            continue
        counts[key] = counts.get(key, 0) + 1
    return counts


def build_strategy_saturation_signal(tasks: list[dict[str, Any]]) -> dict[str, Any]:
    saturation_counts = build_strategy_failure_saturation_counts(tasks)
    saturated_failed_tasks = 0
    for task in tasks:
        if not isinstance(task, dict) or normalize_status(task.get("status")) != "failed":
            continue
        key = strategy_saturation_key(task)
        if key and saturation_counts.get(key, 0) >= STRATEGY_SATURATED_FAILURE_THRESHOLD:
            saturated_failed_tasks += 1
    return {
        "detected": saturated_failed_tasks > 0,
        "saturated_failed_tasks": saturated_failed_tasks,
    }


def build_external_signal_summary(payload: dict[str, Any] | None) -> dict[str, Any]:
    snapshot = payload if isinstance(payload, dict) else {}
    signals = [entry for entry in snapshot.get("signals", []) if isinstance(entry, dict)]
    errors = [entry for entry in snapshot.get("errors", []) if isinstance(entry, (dict, str))]
    latest_signal = max(
        signals,
        key=lambda signal: first_non_empty_text(signal.get("published_at"), signal.get("fetched_at")),
        default=None,
    )
    fresh_signal_count = sum(1 for signal in signals if signal.get("fresh") is True)
    updated_at = first_non_empty_text(snapshot.get("updated_at"))
    if errors:
        status = "error"
    elif fresh_signal_count > 0:
        status = "fresh"
    elif signals:
        status = "stale"
    elif updated_at:
        status = "empty"
    else:
        status = "unavailable"
    return {
        "status": status,
        "signal_count": len(signals),
        "fresh_signal_count": fresh_signal_count,
        "error_count": len(errors),
        "updated_at": updated_at,
        "latest_signal_source": first_non_empty_text(
            latest_signal.get("source_label") if latest_signal else "",
            latest_signal.get("source_id") if latest_signal else "",
        ),
        "latest_signal_title": first_non_empty_text(latest_signal.get("title") if latest_signal else ""),
        "latest_signal_url": first_non_empty_text(latest_signal.get("url") if latest_signal else ""),
        "latest_signal_published_at": first_non_empty_text(latest_signal.get("published_at") if latest_signal else ""),
    }


def build_task_registry_pressure_signal(
    tasks: list[dict[str, Any]], task_registry_payload_bytes: int | None = None
) -> dict[str, Any]:
    payload_bytes = (
        max(safe_int(task_registry_payload_bytes), 0)
        if task_registry_payload_bytes is not None
        else len(json.dumps({"tasks": tasks}, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    )
    detected = payload_bytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
    return {
        "task_registry_payload_bytes": payload_bytes,
        "task_registry_pressure_detected": detected,
        # The dashboard remains the highest-frequency registry reader under the current fixed poll topology.
        "task_registry_pressure_primary_surface": "dashboard_read_path" if detected else "",
    }


def build_persisted_metrics(
    tasks: list[dict[str, Any]],
    records: list[dict[str, Any]],
    external_signals: dict[str, Any] | None = None,
    task_registry_payload_bytes: int | None = None,
) -> dict[str, Any]:
    total_records = len(records)
    success_records = sum(1 for record in records if str(record.get("result") or "").strip() == "SUCCESS")
    tasks_by_id = build_task_index_by_id(tasks)
    latest_success_by_identity = build_latest_success_timestamp_by_identity(records)
    timeout_failure_records = sum(
        1 for record in records if is_unresolved_timeout_record(record, tasks_by_id, latest_success_by_identity)
    )
    pending_approval = sum(1 for task in tasks if normalize_status(task.get("status")) == "pending_approval")
    approved = sum(1 for task in tasks if normalize_status(task.get("status")) == "approved")
    last_score = safe_float(tasks[-1].get("score")) if tasks else 0.0
    first_pass_signal = build_first_pass_success_signal(tasks)
    loop_effort_signal = build_loop_effort_signal(tasks)
    strategy_saturation_signal = build_strategy_saturation_signal(tasks)
    board_health_signals = build_persisted_board_health_signals(tasks)
    external_signal_summary = build_external_signal_summary(external_signals)
    task_registry_pressure_signal = build_task_registry_pressure_signal(tasks, task_registry_payload_bytes)

    return {
        "total_tasks": total_records,
        "success_rate": round(success_records / total_records, 2) if total_records else 0,
        "timeout_failure_records": timeout_failure_records,
        "timeout_failure_rate": round(timeout_failure_records / total_records, 2) if total_records else 0,
        "analysis_runs": len(tasks),
        "pending_approval_tasks": pending_approval,
        "approved_tasks": approved,
        "task_registry_total": len(tasks),
        "task_registry_payload_bytes": task_registry_pressure_signal["task_registry_payload_bytes"],
        "task_registry_pressure_detected": task_registry_pressure_signal["task_registry_pressure_detected"],
        "task_registry_pressure_primary_surface": task_registry_pressure_signal["task_registry_pressure_primary_surface"],
        "last_task_score": last_score,
        "manual_recovery_records": manual_recovery_records(records),
        "low_first_pass_success_detected": first_pass_signal["detected"],
        "strategy_saturation_detected": strategy_saturation_signal["detected"],
        "saturated_failed_tasks": strategy_saturation_signal["saturated_failed_tasks"],
        "retry_churn_detected": board_health_signals["retry_churn_detected"],
        "queue_starvation_detected": board_health_signals["queue_starvation_detected"],
        "pending_approval_blocked_detected": board_health_signals["pending_approval_blocked_detected"],
        "low_completion_drain_detected": first_pass_signal["detected"] and approved == 0 and not any(
            normalize_status(t.get("status")) in {"running"}
            or normalize_status((t.get("execution") or {}).get("state")) in {"running", "retrying"}
            for t in tasks
            if (t.get("task_intent") or {}).get("source", "") in {"strategy_seed", "strategy_anomaly", "strategy_followup", "strategy_loop"}
        ),
        "first_pass_success_rate": first_pass_signal["first_pass_success_rate"],
        "first_pass_success_count": first_pass_signal["first_pass_success_count"],
        "multi_attempt_resolved_count": first_pass_signal["multi_attempt_resolved_count"],
        "loop_effort_detected": loop_effort_signal["detected"],
        "loop_effort_task_count": loop_effort_signal["loop_effort_task_count"],
        "loop_effort_extra_step_attempts": loop_effort_signal["loop_effort_extra_step_attempts"],
        "external_signal_status": external_signal_summary["status"],
        "external_signal_count": external_signal_summary["signal_count"],
        "fresh_external_signal_count": external_signal_summary["fresh_signal_count"],
        "external_signal_error_count": external_signal_summary["error_count"],
        "external_signal_updated_at": external_signal_summary["updated_at"],
        "latest_external_signal_source": external_signal_summary["latest_signal_source"],
        "latest_external_signal_title": external_signal_summary["latest_signal_title"],
        "latest_external_signal_url": external_signal_summary["latest_signal_url"],
        "latest_external_signal_published_at": external_signal_summary["latest_signal_published_at"],
    }
