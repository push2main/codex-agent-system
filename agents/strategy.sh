#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap strategy

PROJECT_NAME="${1:-codex-agent-system}"
OUTPUT_FILE="${2:-$LOG_DIR/strategy-latest.json}"
SETTINGS_FILE="$ROOT_DIR/codex-memory/dashboard-settings.json"
QUEUE_DIR="$ROOT_DIR/queues"
PROJECTS_DIR="$ROOT_DIR/projects"

require_command strategy jq
require_command strategy python3
ensure_runtime_dirs
refresh_external_signals >/dev/null 2>&1 || true
mkdir -p "$(dirname "$OUTPUT_FILE")"

python3 - "$ROOT_DIR" "$PROJECT_NAME" "$TASK_REGISTRY_FILE" "$TASK_LOG" "$METRICS_FILE" "$OUTPUT_FILE" "$SETTINGS_FILE" "$QUEUE_DIR" "$PROJECTS_DIR" "$EXTERNAL_SIGNALS_FILE" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any


root_dir, project_name, tasks_path, task_log_path, metrics_path, output_path, settings_path, queues_dir, projects_dir, external_signals_path = sys.argv[1:]

DEFAULT_PRIORITY_CATEGORIES = {
    "stability": {"weight": 1.8, "success_rate": 0.76},
    "ui": {"weight": 1.35, "success_rate": 0.81},
    "performance": {"weight": 1.1, "success_rate": 0.70},
    "code_quality": {"weight": 1.05, "success_rate": 0.79},
}
REFRESH_COOLDOWN_SECONDS = 1800
ENTERPRISE_ACTIONABLE_TARGET = 3
SYSTEM_WORK_BUFFER_THRESHOLD = 2
STRATEGY_SATURATED_FAILURE_THRESHOLD = 2
DEFAULT_PROVIDER = "codex"
ENTERPRISE_TEMPLATES = [
    {
        "key": "enterprise_mobile_console",
        "title": "Tighten the mobile dashboard into an enterprise control surface",
        "category": "ui",
        "impact": 8,
        "effort": 3,
        "confidence": 0.82,
        "reason": "Enterprise readiness still depends on a mobile dashboard that feels trustworthy on iPhone and iPad under active operations.",
        "hypothesis": "If the dashboard reads like an enterprise control surface on iPhone and iPad, operators will approve and supervise work faster with less ambiguity.",
        "experiment": "Improve only one small mobile dashboard surface at a time, preserving the existing information architecture and audit visibility.",
        "success_criteria": [
            "The chosen mobile surface looks denser and more deliberate without removing existing controls.",
            "The change works on iPhone and iPad widths without introducing layout regressions.",
            "Existing task approval and queue controls remain visible.",
        ],
        "rollback": "Remove the mobile refinement and restore the previous dashboard presentation.",
    },
    {
        "key": "enterprise_live_work_observability",
        "title": "Make active worker ownership and progress explicit in the dashboard",
        "category": "stability",
        "impact": 8,
        "effort": 3,
        "confidence": 0.83,
        "reason": "Enterprise operation still needs clearer live visibility into what each worker, lane, and provider is doing right now.",
        "hypothesis": "If active work ownership and progress are visible directly in the dashboard, operators can trust parallel execution more easily.",
        "experiment": "Surface one more deterministic live-work signal in the dashboard without changing queue semantics.",
        "success_criteria": [
            "The dashboard shows at least one additional live-work ownership or progress signal.",
            "Provider and lane context remain readable on mobile widths.",
            "The new signal is derived from existing runtime state, not ad-hoc text.",
        ],
        "rollback": "Remove the added live-work signal and restore the previous dashboard state.",
    },
    {
        "key": "enterprise_audit_governance",
        "title": "Surface security, audit, and governance readiness in the dashboard",
        "category": "stability",
        "impact": 9,
        "effort": 3,
        "confidence": 0.84,
        "reason": "The system needs stronger enterprise trust signals around auditability, governance, and execution safety.",
        "hypothesis": "If security, audit, and governance readiness are visible and structured in the dashboard, the system will be easier to operate as an enterprise workflow.",
        "experiment": "Add one bounded dashboard surface for audit, governance, or security readiness without changing queue execution.",
        "success_criteria": [
            "At least one audit or governance readiness signal is visible from the dashboard.",
            "The signal is sourced from deterministic runtime or registry data.",
            "Operators can tell whether governance posture is improving without reading raw logs.",
        ],
        "rollback": "Remove the added governance surface and return to the previous dashboard state.",
    },
    {
        "key": "enterprise_learning_feedback",
        "title": "Feed execution learning back into future provider and task decisions",
        "category": "code_quality",
        "impact": 9,
        "effort": 3,
        "confidence": 0.81,
        "reason": "The self-improving loop still needs tighter feedback from past runs into future provider routing and task shaping decisions.",
        "hypothesis": "If execution outcomes are fed back into future provider and task decisions more directly, the system will improve faster instead of only recording history.",
        "experiment": "Implement one small deterministic feedback path from execution history into later planning, routing, or task shaping.",
        "success_criteria": [
            "A later decision path consumes structured data from earlier runs.",
            "The change stays deterministic and bounded to one feedback surface.",
            "A focused test proves the learning signal changes the next decision deterministically.",
        ],
        "rollback": "Remove the new feedback path and restore the previous decision logic.",
    },
]


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path: str, fallback: dict[str, Any]) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return dict(fallback)


def normalize_approval_mode(value: Any) -> str:
    return "auto" if normalize_text(value) == "auto" else "manual"


def read_dashboard_settings() -> dict[str, Any]:
    payload = read_json(settings_path, {"approval_mode": "manual"})
    return {
        "approval_mode": normalize_approval_mode(
            payload.get("approval_mode") or payload.get("approvalMode") or ("auto" if payload.get("auto_approve") else "manual")
        )
    }


def read_external_signals() -> list[dict[str, Any]]:
    payload = read_json(external_signals_path, {"signals": []})
    signals = payload.get("signals")
    if not isinstance(signals, list):
        return []
    return [signal for signal in signals if isinstance(signal, dict)]


