from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from bisect import bisect_right
from pathlib import Path
from typing import Any

FIRST_PASS_SUCCESS_RATE_THRESHOLD = 0.5
FIRST_PASS_SUCCESS_MIN_SAMPLE_SIZE = 3
FIRST_PASS_SUCCESS_RECENT_LOG_WINDOW = 50
STRATEGY_SATURATED_FAILURE_THRESHOLD = 2
RETRY_CHURN_ATTEMPT_THRESHOLD = 2
RECENT_RETRY_CHURN_WINDOW = 30
TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000
DEFAULT_EXTERNAL_SIGNAL_FRESHNESS_WINDOW_SECONDS = 604800
RETRY_CLASSIFICATION_BUCKETS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("timeout", (r"timed?\s*out", r"timeout", r"deadline exceeded", r"operation exceeded")),
    ("context_limit", (r"context\s+(?:window|limit)", r"context.*too.*long", r"token\s+limit", r"maximum context length", r"too many tokens")),
    ("missing_dependency", (r"command not found", r"no such file or directory", r"module not found", r"no module named", r"missing dependency", r"required command", r"dependencies were not installed", r"node_modules is missing")),
    ("sandbox_restriction", (r"sandbox.*perm", r"blocked by.*policy", r"permission.*policy", r"operation not permitted", r"socketexception: operation not permitted", r"not permitted", r"cannot.*create.*node_modules", r"npm.*blocked", r"blocked by.*permission", r"command.*blocked", r"execution.*blocked", r"requires approval", r"security.*restrict", r"sandbox.*block", r"sandbox.*security", r"permission.*system.*block")),
    ("missing_environment", (r"android sdk", r"sdk.not.found", r"jdk.*(missing|not found)", r"java_home", r"gradle.*(not found|failed|could not resolve|plugin.*was not found)", r"missing.*(sdk|jdk|ndk|environment)", r"com\.android\.(application|library)", r"plugin.*com\.android", r"android.*gradle.*plugin", r"gradlew.*(not found|no such file)", r"compilesdk|minsdk", r"kotlin.*android")),
    ("review_rejection", (r"review.*(?:rejected|not approved|fail)", r"reviewer.*(?:rejected|fail)", r"not approved", r"review.*status.*(?:retry|fail)", r"verification step lacks evidence")),
    ("evaluation_failure", (r"evaluation.*fail", r"evaluator.*fail", r"eval.*status.*fail", r"quality.*(?:below|insufficient|poor)", r"score.*(?:below|too low)")),
    ("low_completion", (r"low.completion", r"completion.*(?:below|under).*threshold", r"completion.*stayed.*below", r"completion gate.*fail")),
    ("empty_output", (r"empty.*(?:response|output|result)", r"null.*output", r"no.*output.*produced", r"blank.*response")),
    ("tool_failure", (r"internal server error", r"server error", r"tool failed", r"tool error", r"exit code", r"non-zero exit", r"provider error", r"service unavailable", r"502", r"503", r"504")),
    ("missing_build_tool", (r"xcodebuild.*not found", r"xcrun.*not found", r"pod.*not found", r"flutter.*not found", r"cocoapods.*not found")),
    ("missing_platform", (r"no.*ios.*simulator", r"no.*android.*emulator", r"device not found", r"no.*provisioning.*profile")),
    ("reviewer_indeterminate", (r"fallback.*reviewer.*cannot.*validate", r"cannot.*validate.*deterministically", r"bounded retry guidance", r"review requested another attempt")),
    ("coder_blocked", (r"cannot run", r"cannot execute", r"unable to (run|execute|complete|verify)", r"could not (run|execute|verify)", r"verification (failed|impossible|not possible)", r"coder reported failure", r"coder did not complete the step successfully", r"implementation artifact is missing or incomplete")),
    ("model_refusal", (r"i cannot|i can't|i'm unable|i am unable|as an ai|not able to|refus", r"policy|content policy|safety")),
    ("build_failure", (r"build failed|compilation error|compile error|linker error|assembl.*fail", r"error:.*expected|error:.*undeclared|error:.*undefined")),
    ("test_failure", (r"tests?\s+fail|assert.*fail|expect.*fail|tests? did not pass",)),
    ("no_change_produced", (r"no changes (made|produced|detected)|no diff produced|nothing to commit|working tree clean|no files changed|did not produce any",)),
    ("plan_incomplete", (r"plan.*incomplete|step.*missing|could not complete.*plan|no plan produced",)),
    ("step_not_completed", (r"step.*not.*complet|did not complete|incomplete.*step|step.*fail|could not.*finish",)),
    ("verification_failed", (r"verif.*fail|check.*fail|assert.*error|expect.*but.*got|does not match",)),
    ("file_not_found", (r"file.*not found|no such file|path.*does not exist|cannot find|enoent",)),
    ("syntax_error", (r"syntax.*error|parse.*error|unexpected token|invalid syntax|indentation",)),
    ("permission_error", (r"permission denied|eacces|eperm|access denied|forbidden",)),
    ("network_error", (r"network.*error|connection.*refused|econnrefused|dns.*fail|fetch.*fail|socket.*error",)),
    ("git_conflict", (r"merge conflict|rebase.*fail|git.*conflict|cannot.*merge|unmerged.*paths",)),
    ("dependency_conflict", (r"version.*conflict|incompatible.*version|peer.*dependency|resolution.*fail",)),
    ("resource_limit", (r"out of memory|oom|heap.*limit|stack.*overflow|segfault|killed",)),
)


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