def read_metrics_snapshot() -> dict[str, Any]:
    return read_json(metrics_path, {})


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


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def safe_int(value: Any, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def sanitize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower())) or "codex-agent-system"


def task_slug(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower()))[:40] or "untitled"


def next_task_registry_id(tasks: list[dict[str, Any]], title: str) -> str:
    highest = 0
    for task in tasks:
        match = re.match(r"^task-(\d+)-", str(task.get("id") or "").strip())
        if not match:
            continue
        highest = max(highest, int(match.group(1) or 0))
    prefix = str(highest + 1).zfill(3)
    return f"task-{prefix}-{task_slug(title)}"


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def parse_utc(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    normalized = text.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def task_timestamp(task: dict[str, Any]) -> str:
    for key in ("failed_at", "updated_at", "created_at"):
        value = str(task.get(key) or "").strip()
        if value:
            return value
    return ""


def strategy_depth(task: dict[str, Any]) -> int:
    try:
        return int(task.get("strategy_depth") or 0)
    except (TypeError, ValueError):
        return 0


def root_source_task_id(task: dict[str, Any]) -> str:
    root_source = str(task.get("root_source_task_id") or "").strip()
    if root_source:
        return root_source
    source = str(task.get("source_task_id") or "").strip()
    if source:
        return source
    return str(task.get("id") or "").strip()


def original_failed_root_id(task: dict[str, Any]) -> str:
    original_failed_root = str(task.get("original_failed_root_id") or "").strip()
    if original_failed_root:
        return original_failed_root
    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate
    return str(task.get("id") or "").strip()


def requirement_root_id(task: dict[str, Any]) -> str:
    return original_failed_root_id(task) or root_source_task_id(task) or str(task.get("id") or "").strip()


def append_history(task: dict[str, Any], entry: dict[str, Any]) -> list[dict[str, Any]]:
    history = task.get("history")
    if not isinstance(history, list):
        history = []
    return [*history[-19:], entry]


def build_history_entry(task: dict[str, Any], action: str, from_status: str, to_status: str, note: str, *, at: str, project: str, queue_task: str) -> dict[str, Any]:
    return {
        "at": at,
        "action": action,
        "from_status": from_status,
        "to_status": to_status,
        "project": project,
        "queue_task": queue_task,
        "note": note,
    }


def read_priority_categories() -> dict[str, dict[str, float]]:
    path = os.path.join(root_dir, "codex-memory", "priority.json")
    payload = read_json(path, {"categories": DEFAULT_PRIORITY_CATEGORIES})
    raw_categories = payload.get("categories")
    if not isinstance(raw_categories, dict):
        return DEFAULT_PRIORITY_CATEGORIES

    normalized: dict[str, dict[str, float]] = {}
    for name, config in raw_categories.items():
        if not isinstance(config, dict):
            continue
        try:
            weight = float(config.get("weight", 1))
        except (TypeError, ValueError):
            weight = 1.0
        try:
            success_rate = float(config.get("success_rate", 0.8))
        except (TypeError, ValueError):
            success_rate = 0.8
        normalized[str(name)] = {
            "weight": weight,
            "success_rate": max(0.0, min(success_rate, 1.0)),
        }
    return normalized or DEFAULT_PRIORITY_CATEGORIES


def task_score(impact: int, effort: int, confidence: float, category_weight: float) -> float:
    return round((impact * confidence * category_weight) / max(effort, 1), 2)


def manual_recovery_records(records: list[dict[str, Any]]) -> int:
    return sum(1 for record in records if str(record.get("source") or "").strip() == "manual_recovery")


def build_metrics(tasks: list[dict[str, Any]], records: list[dict[str, Any]]) -> dict[str, Any]:
    # Preserve fields written by scripts/task_metrics.py (e.g. low_completion_drain_detected)
    try:
        with open(metrics_path, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
        if not isinstance(existing, dict):
            existing = {}
    except Exception:
        existing = {}
    total_records = len(records)
    success_records = sum(1 for record in records if str(record.get("result") or "").strip() == "SUCCESS")
    pending_approval = sum(1 for task in tasks if normalize_text(task.get("status")) == "pending_approval")
    approved = sum(1 for task in tasks if normalize_text(task.get("status")) == "approved")
    last_score = float(tasks[-1].get("score") or 0) if tasks else 0.0
    existing.update({
        "total_tasks": total_records,
        "success_rate": round(success_records / total_records, 2) if total_records else 0,
        "analysis_runs": len(tasks),
        "pending_approval_tasks": pending_approval,
        "approved_tasks": approved,
        "task_registry_total": len(tasks),
        "last_task_score": last_score,
        "manual_recovery_records": manual_recovery_records(records),
    })
    return existing


def build_provider_selection(provider: str = DEFAULT_PROVIDER) -> dict[str, Any]:
    normalized = provider if provider in {"codex", "claude"} else DEFAULT_PROVIDER
    return {
        "selected": normalized,
        "source": "strategy_default",
        "reason": f"Strategy defaults enterprise follow-up tasks to {normalized} unless a task pins a different provider.",
        "updated_at": now_utc(),
    }


def build_execution_brief(*, approved_at: str, project: str, queue_task: str, provider: str, queue_status: str) -> dict[str, Any]:
    return {
        "approved_at": approved_at,
        "project": sanitize_project(project),
        "queue_task": str(queue_task or "").strip(),
        "provider": provider if provider in {"codex", "claude"} else DEFAULT_PROVIDER,
        "status": queue_status,
    }


def append_queue_task(project: str, queue_task: str) -> str:
    os.makedirs(projects_dir, exist_ok=True)
    os.makedirs(queues_dir, exist_ok=True)
    normalized_project = sanitize_project(project)
    os.makedirs(os.path.join(projects_dir, normalized_project), exist_ok=True)
    queue_file = os.path.join(queues_dir, f"{normalized_project}.txt")
    existing_lines: list[str] = []
    if os.path.exists(queue_file):
        with open(queue_file, "r", encoding="utf-8") as handle:
            existing_lines = [line.strip() for line in handle if line.strip()]
    if queue_task in existing_lines:
        return "already_queued"
    with open(queue_file, "a", encoding="utf-8") as handle:
        handle.write(f"{queue_task}\n")
    return "queued"


def finalize_task_for_approval(task: dict[str, Any], approval_mode: str) -> dict[str, Any]:
    _ = approval_mode
    return task


def strategy_template(task: dict[str, Any]) -> dict[str, Any]:
    title = str(task.get("title") or "").strip()
    reason = str(task.get("reason") or "").strip()
    combined = normalize_text(f"{title} {reason}")
    category = normalize_text(task.get("category")) or "stability"
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    failed_step = str(failure_context.get("failed_step") or execution_context.get("failed_step") or "").strip()
    step_count = int(execution_context.get("step_count") or 0)
    broad_task = int(task.get("effort") or 0) >= 4 or step_count >= 4 or len(title.split()) >= 9

    if failed_step and broad_task:
        narrowed_step = re.sub(r"\s+", " ", failed_step).strip().rstrip(".")
        narrowed_title = narrowed_step[:140] if narrowed_step else title[:140]
        child_category = category or "code_quality"
        child_impact = max(4, int(task.get("impact") or 6) - 1)
        child_effort = max(2, min(3, int(task.get("effort") or 3) - 1 or 2))
        child_confidence = round(max(0.72, min(0.86, float(task.get("confidence") or 0.79))), 2)
        return {
            "key": "bounded_failed_step_child",
            "title": narrowed_title,
            "category": child_category,
            "impact": child_impact,
            "effort": child_effort,
            "confidence": child_confidence,
            "reason": f"Task {task.get('id') or title} failed while still spanning too much scope. The narrowest deterministic next step is to complete only the first failed plan step before retrying any broader work.",
            "hypothesis": "If the next run executes only the first failed step from the broader task, the system will recover faster than repeating the full multi-step task at the same size.",
            "experiment": f"Execute only this bounded child step next: {narrowed_step}. Do not implement later plan steps from the parent task in the same run.",
            "success_criteria": [
                "The child task changes only the code needed for this single failed step.",
                "The parent task is not retried as a whole in the same run.",
                "Verification covers the exact failed path named in the child step.",
                "Execution context records that this child task came from a broader failed parent task.",
            ],
            "rollback": "Discard the child-task split and return to the previous whole-task retry behavior.",
        }

    if any(token in combined for token in ("approval", "approved", "brief")):
        return {
            "key": "approval_brief_snapshot",
            "title": "Persist approval-time execution brief snapshots",
            "category": "stability",
            "impact": 8,
            "effort": 3,
            "confidence": 0.83,
            "reason": f"Task {task.get('id') or title} failed after exhausting retries, and the approval path still recomputes queue handoff text instead of freezing a deterministic execution brief at approval time.",
            "hypothesis": "If approval stores a fixed execution_brief snapshot and later queue handoff reads that snapshot unchanged, approved runs will fail less often because retries receive identical structured input.",
            "experiment": "Persist an execution_brief object at approval time and drive approved queue handoff from execution_brief.queue_task without changing pending-task editing.",
            "success_criteria": [
                "Approving a task stores an execution_brief object with deterministic fields for role, objective, project, queue_task, constraints, and success criteria.",
                "Approved queue handoff reads execution_brief.queue_task instead of recomputing raw task text after approval.",
                "Pending-task editing and approval audit history keep working without changing non-approved task behavior.",
                "A deterministic test proves repeated approval of the same task input produces the same stored execution_brief payload.",
            ],
            "rollback": "Remove the approval-time execution_brief snapshot and restore the existing raw-text handoff path.",
        }

    if category == "ui" and any(token in combined for token in ("dashboard", "submitted", "prompt", "task")):
        return {
            "key": "dashboard_task_intent_metadata",
            "title": "Persist dashboard task intent metadata before queue handoff",
            "category": "ui",
            "impact": 7,
            "effort": 3,
            "confidence": 0.8,
            "reason": f"Task {task.get('id') or title} failed after the system tried to reshape raw dashboard task text too late in the flow. A narrower step is to persist intent metadata at task creation before approval or queue handoff changes.",
            "hypothesis": "If dashboard-created backlog items store deterministic intent metadata when they enter tasks.json, later approval and execution steps can consume stable context without rewriting the raw task text in multiple places.",
            "experiment": "Store a task_intent object when dashboard backlog items are created, containing submitter-facing objective, target area, and fixed safety constraints, without changing queue execution yet.",
            "success_criteria": [
                "New dashboard-created pending tasks persist a task_intent object with deterministic keys.",
                "Existing approval, editing, and queue behavior remain unchanged for tasks without task_intent.",
                "The dashboard API returns task_intent for newly created pending tasks.",
                "A deterministic test proves the same dashboard request creates the same task_intent payload on every run.",
            ],
            "rollback": "Remove the task_intent write path and API exposure while leaving the rest of task creation unchanged.",
        }

    if any(token in combined for token in ("restart", "reload", "stale", "runtime", "helper", "session")):
        return {
            "key": "runtime_restart_needed_state",
            "title": "Persist restart-needed runtime state when helper scripts change",
            "category": "stability",
            "impact": 7,
            "effort": 3,
            "confidence": 0.79,
            "reason": f"Task {task.get('id') or title} failed because automatic runtime recovery stayed too broad. The smaller reversible step is to persist a restart-needed signal instead of attempting tmux restarts automatically.",
            "hypothesis": "If the runtime records a deterministic restart-needed state when helper fingerprints diverge, operators can recover stale sessions reliably without attempting unsafe auto-restarts.",
            "experiment": "Detect queue helper fingerprint mismatch and persist a restart-needed state that the dashboard and status command can surface without restarting tmux automatically.",
            "success_criteria": [
                "A helper fingerprint mismatch writes a stable restart-needed flag into runtime state.",
                "agentctl status surfaces the restart-needed state without requiring log inspection.",
                "The queue continues running unchanged until an operator restarts the session.",
                "A deterministic test proves helper changes flip the restart-needed state exactly once until restart.",
            ],
            "rollback": "Remove the restart-needed runtime flag and restore the current stale-helper warning-only behavior.",
        }

    if "auth" in combined and "dashboard" in combined:
        return {
            "key": "dashboard_auth_submission_guard",
            "title": "Block dashboard task submissions during auth cooldown",
            "category": "stability",
            "impact": 7,
            "effort": 3,
            "confidence": 0.8,
            "reason": f"Task {task.get('id') or title} failed because auth-related queue safety was coupled to too many entrypoints at once. A smaller step is to stop new dashboard submissions while the auth cooldown is active.",
            "hypothesis": "If the dashboard rejects new task submissions during a cached auth cooldown, backlog growth will stay bounded and operators will not approve work that cannot execute yet.",
            "experiment": "Reuse the existing auth-health signal in the dashboard task-create endpoint and block new submissions while the cooldown is active, without changing approval behavior.",
            "success_criteria": [
                "The dashboard task-create endpoint rejects new submissions while auth cooldown is active.",
                "The response explains that task creation is paused until Codex authentication recovers.",
                "Approval actions keep their existing auth-block behavior.",
                "A deterministic test proves blocked submissions do not create tasks.json entries.",
            ],
            "rollback": "Remove the task-create auth guard and return to the current submission behavior.",
        }

    return {
        "key": "structured_failure_context",
        "title": "Persist structured failure context for strategy follow-ups",
        "category": "stability",
        "impact": 6,
        "effort": 3,
        "confidence": 0.76,
        "reason": f"Task {task.get('id') or title} failed without enough machine-readable failure context to derive the next smaller experiment deterministically.",
        "hypothesis": "If failed tasks persist a compact structured failure_context payload, later strategy runs can generate narrower successor tasks without relying on free-form log parsing.",
        "experiment": "Persist a failure_context object with failed step index, failing component, and retry outcome whenever queue execution ends in failed state.",
        "success_criteria": [
            "Failed tasks persist a failure_context object with deterministic keys.",
            "Existing dashboard history and execution rendering keep working unchanged.",
            "Strategy runs can derive successor experiments from failure_context without reading raw logs.",
            "A deterministic test proves the same failed run writes the same failure_context payload.",
        ],
        "rollback": "Remove the failure_context payload and restore the current failed-task persistence behavior.",
    }


def find_equivalent_task(tasks: list[dict[str, Any]], project: str, template: dict[str, Any], source_task_id: str) -> dict[str, Any] | None:
    normalized_title = normalize_text(template["title"])
    template_key = template["key"]
    preferred_statuses = {"pending_approval", "approved", "running", "completed", "rejected"}

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        status = normalize_text(task.get("status"))
        if status not in preferred_statuses:
            continue
        same_source = root_source_task_id(task) == source_task_id and str(task.get("strategy_template") or "").strip() == template_key
        same_title = normalize_text(task.get("title")) == normalized_title
        if same_source or same_title:
            return task
    return None


def failed_bounded_child_family_count(tasks: list[dict[str, Any]], project: str, source_task: dict[str, Any]) -> int:
    family_root_id = original_failed_root_id(source_task) or root_source_task_id(source_task) or str(source_task.get("id") or "").strip()
    if not family_root_id:
        return 0

    failed_count = 0
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("status")) != "failed":
            continue
        if str(task.get("strategy_template") or "").strip() != "bounded_failed_step_child":
            continue
        task_family_root_id = original_failed_root_id(task) or root_source_task_id(task) or str(task.get("id") or "").strip()
        if task_family_root_id == family_root_id:
            failed_count += 1
    return failed_count


def needs_refresh(task: dict[str, Any], template: dict[str, Any], source_task: dict[str, Any]) -> bool:
    expected_pairs = {
        "strategy_template": template["key"],
        "hypothesis": template["hypothesis"],
        "experiment": template["experiment"],
        "rollback": template["rollback"],
    }
    for key, value in expected_pairs.items():
        if str(task.get(key) or "").strip() != value:
            return True
    if not isinstance(task.get("success_criteria"), list) or not task.get("success_criteria"):
        return True
    for key in ("title", "category"):
        if str(task.get(key) or "").strip() != str(template.get(key) or "").strip():
            return True
    if int(task.get("impact") or 0) != int(template["impact"]):
        return True
    if int(task.get("effort") or 0) != int(template["effort"]):
        return True
    if round(float(task.get("confidence") or 0), 2) != round(float(template["confidence"]), 2):
        return True
    return False


def refresh_allowed(task: dict[str, Any]) -> bool:
    updated_at = parse_utc(task.get("updated_at") or task.get("created_at"))
    if updated_at is None:
        return True
    age_seconds = max((datetime.now(timezone.utc) - updated_at).total_seconds(), 0)
    return age_seconds >= REFRESH_COOLDOWN_SECONDS


def refresh_task(task: dict[str, Any], source_task: dict[str, Any], template: dict[str, Any], category_weight: float) -> dict[str, Any]:
    transition_at = now_utc()
    next_task = dict(task)
    failed_root_id = original_failed_root_id(source_task)
    related_sources = task.get("related_source_task_ids")
    if not isinstance(related_sources, list):
        related_sources = []
    merged_sources = []
    for source_id in [*related_sources, root_source_task_id(source_task)]:
        normalized = str(source_id or "").strip()
        if normalized and normalized not in merged_sources:
            merged_sources.append(normalized)
    next_task.update(
        {
            "title": template["title"],
            "project": sanitize_project(source_task.get("project")),
            "category": template["category"],
            "impact": template["impact"],
            "effort": template["effort"],
            "confidence": template["confidence"],
            "reason": template["reason"],
            "hypothesis": template["hypothesis"],
            "experiment": template["experiment"],
            "success_criteria": template["success_criteria"],
            "rollback": template["rollback"],
            "source_task_id": root_source_task_id(source_task),
            "source_task_title": str(source_task.get("title") or "").strip(),
            "root_source_task_id": root_source_task_id(source_task),
            "original_failed_root_id": failed_root_id,
            "related_source_task_ids": merged_sources,
            "strategy_template": template["key"],
            "score": task_score(template["impact"], template["effort"], template["confidence"], category_weight),
            "updated_at": transition_at,
        }
    )
    next_task["history"] = append_history(
        next_task,
        build_history_entry(
            next_task,
            "refine",
            normalize_text(task.get("status")) or "pending_approval",
            normalize_text(task.get("status")) or "pending_approval",
            f"Task was refreshed from strategy analysis as the current smallest successor to failed task {source_task.get('id') or source_task.get('title')}.",
            at=transition_at,
            project=next_task["project"],
            queue_task=next_task["title"],
        ),
    )
    return next_task


def create_task(tasks: list[dict[str, Any]], source_task: dict[str, Any], template: dict[str, Any], category_weight: float, approval_mode: str) -> dict[str, Any]:
    transition_at = now_utc()
    project = sanitize_project(source_task.get("project"))
    title = template["title"]
    root_source_id = root_source_task_id(source_task)
    failed_root_id = original_failed_root_id(source_task) or str(source_task.get("id") or "").strip()
    next_task = {
        "id": next_task_registry_id(tasks, title),
        "title": title,
        "impact": template["impact"],
        "effort": template["effort"],
        "confidence": template["confidence"],
        "category": template["category"],
        "project": project,
        "reason": template["reason"],
        "hypothesis": template["hypothesis"],
        "experiment": template["experiment"],
        "success_criteria": template["success_criteria"],
        "rollback": template["rollback"],
        "source_task_id": root_source_id,
        "source_task_title": str(source_task.get("title") or "").strip(),
        "root_source_task_id": root_source_id,
        "original_failed_root_id": failed_root_id,
        "related_source_task_ids": [root_source_id] if root_source_id else [],
        "strategy_template": template["key"],
        "strategy_depth": strategy_depth(source_task) + 1,
        "score": task_score(template["impact"], template["effort"], template["confidence"], category_weight),
        "status": "pending_approval",
        "created_at": transition_at,
        "updated_at": transition_at,
    }
    next_task["history"] = append_history(
        next_task,
        build_history_entry(
            next_task,
            "create",
            "",
            "pending_approval",
            f"Task was added from strategy analysis as the next smaller successor to failed task {source_task.get('id') or source_task.get('title')}.",
            at=transition_at,
            project=project,
            queue_task=title,
        ),
    )
    return finalize_task_for_approval(next_task, approval_mode)


def find_equivalent_seed_task(tasks: list[dict[str, Any]], project: str, template: dict[str, Any]) -> dict[str, Any] | None:
    normalized_title = normalize_text(template["title"])
    template_key = template["key"]
    preferred_statuses = {"pending_approval", "approved", "running", "completed", "rejected"}

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("status")) not in preferred_statuses:
            continue
        if str(task.get("strategy_template") or "").strip() == template_key:
            return task
        if normalize_text(task.get("title")) == normalized_title:
            return task
    return None


def count_failed_seed_equivalents(tasks: list[dict[str, Any]], project: str, template: dict[str, Any]) -> int:
    normalized_title = normalize_text(template["title"])
    template_key = template["key"]
    failed_count = 0

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("status")) != "failed":
            continue
        if str(task.get("strategy_template") or "").strip() == template_key:
            failed_count += 1
            continue
        if normalize_text(task.get("title")) == normalized_title:
            failed_count += 1
    return failed_count


def prioritized_enterprise_templates(tasks: list[dict[str, Any]], project: str) -> list[dict[str, Any]]:
    ranked_templates: list[tuple[bool, int, int, dict[str, Any]]] = []
    for index, template in enumerate(ENTERPRISE_TEMPLATES):
        failed_equivalents = count_failed_seed_equivalents(tasks, project, template)
        ranked_templates.append(
            (
                failed_equivalents >= STRATEGY_SATURATED_FAILURE_THRESHOLD,
                failed_equivalents,
                index,
                template,
            )
        )
    ranked_templates.sort(key=lambda entry: (entry[0], entry[1], entry[2]))
    return [template for _, _, _, template in ranked_templates]


def create_enterprise_seed_task(tasks: list[dict[str, Any]], project: str, template: dict[str, Any], category_weight: float, approval_mode: str) -> dict[str, Any]:
    transition_at = now_utc()
    title = template["title"]
    next_task = {
        "id": next_task_registry_id(tasks, title),
        "title": title,
        "impact": template["impact"],
        "effort": template["effort"],
        "confidence": template["confidence"],
        "category": template["category"],
        "project": project,
        "reason": template["reason"],
        "hypothesis": template["hypothesis"],
        "experiment": template["experiment"],
        "success_criteria": template["success_criteria"],
        "rollback": template["rollback"],
        "source_task_id": f"enterprise-readiness::{project}",
        "source_task_title": "Enterprise readiness backlog",
        "root_source_task_id": f"enterprise-readiness::{project}",
        "original_failed_root_id": f"enterprise-readiness::{project}",
        "related_source_task_ids": [f"enterprise-readiness::{project}"],
        "strategy_template": template["key"],
        "strategy_depth": 0,
        "task_intent": {
            "source": "strategy_seed",
            "objective": title,
            "project": project,
            "category": template["category"],
            "context_hint": "Enterprise readiness backlog",
        },
        "score": task_score(template["impact"], template["effort"], template["confidence"], category_weight),
        "status": "pending_approval",
        "created_at": transition_at,
        "updated_at": transition_at,
        "execution_provider": DEFAULT_PROVIDER,
        "provider_selection": build_provider_selection(DEFAULT_PROVIDER),
    }
    next_task["history"] = append_history(
        next_task,
        build_history_entry(
            next_task,
            "create",
            "",
            "pending_approval",
            "Task was added from enterprise-readiness strategy seeding to keep the backlog improving continuously.",
            at=transition_at,
            project=project,
            queue_task=title,
        ),
    )
    return finalize_task_for_approval(next_task, approval_mode)