def normalize_datetime_utc(value: datetime | None) -> datetime | None:
    if not isinstance(value, datetime):
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def external_signal_now() -> datetime:
    override = normalize_datetime_utc(parse_timestamp(os.environ.get("CODEX_EXTERNAL_SIGNAL_NOW")))
    if override is not None:
        return override
    return datetime.now(timezone.utc)


def external_signal_freshness_window_seconds(
    snapshot: dict[str, Any] | None = None,
    signal: dict[str, Any] | None = None,
) -> int:
    raw_value = None
    if isinstance(signal, dict):
        raw_value = signal.get("freshness_window_seconds")
    if raw_value is None and isinstance(snapshot, dict):
        raw_value = snapshot.get("freshness_window_seconds")
    window_seconds = safe_int(raw_value, DEFAULT_EXTERNAL_SIGNAL_FRESHNESS_WINDOW_SECONDS)
    return max(60, window_seconds)


def external_signal_is_fresh(
    signal: dict[str, Any],
    snapshot: dict[str, Any] | None = None,
    *,
    now: datetime | None = None,
) -> bool:
    if not isinstance(signal, dict):
        return False
    reference = normalize_datetime_utc(
        parse_timestamp(first_non_empty_text(signal.get("published_at"), signal.get("fetched_at")))
    )
    if reference is None:
        return signal.get("fresh") is True
    current = normalize_datetime_utc(now) or external_signal_now()
    age_seconds = max(int((current - reference).total_seconds()), 0)
    return age_seconds <= external_signal_freshness_window_seconds(snapshot, signal)


def first_non_empty_text(*values: Any) -> str:
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def normalize_project(value: Any) -> str:
    return normalize_text(value) or "codex-agent-system"


def classify_retry_failure_text(value: Any) -> str:
    text = normalize_text(value)
    if not text:
        return "unknown"
    for name, patterns in RETRY_CLASSIFICATION_BUCKETS:
        if any(re.search(pattern, text) for pattern in patterns):
            return name
    return "unknown"


def retry_failure_identity(entry: dict[str, Any]) -> str:
    project = normalize_project(entry.get("project"))
    task_id = normalize_text(entry.get("task_id"))
    if not project or not task_id:
        return ""
    return f"{project}::{task_id}"


def build_retry_failure_kind_index(records: list[dict[str, Any]]) -> dict[str, list[tuple[datetime | None, str]]]:
    index: dict[str, list[tuple[datetime | None, str]]] = {}
    for record in records:
        if not isinstance(record, dict):
            continue
        if str(record.get("result") or "").strip().upper() != "FAILURE":
            continue

        identity = retry_failure_identity(record)
        failure_kind = normalize_text(record.get("failure_kind"))
        if not identity or not failure_kind:
            continue

        index.setdefault(identity, []).append((parse_timestamp(record.get("timestamp")), failure_kind))

    for values in index.values():
        values.sort(key=lambda item: (item[0] is None, item[0].timestamp() if item[0] is not None else float("-inf")))
    return index


def retry_failure_kind_from_records(
    entry: dict[str, Any],
    failure_kind_index: dict[str, list[tuple[datetime | None, str]]],
) -> str:
    identity = retry_failure_identity(entry)
    if not identity:
        return "unknown"

    candidates = failure_kind_index.get(identity)
    if not candidates:
        return "unknown"

    retry_timestamp = parse_timestamp(entry.get("timestamp"))
    if retry_timestamp is None:
        return candidates[-1][1]

    retry_epoch = retry_timestamp.timestamp()
    candidate_timestamps = [timestamp.timestamp() if timestamp is not None else float("-inf") for timestamp, _ in candidates]
    last_prior_index = bisect_right(candidate_timestamps, retry_epoch) - 1
    if last_prior_index >= 0:
        return candidates[last_prior_index][1]
    return candidates[-1][1]