def external_signal_sort_key(signal: dict[str, Any]) -> tuple[str, str]:
    return (str(signal.get("published_at") or ""), str(signal.get("id") or ""))


def external_signal_task_title(signal: dict[str, Any]) -> str:
    source_label = str(signal.get("source_label") or signal.get("source_id") or "external signal").strip()
    title = re.sub(r"\s+", " ", str(signal.get("title") or "").strip())
    if len(title) > 72:
        title = title[:69].rstrip() + "..."
    return f"Review external signal: {source_label} - {title}".strip()


def find_equivalent_external_signal_task(tasks: list[dict[str, Any]], project: str, signal: dict[str, Any]) -> dict[str, Any] | None:
    source_task_id = str(signal.get("source_task_id") or "").strip()
    if not source_task_id:
        return None
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if str(task.get("source_task_id") or "").strip() == source_task_id:
            return task
        if str(task.get("root_source_task_id") or "").strip() == source_task_id:
            return task
    return None


def external_signal_learning_snapshot(metrics: dict[str, Any]) -> dict[str, Any]:
    status = normalize_text(metrics.get("external_signal_status"))
    fresh_signal_count = max(safe_int(metrics.get("fresh_external_signal_count")), 0)
    error_count = max(safe_int(metrics.get("external_signal_error_count")), 0)
    confidence = 0.74
    note = ""
    if status == "error" or error_count > 0:
        confidence = 0.58
        note = "Persisted external research has recent refresh errors, so this follow-up stays lower-confidence until signal collection stabilizes."
    elif status in {"stale", "empty", "unavailable"} or (status == "fresh" and fresh_signal_count <= 0):
        confidence = 0.64
        note = "Persisted external research is not currently fresh, so this follow-up keeps reduced confidence until a newer shared snapshot is available."
    return {
        "status": status or "unknown",
        "fresh_signal_count": fresh_signal_count,
        "error_count": error_count,
        "applied_confidence": confidence,
        "note": note,
    }


def create_external_signal_task(
    tasks: list[dict[str, Any]],
    project: str,
    signal: dict[str, Any],
    category_weight: float,
    learning_snapshot: dict[str, Any],
) -> dict[str, Any]:
    transition_at = now_utc()
    title = external_signal_task_title(signal)
    source_task_id = str(signal.get("source_task_id") or f"external-signal::{signal.get('id') or title}").strip()
    category = normalize_text(signal.get("category")) or "code_quality"
    source_label = str(signal.get("source_label") or signal.get("source_id") or "external signal").strip()
    source_title = str(signal.get("title") or source_label).strip()
    source_url = str(signal.get("url") or "").strip()
    task_hint = str(signal.get("task_hint") or "").strip()
    confidence = round(float(learning_snapshot.get("applied_confidence") or 0.74), 2)
    fresh_signal_count = max(safe_int(learning_snapshot.get("fresh_signal_count")), 0)
    error_count = max(safe_int(learning_snapshot.get("error_count")), 0)
    reason = f"External research from {source_label} surfaced a fresh signal that may affect the system before internal failures make the gap obvious."
    learning_note = str(learning_snapshot.get("note") or "").strip()
    if learning_note:
        reason = f"{reason} {learning_note}"
    next_task = {
        "id": next_task_registry_id(tasks, title),
        "title": title,
        "impact": 6,
        "effort": 2,
        "confidence": confidence,
        "category": category,
        "project": project,
        "reason": reason,
        "hypothesis": "If the system reviews bounded external updates regularly, it can adapt earlier instead of learning only from internal failures.",
        "experiment": f"Inspect the referenced external update and derive at most one bounded improvement or explicit no-op. {task_hint}".strip(),
        "success_criteria": [
            "The run inspects the referenced external update and records the concrete implication for the system.",
            "At most one bounded system change is proposed or implemented from this signal.",
            "If the signal is not relevant, the outcome records a deterministic no-op conclusion instead of speculative work.",
        ],
        "rollback": "Remove the external-signal follow-up task and return to internal-signals-only planning.",
        "source_task_id": source_task_id,
        "source_task_title": source_title,
        "root_source_task_id": source_task_id,
        "original_failed_root_id": source_task_id,
        "related_source_task_ids": [source_task_id],
        "strategy_template": "external_signal_review",
        "strategy_depth": 0,
        "task_intent": {
            "source": "strategy_external_signal",
            "objective": title,
            "project": project,
            "category": category,
            "context_hint": source_label,
        },
        "score": task_score(6, 2, confidence, category_weight),
        "status": "pending_approval",
        "created_at": transition_at,
        "updated_at": transition_at,
        "external_signal_learning": {
            "status": str(learning_snapshot.get("status") or "unknown"),
            "fresh_signal_count": fresh_signal_count,
            "error_count": error_count,
            "applied_confidence": confidence,
        },
        "external_signal": {
            "id": str(signal.get("id") or "").strip(),
            "source_id": str(signal.get("source_id") or "").strip(),
            "source_label": source_label,
            "topic": str(signal.get("topic") or "").strip(),
            "title": source_title,
            "url": source_url,
            "published_at": str(signal.get("published_at") or "").strip(),
            "summary": str(signal.get("summary") or "").strip(),
            "task_hint": task_hint,
        },
    }
    next_task["history"] = append_history(
        next_task,
        build_history_entry(
            next_task,
            "create",
            "",
            "pending_approval",
            f"Task was added from bounded external research signal ingestion for {source_label}.",
            at=transition_at,
            project=project,
            queue_task=title,
        ),
    )
    return next_task