def effective_retry_classification(
    entry: dict[str, Any],
    failure_kind_index: dict[str, list[tuple[datetime | None, str]]] | None = None,
) -> str:
    classification = normalize_text(entry.get("classification"))
    if classification and classification != "unknown":
        return classification

    text_classification = classify_retry_failure_text(entry.get("error_text"))
    if text_classification != "unknown":
        return text_classification

    if failure_kind_index:
        return retry_failure_kind_from_records(entry, failure_kind_index)
    return "unknown"


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
    unique_by_id: dict[str, dict[str, Any]] = {}
    duplicate_ids: set[str] = set()
    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_id = normalize_text(task.get("id"))
        if not task_id:
            continue
        project = normalize_project(task.get("project") or task.get("target_project"))
        index[f"{project}::{task_id}"] = task
        if task_id in unique_by_id:
            duplicate_ids.add(task_id)
            continue
        unique_by_id[task_id] = task
    for task_id, task in unique_by_id.items():
        if task_id not in duplicate_ids:
            index[task_id] = task
    return index


def lookup_task_by_id(index: dict[str, dict[str, Any]], task_id: Any, project: Any = "") -> dict[str, Any] | None:
    normalized_task_id = normalize_text(task_id)
    if not normalized_task_id:
        return None
    normalized_project = normalize_project(project) if normalize_text(project) else ""
    if normalized_project:
        scoped = index.get(f"{normalized_project}::{normalized_task_id}")
        if isinstance(scoped, dict):
            return scoped
    unscoped = index.get(normalized_task_id)
    return unscoped if isinstance(unscoped, dict) else None


def task_log_identity_key(record: dict[str, Any]) -> str:
    if not isinstance(record, dict):
        return ""
    project = normalize_project(record.get("project") or record.get("target_project"))
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

    linked_task = lookup_task_by_id(tasks_by_id, task_id, record.get("project") or record.get("target_project"))
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


def derive_task_log_resolved_attempt_record(record: dict[str, Any]) -> dict[str, Any] | None:
    if not isinstance(record, dict):
        return None

    resolved_result = str(record.get("result") or "").strip().upper()
    if resolved_result != "SUCCESS":
        return None

    attempt = max(safe_int(record.get("attempts") if record.get("attempts") is not None else record.get("attempt")), 0)
    return {
        "result": resolved_result,
        "attempt": attempt,
    }