def ui_requirement_is_already_covered(tasks: list[dict[str, Any]], source_task: dict[str, Any]) -> bool:
    project = sanitize_project(source_task.get("project"))
    requirement_root = requirement_root_id(source_task)
    source_id = str(source_task.get("id") or "").strip()
    if not project or not requirement_root:
        return False

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if str(task.get("id") or "").strip() == source_id:
            continue
        if requirement_root_id(task) != requirement_root:
            continue
        status = normalize_text(task.get("status"))
        if status in {"pending_approval", "approved", "running", "completed"}:
            return True
    return False


registry = read_json(tasks_path, {"tasks": []})
tasks = [task for task in registry.get("tasks", []) if isinstance(task, dict)]
records = read_json_lines(task_log_path)
priority_categories = read_priority_categories()
project_key = sanitize_project(project_name)
settings = read_dashboard_settings()
approval_mode = settings["approval_mode"]
external_signals = read_external_signals()
metrics_snapshot = read_metrics_snapshot()
external_signal_learning = external_signal_learning_snapshot(metrics_snapshot)

pending_tasks = [
    task
    for task in tasks
    if sanitize_project(task.get("project")) == project_key and normalize_text(task.get("status")) == "pending_approval"
]
actionable_statuses = {"pending_approval", "approved", "running"}
actionable_tasks = [
    task
    for task in tasks
    if sanitize_project(task.get("project")) == project_key and normalize_text(task.get("status")) in actionable_statuses
]
approved_actionable_count = sum(
    1
    for task in tasks
    if sanitize_project(task.get("project")) == project_key and normalize_text(task.get("status")) == "approved"
)
running_actionable_count = sum(
    1
    for task in tasks
    if sanitize_project(task.get("project")) == project_key and normalize_text(task.get("status")) == "running"
)
fresh_external_signals = [
    signal for signal in external_signals if signal.get("fresh") is True and signal.get("source_task_id")
]
fresh_external_signals.sort(key=external_signal_sort_key, reverse=True)