def summarize_first_pass_success_records(successful_records: list[dict[str, Any]]) -> dict[str, Any]:
    first_pass_success_count = sum(1 for record in successful_records if safe_int(record.get("attempt")) <= 1)
    multi_attempt_resolved_count = sum(1 for record in successful_records if safe_int(record.get("attempt")) > 1)
    first_pass_success_rate = round(first_pass_success_count / len(successful_records), 2) if successful_records else 0
    return {
        "detected": bool(successful_records) and first_pass_success_rate < FIRST_PASS_SUCCESS_RATE_THRESHOLD,
        "first_pass_success_rate": first_pass_success_rate,
        "first_pass_success_count": first_pass_success_count,
        "multi_attempt_resolved_count": multi_attempt_resolved_count,
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


def build_first_pass_success_signal(
    tasks: list[dict[str, Any]],
    records: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    successful_records = [
        record
        for record in (derive_resolved_attempt_record(task) for task in tasks)
        if isinstance(record, dict) and record.get("result") == "SUCCESS"
    ]
    if len(successful_records) < FIRST_PASS_SUCCESS_MIN_SAMPLE_SIZE and records:
        recent_completed_records = [
            record
            for record in records
            if str(record.get("result") or "").strip().upper() in {"SUCCESS", "FAILURE"}
        ][-FIRST_PASS_SUCCESS_RECENT_LOG_WINDOW:]
        recent_successful_records = [
            record
            for record in (derive_task_log_resolved_attempt_record(record) for record in recent_completed_records)
            if isinstance(record, dict) and record.get("result") == "SUCCESS"
        ]
        if len(recent_successful_records) >= FIRST_PASS_SUCCESS_MIN_SAMPLE_SIZE:
            successful_records = recent_successful_records
    return summarize_first_pass_success_records(successful_records)


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
    registry_tasks = [
        task for task in tasks
        if isinstance(task, dict) and not task.get("_cross_project")
    ]
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
    now = external_signal_now()
    latest_signal = max(
        signals,
        key=lambda signal: first_non_empty_text(signal.get("published_at"), signal.get("fetched_at")),
        default=None,
    )
    fresh_signal_count = sum(1 for signal in signals if external_signal_is_fresh(signal, snapshot, now=now))
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
    tasks: list[dict[str, Any]],
    task_registry_payload_bytes: int | None = None,
    task_registry_pressure_sources: list[dict[str, Any]] | None = None,
    primary_registry_path: str | None = None,
    primary_project_name: str | None = "codex-agent-system",
) -> dict[str, Any]:
    payload_bytes = (
        max(safe_int(task_registry_payload_bytes), 0)
        if task_registry_payload_bytes is not None
        else len(json.dumps({"tasks": tasks}, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    )
    normalized_sources: list[dict[str, Any]] = []
    seen_files: set[str] = set()
    for entry in task_registry_pressure_sources or []:
        if not isinstance(entry, dict):
            continue
        file_path = str(entry.get("file") or "").strip()
        if not file_path or file_path in seen_files:
            continue
        seen_files.add(file_path)
        normalized_sources.append(
            {
                "project": first_non_empty_text(entry.get("project"), "codex-agent-system"),
                "file": file_path,
                "payload_bytes": max(safe_int(entry.get("payload_bytes")), 0),
            }
        )
    normalized_sources.sort(key=lambda entry: (-safe_int(entry.get("payload_bytes")), entry["project"], entry["file"]))
    detected = payload_bytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
    dominant_source = dict(normalized_sources[0]) if normalized_sources else {}

    local_source: dict[str, Any] = {}
    normalized_primary_registry_path = os.path.realpath(primary_registry_path) if primary_registry_path else ""
    if normalized_primary_registry_path:
        for entry in normalized_sources:
            if os.path.realpath(entry["file"]) == normalized_primary_registry_path:
                local_source = dict(entry)
                break

    if not local_source:
        primary_project_key = normalize_text(primary_project_name)
        if primary_project_key:
            for entry in normalized_sources:
                if normalize_text(entry.get("project")) == primary_project_key:
                    local_source = dict(entry)
                    break

    if not local_source and len(normalized_sources) == 1:
        local_source = dict(normalized_sources[0])

    local_registry_bytes = max(safe_int(local_source.get("payload_bytes")), 0)
    if local_registry_bytes <= 0 and not normalized_sources:
        local_registry_bytes = payload_bytes

    registry_scope = "none"
    if detected:
        dominant_matches_local = False
        if dominant_source and local_source:
            dominant_file = str(dominant_source.get("file") or "").strip()
            local_file = str(local_source.get("file") or "").strip()
            if dominant_file and local_file:
                dominant_matches_local = os.path.realpath(dominant_file) == os.path.realpath(local_file)
            else:
                dominant_matches_local = normalize_text(dominant_source.get("project")) == normalize_text(local_source.get("project"))
        elif dominant_source and primary_project_name:
            dominant_matches_local = normalize_text(dominant_source.get("project")) == normalize_text(primary_project_name)

        registry_scope = (
            "cross_project"
            if dominant_source and not dominant_matches_local and local_registry_bytes < TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
            else "local"
        )

    return {
        "task_registry_payload_bytes": payload_bytes,
        "task_registry_pressure_detected": detected,
        # The dashboard remains the highest-frequency registry reader under the current fixed poll topology.
        "task_registry_pressure_primary_surface": "dashboard_read_path" if detected else "",
        "task_registry_pressure_sources": normalized_sources,
        "shared_registry_bytes": payload_bytes,
        "local_registry_bytes": local_registry_bytes,
        "registry_pressure_scope": registry_scope,
        "registry_pressure_dominant_source": dominant_source,
        "registry_pressure_local_source": local_source,
    }


def build_persisted_metrics(
    tasks: list[dict[str, Any]],
    records: list[dict[str, Any]],
    external_signals: dict[str, Any] | None = None,
    task_registry_payload_bytes: int | None = None,
    task_registry_pressure_sources: list[dict[str, Any]] | None = None,
    primary_registry_path: str | None = None,
    primary_project_name: str | None = "codex-agent-system",
) -> dict[str, Any]:
    total_records = len(records)
    success_records = sum(1 for record in records if str(record.get("result") or "").strip() == "SUCCESS")
    tasks_by_id = build_task_index_by_id(tasks)
    latest_success_by_identity = build_latest_success_timestamp_by_identity(records)
    timeout_failure_records = sum(
        1 for record in records if is_unresolved_timeout_record(record, tasks_by_id, latest_success_by_identity)
    )
    timeout_failure_events = sum(
        1
        for record in records
        if str(record.get("result") or "").strip() == "FAILURE"
        and str(record.get("failure_kind") or "").strip() == "timeout"
    )
    pending_approval = sum(1 for task in tasks if normalize_status(task.get("status")) == "pending_approval")
    approved = sum(1 for task in tasks if normalize_status(task.get("status")) == "approved")
    queued = sum(1 for task in tasks if normalize_status(task.get("status")) == "queued")
    running = sum(1 for task in tasks if normalize_status(task.get("status")) == "running")
    # v23: separate local vs cross-project counts to prevent phantom backlog inflation
    _local_tasks = [t for t in tasks if not (isinstance(t, dict) and t.get("_cross_project"))]
    local_approved = sum(1 for t in _local_tasks if normalize_status(t.get("status")) == "approved")
    cross_project_approved = approved - local_approved
    last_score = safe_float(tasks[-1].get("score")) if tasks else 0.0
    first_pass_signal = build_first_pass_success_signal(tasks, records)
    loop_effort_signal = build_loop_effort_signal(tasks)
    strategy_saturation_signal = build_strategy_saturation_signal(tasks)
    board_health_signals = build_persisted_board_health_signals(tasks)
    external_signal_summary = build_external_signal_summary(external_signals)
    task_registry_pressure_signal = build_task_registry_pressure_signal(
        tasks,
        task_registry_payload_bytes,
        task_registry_pressure_sources,
        primary_registry_path,
        primary_project_name,
    )

    # Recent success rate (last 50 completed tasks) to track learning trend
    recent_window = 50
    recent_completed = [r for r in records if r.get("result") in {"SUCCESS", "FAILURE"}][-recent_window:]
    recent_successes = sum(1 for r in recent_completed if r.get("result") == "SUCCESS")
    recent_success_rate = round(recent_successes / len(recent_completed), 2) if recent_completed else 0

    # Iteration trend: compare success rate across 50-task windows to detect improvement
    iteration_trend = _compute_iteration_trend(records)

    # Zero-step timeout count: tasks that timeout without executing any steps (planning overhead)
    zero_step_timeouts = sum(
        1 for r in records
        if str(r.get("result") or "").strip() == "FAILURE"
        and str(r.get("failure_kind") or "").strip() == "timeout"
        and safe_int(r.get("total_step_attempts")) == 0
    )

    # Zombie task detection: same task title failing 5+ times (wasted worker slots)
    from collections import Counter
    task_failure_counts = Counter(
        normalize_text(r.get("task"))
        for r in records
        if str(r.get("result") or "").strip() == "FAILURE"
        and normalize_text(r.get("task"))
    )
    zombie_task_count = sum(1 for count in task_failure_counts.values() if count >= 5)
    zombie_wasted_slots = sum(count for count in task_failure_counts.values() if count >= 5)

    # Diagnostic coverage: % of failure records that have a non-empty failed_step field
    failure_records = [r for r in records if str(r.get("result") or "").strip() == "FAILURE"]
    failures_with_diagnostic = sum(
        1 for r in failure_records
        if normalize_text(r.get("failed_step"))
    )
    diagnostic_coverage = round(failures_with_diagnostic / len(failure_records), 2) if failure_records else 0
    # Recent diagnostic coverage (last 50 failures)
    recent_failures = failure_records[-50:]
    recent_diag = sum(1 for r in recent_failures if normalize_text(r.get("failed_step")))
    recent_diagnostic_coverage = round(recent_diag / len(recent_failures), 2) if recent_failures else 0

    return {
        "total_tasks": total_records,
        "success_rate": round(success_records / total_records, 2) if total_records else 0,
        "recent_success_rate": recent_success_rate,
        "recent_window_size": len(recent_completed),
        "timeout_failure_records": timeout_failure_records,
        "timeout_failure_rate": round(timeout_failure_records / total_records, 2) if total_records else 0,
        "analysis_runs": len(tasks),
        "pending_approval_tasks": pending_approval,
        "approved_tasks": local_approved,
        "approved_backlog": local_approved,
        "approved_tasks_cross_project": cross_project_approved,
        "queued_tasks": queued,
        "running_tasks": running,
        "task_registry_total": len(tasks),
        "task_registry_payload_bytes": task_registry_pressure_signal["task_registry_payload_bytes"],
        "task_registry_pressure_bytes": task_registry_pressure_signal["task_registry_payload_bytes"],
        "task_registry_pressure_detected": task_registry_pressure_signal["task_registry_pressure_detected"],
        "task_registry_pressure_primary_surface": task_registry_pressure_signal["task_registry_pressure_primary_surface"],
        "task_registry_pressure_sources": task_registry_pressure_signal["task_registry_pressure_sources"],
        "shared_registry_bytes": task_registry_pressure_signal["shared_registry_bytes"],
        "local_registry_bytes": task_registry_pressure_signal["local_registry_bytes"],
        "registry_pressure_scope": task_registry_pressure_signal["registry_pressure_scope"],
        "registry_pressure_dominant_source": task_registry_pressure_signal["registry_pressure_dominant_source"],
        "registry_pressure_local_source": task_registry_pressure_signal["registry_pressure_local_source"],
        "last_task_score": last_score,
        "manual_recovery_records": manual_recovery_records(records),
        "low_first_pass_success_detected": first_pass_signal["detected"],
        "strategy_saturation_detected": strategy_saturation_signal["detected"],
        "strategy_saturation": strategy_saturation_signal["detected"],
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
        **_compute_learning_efficiency(records, tasks),
        **iteration_trend,
        "zero_step_timeout_count": zero_step_timeouts,
        # Measure planning overhead against observed timeout events, not unresolved timeout pressure.
        "zero_step_timeout_rate": round(zero_step_timeouts / timeout_failure_events, 2) if timeout_failure_events else 0,
        "zombie_task_count": zombie_task_count,
        "zombie_wasted_slots": zombie_wasted_slots,
        "diagnostic_coverage": diagnostic_coverage,
        "recent_diagnostic_coverage": recent_diagnostic_coverage,
        "failures_with_diagnostic": failures_with_diagnostic,
        "total_failure_records": len(failure_records),
        **_compute_self_improve_pause_signal(),
        **_compute_pipeline_staleness(records, tasks),
    }


def _compute_self_improve_pause_signal() -> dict[str, Any]:
    """Surface the self-improve pause gate in shared metrics.

    The pause file can block the entire autonomous improvement loop for hours,
    but until now that state only lived in self-improve-run.json. Persist it in
    metrics so downstream automation and triage can prioritize the real blocker
    instead of stale historical weakness signals.
    """
    pause_file = Path(os.environ.get("SELF_IMPROVE_PAUSE_FILE", "codex-logs/self-improve-paused"))
    threshold_seconds = max(
        0,
        safe_int(os.environ.get("SELF_IMPROVE_PAUSE_ESCALATION_SECONDS"), 21600),
    )

    resolved_path = str(pause_file.resolve())
    if not pause_file.exists():
        return {
            "self_improve_paused": False,
            "self_improve_pause_reason": "inactive",
            "self_improve_pause_file": resolved_path,
            "self_improve_pause_detected_at": "",
            "self_improve_pause_age_seconds": 0,
            "self_improve_pause_escalated": False,
        }

    try:
        detected_at = datetime.fromtimestamp(pause_file.stat().st_mtime, timezone.utc)
    except OSError:
        detected_at = None

    now_utc = datetime.now(timezone.utc)
    age_seconds = 0
    detected_at_text = ""
    if detected_at is not None:
        age_seconds = max(int((now_utc - detected_at).total_seconds()), 0)
        detected_at_text = detected_at.isoformat(timespec="seconds").replace("+00:00", "Z")

    return {
        "self_improve_paused": True,
        "self_improve_pause_reason": "paused_by_file",
        "self_improve_pause_file": resolved_path,
        "self_improve_pause_detected_at": detected_at_text,
        "self_improve_pause_age_seconds": age_seconds,
        "self_improve_pause_escalated": age_seconds >= threshold_seconds if threshold_seconds > 0 else True,
    }


def _compute_pipeline_staleness(
    records: list[dict[str, Any]],
    tasks: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Detect if the pipeline has been idle for >6 hours since the last success.

    Iteration 10: A stale pipeline indicates that all gates/guards have created
    a deadlock. The pipeline_stale flag is used by strategy to override blocking
    health flags and allow recovery task generation. Recent active execution
    should suppress the stale flag even when the last success is older.
    """
    from datetime import timedelta

    stale_window = timedelta(hours=6)
    latest_active_at: datetime | None = None

    local_tasks = [
        task for task in (tasks or [])
        if isinstance(task, dict) and not task.get("_cross_project")
    ]

    for task in local_tasks:
        if not isinstance(task, dict):
            continue

        task_status = normalize_status(task.get("status"))
        execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
        execution_state = normalize_status(execution.get("state"))

        if task_status not in {"queued", "running"} and execution_state not in {"queued", "running", "retrying"}:
            continue

        active_at_text = first_non_empty_text(
            execution.get("updated_at"),
            task.get("updated_at"),
            task.get("approved_at"),
            task.get("created_at"),
        )
        active_at = normalize_datetime_utc(parse_timestamp(active_at_text))
        if active_at is None:
            continue
        if latest_active_at is None or active_at > latest_active_at:
            latest_active_at = active_at

    now_utc = datetime.now(timezone.utc)
    if latest_active_at is not None and (now_utc - latest_active_at) <= stale_window:
        return {"pipeline_stale": False, "pipeline_stale_since": None}

    if not records and not local_tasks:
        return {"pipeline_stale": False, "pipeline_stale_since": None}

    if not records:
        return {"pipeline_stale": True, "pipeline_stale_since": None}

    last_success_at: datetime | None = None
    last_success_at_text = ""
    for record in records:
        if normalize_text(record.get("result")) != "success":
            continue
        ts_str = str(
            record.get("completed_at")
            or record.get("updated_at")
            or record.get("created_at")
            or record.get("timestamp")
            or ""
        ).strip()
        if not ts_str:
            continue
        ts = normalize_datetime_utc(parse_timestamp(ts_str))
        if ts is None:
            continue
        if last_success_at is None or ts > last_success_at:
            last_success_at = ts
            last_success_at_text = ts_str

    if last_success_at is None:
        return {"pipeline_stale": True, "pipeline_stale_since": None}

    stale = (now_utc - last_success_at) > stale_window
    return {
        "pipeline_stale": stale,
        "pipeline_stale_since": last_success_at_text if stale else None,
    }


def _compute_iteration_trend(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Compare success rate across 50-task windows to detect improvement over time."""
    completed = [r for r in records if str(r.get("result") or "").strip() in {"SUCCESS", "FAILURE"}]
    if len(completed) < 50:
        return {
            "iteration_trend_windows": [],
            "iteration_trend_improving": False,
            "iteration_trend_delta_pp": 0.0,
        }
    window_size = 50
    windows = []
    for i in range(0, len(completed), window_size):
        chunk = completed[i:i + window_size]
        if len(chunk) < 10:
            continue
        s = sum(1 for r in chunk if str(r.get("result") or "").strip() == "SUCCESS")
        rate = round(s / len(chunk), 2)
        timeouts = sum(1 for r in chunk if str(r.get("failure_kind") or "").strip() == "timeout")
        windows.append({"window": f"{i + 1}-{i + len(chunk)}", "rate": rate, "timeouts": timeouts})

    if len(windows) >= 4:
        # Compare the RECENT 3 windows vs the 3 windows before them.
        # Previous method (first-half vs second-half) was misleading when
        # early windows had high rates and recent windows collapsed to 0%.
        recent_count = min(3, len(windows) // 2)
        recent_windows = windows[-recent_count:]
        prior_windows = windows[-(2 * recent_count):-recent_count]
        avg_prior = sum(w["rate"] for w in prior_windows) / len(prior_windows)
        avg_recent = sum(w["rate"] for w in recent_windows) / len(recent_windows)
        delta = round((avg_recent - avg_prior) * 100, 1)
        improving = avg_recent > avg_prior
    elif len(windows) >= 2:
        avg_first = windows[0]["rate"]
        avg_last = windows[-1]["rate"]
        delta = round((avg_last - avg_first) * 100, 1)
        improving = avg_last > avg_first
    else:
        delta = 0.0
        improving = False

    # Improvement velocity: percentage points gained per 100 tasks
    # Uses linear regression on window rates to measure acceleration
    velocity = 0.0
    if len(windows) >= 3:
        n = len(windows)
        x_vals = list(range(n))
        y_vals = [w["rate"] for w in windows]
        x_mean = sum(x_vals) / n
        y_mean = sum(y_vals) / n
        numerator = sum((x - x_mean) * (y - y_mean) for x, y in zip(x_vals, y_vals))
        denominator = sum((x - x_mean) ** 2 for x in x_vals)
        if denominator > 0:
            slope = numerator / denominator  # rate change per window
            velocity = round(slope * 100 * 2, 2)  # pp per 100 tasks (2 windows = 100 tasks)

    # Non-timeout learning velocity: isolate signal from environmental timeout noise
    # Only count tasks that actually ran (exclude timeouts) to measure code-level learning
    non_timeout_completed = [
        r for r in completed
        if str(r.get("failure_kind") or "").strip() != "timeout"
    ]
    non_timeout_windows = []
    for i in range(0, len(non_timeout_completed), window_size):
        chunk = non_timeout_completed[i:i + window_size]
        if len(chunk) < 10:
            continue
        s = sum(1 for r in chunk if str(r.get("result") or "").strip() == "SUCCESS")
        rate = round(s / len(chunk), 2)
        non_timeout_windows.append({"window": f"{i + 1}-{i + len(chunk)}", "rate": rate})

    non_timeout_velocity = 0.0
    non_timeout_improving = False
    if len(non_timeout_windows) >= 2:
        nt_first = non_timeout_windows[:len(non_timeout_windows) // 2]
        nt_second = non_timeout_windows[len(non_timeout_windows) // 2:]
        nt_avg_first = sum(w["rate"] for w in nt_first) / len(nt_first)
        nt_avg_second = sum(w["rate"] for w in nt_second) / len(nt_second)
        non_timeout_improving = nt_avg_second > nt_avg_first
    if len(non_timeout_windows) >= 3:
        n_nt = len(non_timeout_windows)
        x_nt = list(range(n_nt))
        y_nt = [w["rate"] for w in non_timeout_windows]
        x_nt_mean = sum(x_nt) / n_nt
        y_nt_mean = sum(y_nt) / n_nt
        num_nt = sum((x - x_nt_mean) * (y - y_nt_mean) for x, y in zip(x_nt, y_nt))
        den_nt = sum((x - x_nt_mean) ** 2 for x in x_nt)
        if den_nt > 0:
            slope_nt = num_nt / den_nt
            non_timeout_velocity = round(slope_nt * 100 * 2, 2)

    return {
        "iteration_trend_windows": windows,
        "iteration_trend_improving": improving,
        "iteration_trend_delta_pp": delta,
        "improvement_velocity_pp_per_100": velocity,
        "non_timeout_success_rate": round(
            sum(1 for r in non_timeout_completed if str(r.get("result") or "").strip() == "SUCCESS") / len(non_timeout_completed), 2
        ) if non_timeout_completed else 0,
        "non_timeout_task_count": len(non_timeout_completed),
        "non_timeout_velocity_pp_per_100": non_timeout_velocity,
        "non_timeout_improving": non_timeout_improving,
    }


def unique_markdown_bullet_rules(*paths: Path) -> set[str]:
    unique_rules: set[str] = set()
    for path in paths:
        if not isinstance(path, Path) or not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped.startswith("- "):
                continue
            normalized_rule = re.sub(r"\s+", " ", stripped[2:].strip())
            if normalized_rule:
                unique_rules.add(normalized_rule)
    return unique_rules


def _compute_learning_efficiency(records: list[dict], tasks: list[dict]) -> dict:
    """Compute learning efficiency metrics to track whether the system improves over time."""
    import os
    from pathlib import Path

    # Count active learned guidance across both persistent learned rules and prompt rules.
    # Both files influence future decisions, so the metric should reflect the union.
    rules_file = Path(os.environ.get("RULES_FILE", "codex-learning/rules.md"))
    prompt_rules_file = Path(os.environ.get("PROMPT_RULES_FILE", "codex-learning/prompt-rules.md"))
    rules_count = len(unique_markdown_bullet_rules(rules_file, prompt_rules_file))

    # Count knowledge.json entries
    knowledge_file = Path(os.environ.get("KNOWLEDGE_FILE", "codex-memory/knowledge.json"))
    knowledge_count = 0
    if knowledge_file.exists():
        try:
            import json as _json
            knowledge = _json.loads(knowledge_file.read_text(encoding="utf-8"))
            knowledge_count = len(knowledge.get("rules", []))
        except Exception:
            pass

    # Count retry-failure-analysis classifications
    retry_file = Path(os.environ.get("RETRY_ANALYSIS_LOG", "codex-learning/retry-failure-analysis.jsonl"))
    retry_total = 0
    retry_classified = 0
    retry_reclassified = 0
    retry_failure_kind_index = build_retry_failure_kind_index(records)
    if retry_file.exists():
        import json as _json
        for line in retry_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = _json.loads(line)
                retry_total += 1
                effective_classification = effective_retry_classification(entry, retry_failure_kind_index)
                if effective_classification != "unknown":
                    retry_classified += 1
                    if normalize_text(entry.get("classification")) in {"", "unknown"}:
                        retry_reclassified += 1
            except Exception:
                pass

    # Compute learning rate: rules per 100 tasks
    total = len(records) if records else 1
    learning_rate = round(rules_count / (total / 100), 2) if total > 0 else 0

    # Classification coverage: % of retries with non-unknown classification
    classification_coverage = round(retry_classified / retry_total, 2) if retry_total > 0 else 0

    return {
        "learning_rules_count": rules_count,
        "learning_knowledge_count": knowledge_count,
        "learning_rate_per_100_tasks": learning_rate,
        "retry_classification_coverage": classification_coverage,
        "retry_classified_count": retry_classified,
        "retry_total_count": retry_total,
        "retry_reclassified_count": retry_reclassified,
    }