failed_candidates = sorted(
    [
        task
        for task in tasks
        if sanitize_project(task.get("project")) == project_key
        and normalize_text(task.get("status")) == "failed"
        and (
            strategy_depth(task) < 1
            or (normalize_text(task.get("category")) == "ui" and strategy_depth(task) < 2)
        )
    ],
    key=lambda task: (task_timestamp(task), str(task.get("id") or "")),
    reverse=True,
)

actions: list[dict[str, str]] = []
hypotheses: list[dict[str, str]] = []
experiments: list[dict[str, str]] = []
processed_templates: set[str] = set()

for failed_task in failed_candidates:
    if len(actions) >= 2:
        break

    if normalize_text(failed_task.get("category")) == "ui" and ui_requirement_is_already_covered(tasks, failed_task):
        continue

    template = strategy_template(failed_task)
    template_slot = f"{template['key']}::{normalize_text(template['title'])}"
    if template_slot in processed_templates:
        continue

    category_config = priority_categories.get(template["category"], DEFAULT_PRIORITY_CATEGORIES["code_quality"])
    equivalent = find_equivalent_task(tasks, project_key, template, root_source_task_id(failed_task))

    if equivalent is not None:
        processed_templates.add(template_slot)
        if (
            normalize_text(equivalent.get("status")) == "pending_approval"
            and needs_refresh(equivalent, template, failed_task)
            and refresh_allowed(equivalent)
        ):
            for index, existing in enumerate(tasks):
                if str(existing.get("id") or "").strip() != str(equivalent.get("id") or "").strip():
                    continue
                tasks[index] = refresh_task(existing, failed_task, template, float(category_config.get("weight", 1.0)))
                equivalent = tasks[index]
                actions.append({"id": equivalent["id"], "action": "updated", "source_task_id": root_source_task_id(failed_task)})
                hypotheses.append({"task_id": equivalent["id"], "source_task_id": root_source_task_id(failed_task), "hypothesis": template["hypothesis"]})
                experiments.append({"task_id": equivalent["id"], "source_task_id": root_source_task_id(failed_task), "experiment": template["experiment"]})
                break
        continue

    if (
        template["key"] == "bounded_failed_step_child"
        and failed_bounded_child_family_count(tasks, project_key, failed_task) >= STRATEGY_SATURATED_FAILURE_THRESHOLD
    ):
        processed_templates.add(template_slot)
        continue

    if len(pending_tasks) >= 2:
        continue

    created_task = create_task(tasks, failed_task, template, float(category_config.get("weight", 1.0)), approval_mode)
    tasks.append(created_task)
    if normalize_text(created_task.get("status")) == "pending_approval":
        pending_tasks.append(created_task)
    actionable_tasks.append(created_task)
    processed_templates.add(template_slot)
    actions.append({"id": created_task["id"], "action": "created", "source_task_id": root_source_task_id(failed_task)})
    hypotheses.append({"task_id": created_task["id"], "source_task_id": root_source_task_id(failed_task), "hypothesis": template["hypothesis"]})
    experiments.append({"task_id": created_task["id"], "source_task_id": root_source_task_id(failed_task), "experiment": template["experiment"]})

if len(actions) < 2 and len(pending_tasks) < 2:
    for signal in fresh_external_signals:
        if find_equivalent_external_signal_task(tasks, project_key, signal) is not None:
            continue
        category_name = normalize_text(signal.get("category")) or "code_quality"
        category_config = priority_categories.get(category_name, DEFAULT_PRIORITY_CATEGORIES["code_quality"])
        created_task = create_external_signal_task(
            tasks,
            project_key,
            signal,
            float(category_config.get("weight", 1.0)),
            external_signal_learning,
        )
        tasks.append(created_task)
        pending_tasks.append(created_task)
        actionable_tasks.append(created_task)
        signal_source_task_id = str(signal.get("source_task_id") or "").strip()
        actions.append({"id": created_task["id"], "action": "created", "source_task_id": signal_source_task_id})
        hypotheses.append({"task_id": created_task["id"], "source_task_id": signal_source_task_id, "hypothesis": created_task["hypothesis"]})
        experiments.append({"task_id": created_task["id"], "source_task_id": signal_source_task_id, "experiment": created_task["experiment"]})
        break

total_records = len(records)
success_records_count = sum(1 for record in records if str(record.get("result") or "").strip() == "SUCCESS")
completion_rate = round(success_records_count / total_records, 2) if total_records else 0

if (
    len(actions) < 2
    and total_records > 0
    and completion_rate < 0.5
    and (approved_actionable_count + running_actionable_count) < SYSTEM_WORK_BUFFER_THRESHOLD
):
    buffer_template = {
        "key": "system_work_buffer",
        "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
        "category": "stability",
        "impact": 8,
        "effort": 2,
        "confidence": 0.85,
        "reason": "A self-improving system should not sit idle when completion remains weak. If executable work drains while outcomes stay poor, strategy must seed bounded corrective work immediately.",
        "hypothesis": "If strategy seeds bounded corrective work before the queue fully drains under low completion rate, the system will recover faster instead of idling with no executable tasks.",
        "experiment": "Detect low completion rate with a drained executable queue and seed one bounded system-work follow-up task before the queue reaches zero actionable items.",
        "success_criteria": [
            "Strategy seeds a bounded system-work task when completion rate is low and the executable queue is nearly empty.",
            "The seeded task stays within the existing approval flow.",
            "No schemas, payloads, or routing conditions change.",
            "A deterministic test proves the buffer task is created before the queue fully drains.",
        ],
        "rollback": "Remove the system-work buffer seeding guard and restore the previous zero-buffer behavior.",
    }
    buffer_failed_equivalents = count_failed_seed_equivalents(tasks, project_key, buffer_template)
    if (
        find_equivalent_seed_task(tasks, project_key, buffer_template) is None
        and buffer_failed_equivalents < STRATEGY_SATURATED_FAILURE_THRESHOLD
    ):
        category_config = priority_categories.get(buffer_template["category"], DEFAULT_PRIORITY_CATEGORIES["code_quality"])
        transition_at = now_utc()
        buffer_title = buffer_template["title"]
        buffer_task = {
            "id": next_task_registry_id(tasks, buffer_title),
            "title": buffer_title,
            "impact": buffer_template["impact"],
            "effort": buffer_template["effort"],
            "confidence": buffer_template["confidence"],
            "category": buffer_template["category"],
            "project": project_key,
            "reason": buffer_template["reason"],
            "hypothesis": buffer_template["hypothesis"],
            "experiment": buffer_template["experiment"],
            "success_criteria": buffer_template["success_criteria"],
            "rollback": buffer_template["rollback"],
            "source_task_id": "strategy::queue-drain-completion",
            "root_source_task_id": "strategy::queue-drain-completion",
            "original_failed_root_id": "strategy::queue-drain-completion",
            "related_source_task_ids": ["strategy::queue-drain-completion"],
            "strategy_template": buffer_template["key"],
            "strategy_depth": 0,
            "task_intent": {
                "source": "strategy_anomaly",
                "objective": buffer_title,
                "project": project_key,
                "category": buffer_template["category"],
                "context_hint": "Queue drain completion anomaly",
            },
            "score": task_score(buffer_template["impact"], buffer_template["effort"], buffer_template["confidence"], float(category_config.get("weight", 1.0))),
            "status": "pending_approval",
            "created_at": transition_at,
            "updated_at": transition_at,
            "execution_provider": DEFAULT_PROVIDER,
            "provider_selection": build_provider_selection(DEFAULT_PROVIDER),
        }
        buffer_task["history"] = append_history(
            buffer_task,
            build_history_entry(
                buffer_task,
                "create",
                "",
                "pending_approval",
                "Task was added from system-work buffer anomaly detection under low completion rate.",
                at=transition_at,
                project=project_key,
                queue_task=buffer_title,
            ),
        )
        buffer_task = finalize_task_for_approval(buffer_task, approval_mode)
        tasks.append(buffer_task)
        if normalize_text(buffer_task.get("status")) == "pending_approval":
            pending_tasks.append(buffer_task)
        actionable_tasks.append(buffer_task)
        actions.append({"id": buffer_task["id"], "action": "created", "source_task_id": "strategy::queue-drain-completion"})
        hypotheses.append({"task_id": buffer_task["id"], "source_task_id": "strategy::queue-drain-completion", "hypothesis": buffer_template["hypothesis"]})
        experiments.append({"task_id": buffer_task["id"], "source_task_id": "strategy::queue-drain-completion", "experiment": buffer_template["experiment"]})

if len(actions) < 2 and (approved_actionable_count + running_actionable_count) < SYSTEM_WORK_BUFFER_THRESHOLD:
    for template in prioritized_enterprise_templates(tasks, project_key):
        if len(actions) >= 2 or len(actionable_tasks) >= ENTERPRISE_ACTIONABLE_TARGET:
            break
        if count_failed_seed_equivalents(tasks, project_key, template) >= STRATEGY_SATURATED_FAILURE_THRESHOLD:
            continue
        equivalent = find_equivalent_seed_task(tasks, project_key, template)
        if equivalent is not None:
            continue
        category_config = priority_categories.get(template["category"], DEFAULT_PRIORITY_CATEGORIES["code_quality"])
        created_task = create_enterprise_seed_task(
            tasks,
            project_key,
            template,
            float(category_config.get("weight", 1.0)),
            approval_mode,
        )
        tasks.append(created_task)
        if normalize_text(created_task.get("status")) == "pending_approval":
            pending_tasks.append(created_task)
        actionable_tasks.append(created_task)
        status = normalize_text(created_task.get("status"))
        if status == "approved":
            approved_actionable_count += 1
        elif status == "running":
            running_actionable_count += 1
        actions.append(
            {
                "id": created_task["id"],
                "action": "created",
                "source_task_id": "enterprise-readiness",
            }
        )
        hypotheses.append(
            {
                "task_id": created_task["id"],
                "source_task_id": "enterprise-readiness",
                "hypothesis": template["hypothesis"],
            }
        )
        experiments.append(
            {
                "task_id": created_task["id"],
                "source_task_id": "enterprise-readiness",
                "experiment": template["experiment"],
            }
        )

if actions:
    registry["tasks"] = tasks
    write_json(tasks_path, registry)

metrics = build_metrics(tasks, records)
write_json(metrics_path, metrics)

payload = {
    "status": "success",
    "message": (
        f"Applied {len(actions)} strategy board update(s) for {project_key}."
        if actions
        else f"No strategy board changes were needed for {project_key}."
    ),
    "data": {
        "hypotheses": hypotheses,
        "experiments": experiments,
        "board_tasks": actions,
    },
}
write_json(output_path, payload)
PY

print_json_file "$OUTPUT_FILE"
