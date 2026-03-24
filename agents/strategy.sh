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
scripts_dir = os.path.join(root_dir, "scripts")
if scripts_dir not in sys.path:
    sys.path.insert(0, scripts_dir)

try:
    from task_metrics import build_persisted_metrics
except Exception:
    build_persisted_metrics = None

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
RETRY_CHURN_ATTEMPT_THRESHOLD = 2
TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000
TIMEOUT_FAILURE_RECORDS_THRESHOLD = 3
TIMEOUT_FAILURE_RATE_THRESHOLD = 0.12
DEFAULT_PROVIDER = "codex"
ENTERPRISE_TEMPLATES = [
    {
        "key": "enterprise_timeout_stability",
        "title": "Cut queue timeout churn before retries burn worker capacity",
        "category": "stability",
        "impact": 9,
        "effort": 2,
        "confidence": 0.84,
        "reason": "Recent queue executions are still timing out often enough to burn retry budget and worker capacity before the system learns from the failures.",
        "hypothesis": "If strategy prioritizes one bounded timeout-reduction experiment when timeout pressure is already elevated, the system can recover stability faster than by continuing with generic enterprise backlog work.",
        "experiment": "Implement one narrow timeout-reduction change on the highest-friction queue path, such as shrinking task scope, tightening success reconciliation, or improving timeout-specific observability, without changing queue semantics broadly.",
        "success_criteria": [
            "The change targets a concrete timeout-prone queue or orchestration path.",
            "The improvement stays deterministic and bounded to one timeout-reduction surface.",
            "A focused test proves the timeout-reduction behavior or learning signal.",
        ],
        "rollback": "Remove the timeout-reduction change and restore the previous strategy ordering if timeout pressure falls back below the trigger threshold.",
    },
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
    {
        "key": "enterprise_registry_pressure_relief",
        "title": "Cut task-registry read amplification before growth stalls the loop",
        "category": "performance",
        "impact": 8,
        "effort": 2,
        "confidence": 0.83,
        "reason": "The shared task registry is now large enough that repeated full-payload reads can become the next scaling bottleneck if the loop does not prioritize bounded read-path relief.",
        "hypothesis": "If strategy prioritizes one small registry-read performance task when payload pressure is already high, the system can stay responsive without waiting for larger-scale regressions.",
        "experiment": "Implement one bounded optimization or observability change on the hottest task-registry read path, without changing task schemas or queue semantics.",
        "success_criteria": [
            "The change targets an existing high-frequency task-registry read path.",
            "The optimization stays deterministic and preserves current runtime artifacts.",
            "A focused test proves the new read-path behavior or signal.",
        ],
        "rollback": "Remove the bounded registry-read optimization and restore the previous read path.",
    },
]
SATURATION_RESCUE_TEMPLATE = {
    "key": "strategy_saturation_rescue",
    "title": "Choose a different bounded experiment after strategy saturation stalls the board",
    "category": "learning",
    "impact": 8,
    "effort": 2,
    "confidence": 0.84,
    "hypothesis": "If the board surfaces one explicit saturation-recovery task instead of silently no-oping, the next improvement can reuse failure history instead of stalling the loop.",
    "experiment": "Review the saturated strategy families, identify the weakest repeated experiment, and propose one different bounded follow-up that does not reuse the same template or title.",
    "success_criteria": [
        "The next task references the saturated family or title it is replacing.",
        "The proposed follow-up is materially narrower or structurally different from the saturated experiment.",
        "The board keeps one actionable pending-approval item instead of returning an empty strategy result.",
    ],
    "rollback": "Remove the saturation-rescue task and return to the previous silent no-op behavior once another bounded recovery path exists.",
}


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


def read_external_signals_payload() -> dict[str, Any]:
    return read_json(external_signals_path, {"signals": [], "errors": []})


def read_external_signals() -> list[dict[str, Any]]:
    payload = read_external_signals_payload()
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


def discover_task_registry_paths(primary_tasks_path: str) -> list[str]:
    primary_path = os.path.abspath(primary_tasks_path)
    repo_root = os.path.dirname(os.path.dirname(primary_path))
    projects_dir = os.path.join(repo_root, "projects")

    registry_paths: list[str] = []
    seen: set[str] = set()

    def append_path(candidate: str) -> None:
        if not candidate:
            return
        resolved = os.path.realpath(candidate)
        if resolved in seen:
            return
        seen.add(resolved)
        registry_paths.append(candidate)

    append_path(primary_path)
    if not os.path.isdir(projects_dir):
        return registry_paths

    for entry in sorted(os.scandir(projects_dir), key=lambda item: item.name):
        if not entry.is_dir():
            continue
        metadata = read_json(os.path.join(entry.path, "project.json"), {})
        registry_path = str(metadata.get("task_registry_file") or "").strip() or primary_path
        append_path(registry_path)

    return registry_paths


def resolve_project_registry_path(project: str, primary_tasks_path: str, projects_root: str) -> str:
    primary_path = os.path.abspath(primary_tasks_path)
    project_key = sanitize_project(project)
    if not project_key or not os.path.isdir(projects_root):
        return primary_path

    metadata = read_json(os.path.join(projects_root, project_key, "project.json"), {})
    configured_path = str(metadata.get("task_registry_file") or "").strip()
    if not configured_path:
        return primary_path
    return os.path.abspath(os.path.expanduser(configured_path))


def read_registry_tasks(paths: list[str]) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    for registry_path in paths:
        registry = read_json(registry_path, {"tasks": []})
        registry_tasks = registry.get("tasks")
        if not isinstance(registry_tasks, list):
            continue
        tasks.extend(task for task in registry_tasks if isinstance(task, dict))
    return tasks


def registry_payload_bytes(paths: list[str]) -> int:
    total = 0
    seen: set[str] = set()
    for registry_path in paths:
        resolved = os.path.realpath(registry_path)
        if resolved in seen:
            continue
        seen.add(resolved)
        try:
            total += os.path.getsize(resolved)
        except OSError:
            continue
    return total


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


def excerpt_text(value: Any, length: int) -> str:
    text = re.sub(r"\s+", " ", str(value or "").strip())
    if length <= 0:
        return ""
    if len(text) <= length:
        return text
    return text[: max(length - 3, 0)].rstrip() + "..."


def normalize_provider_name(value: Any) -> str:
    provider = normalize_text(value)
    return provider if provider in {"codex", "claude"} else ""


def alternate_provider_name(value: Any) -> str:
    provider = normalize_provider_name(value)
    if provider == "codex":
        return "claude"
    if provider == "claude":
        return "codex"
    return ""


def stable_mapping_without_updated_at(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    return {key: item for key, item in value.items() if key != "updated_at"}


def task_execution_provider(task: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    return (
        normalize_provider_name(execution.get("provider"))
        or normalize_provider_name(execution_context.get("provider"))
        or normalize_provider_name(failure_context.get("provider"))
        or normalize_provider_name(task.get("execution_provider"))
        or normalize_provider_name(provider_selection.get("selected"))
    )


def derive_saturation_recovery_metadata(task: dict[str, Any], tasks: list[dict[str, Any]], project: str) -> dict[str, str] | None:
    strategy_template = normalize_text(task.get("strategy_template") or task.get("strategyTemplate"))
    source_task_id = str(task.get("source_task_id") or task.get("sourceTaskId") or "").strip()
    if strategy_template != "strategy_saturation_rescue" and source_task_id != "strategy::saturation-recovery":
        return None

    existing = task.get("saturation_recovery") if isinstance(task.get("saturation_recovery"), dict) else {}
    normalized_existing = {
        "kind": str(existing.get("kind") or "").strip(),
        "replaces_task_id": str(existing.get("replaces_task_id") or "").strip(),
        "replaces_title": str(existing.get("replaces_title") or "").strip(),
        "replaces_strategy_template": str(existing.get("replaces_strategy_template") or "").strip(),
        "replaces_category": normalize_text(existing.get("replaces_category") or ""),
    }
    if any(normalized_existing.values()):
        if not normalized_existing["kind"]:
            normalized_existing["kind"] = "replace_saturated_experiment"
        return normalized_existing

    reason = str(task.get("reason") or "").strip()
    quoted_match = re.search(r"latest saturated failure is [`'\"]([^`'\"]+)[`'\"]\s*\(([^)]+)\)", reason, re.IGNORECASE)
    unquoted_match = None if quoted_match else re.search(r"latest saturated failure is ([^(]+?)\s*\(([^)]+)\)", reason, re.IGNORECASE)
    parsed_title = str((quoted_match.group(1) if quoted_match else (unquoted_match.group(1) if unquoted_match else "")) or "").strip()
    parsed_template = str((quoted_match.group(2) if quoted_match else (unquoted_match.group(2) if unquoted_match else "")) or "").strip()
    if not parsed_title and not parsed_template:
        return None

    selected_candidate: dict[str, Any] | None = None
    selected_rank: tuple[int, float, str] | None = None
    for candidate in tasks:
        if not isinstance(candidate, dict):
            continue
        if str(candidate.get("id") or "").strip() == str(task.get("id") or "").strip():
            continue
        if sanitize_project(candidate.get("project")) != project:
            continue
        if normalize_text(candidate.get("status")) != "failed":
            continue
        score = 0
        if parsed_title and task_execution_text(candidate) == parsed_title:
            score += 4
        if parsed_template and str(candidate.get("strategy_template") or candidate.get("strategyTemplate") or "").strip() == parsed_template:
            score += 2
        if score <= 0:
            continue
        candidate_timestamp = parse_utc(task_timestamp(candidate))
        rank = (
            score,
            candidate_timestamp.timestamp() if candidate_timestamp is not None else 0.0,
            str(candidate.get("id") or ""),
        )
        if selected_rank is None or rank > selected_rank:
            selected_candidate = candidate
            selected_rank = rank

    return {
        "kind": "replace_saturated_experiment",
        "replaces_task_id": str((selected_candidate or {}).get("id") or "").strip(),
        "replaces_title": task_execution_text(selected_candidate) if isinstance(selected_candidate, dict) else parsed_title,
        "replaces_strategy_template": str(
            (selected_candidate or {}).get("strategy_template")
            or (selected_candidate or {}).get("strategyTemplate")
            or parsed_template
            or ""
        ).strip(),
        "replaces_category": normalize_text(
            (selected_candidate or {}).get("category") or task.get("category") or "code_quality"
        )
        or "code_quality",
    }


def find_saturation_recovery_replaced_task(
    saturation_recovery: dict[str, str] | None,
    tasks: list[dict[str, Any]],
    project: str,
) -> dict[str, Any] | None:
    if not isinstance(saturation_recovery, dict):
        return None

    replaced_task_id = str(saturation_recovery.get("replaces_task_id") or "").strip()
    replaced_title = str(saturation_recovery.get("replaces_title") or "").strip()
    replaced_template = str(saturation_recovery.get("replaces_strategy_template") or "").strip()
    selected_candidate: dict[str, Any] | None = None
    selected_rank: tuple[int, float, str] | None = None

    for candidate in tasks:
        if not isinstance(candidate, dict):
            continue
        if sanitize_project(candidate.get("project")) != project:
            continue

        score = 0
        if replaced_task_id and str(candidate.get("id") or "").strip() == replaced_task_id:
            score += 8
        if replaced_title and task_execution_text(candidate) == replaced_title:
            score += 4
        if replaced_template and str(candidate.get("strategy_template") or candidate.get("strategyTemplate") or "").strip() == replaced_template:
            score += 2
        if score <= 0:
            continue

        candidate_timestamp = parse_utc(task_timestamp(candidate))
        rank = (
            score,
            candidate_timestamp.timestamp() if candidate_timestamp is not None else 0.0,
            str(candidate.get("id") or ""),
        )
        if selected_rank is None or rank > selected_rank:
            selected_candidate = candidate
            selected_rank = rank

    return selected_candidate


def saturation_recovery_failed_step(task: dict[str, Any] | None) -> str:
    if not isinstance(task, dict):
        return ""

    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failed_step = str(failure_context.get("failed_step") or execution_context.get("failed_step") or "").strip()
    if failed_step:
        return re.sub(r"\s+", " ", failed_step).strip().rstrip(".")

    experiment = str(task.get("experiment") or "").strip()
    match = re.search(
        r"Execute only this bounded child step next:\s*(.+?)(?:\.\s*Do not implement later plan steps|\Z)",
        experiment,
        re.IGNORECASE,
    )
    if match:
        return re.sub(r"\s+", " ", str(match.group(1) or "")).strip().rstrip(".")
    return ""


def derive_saturation_recovery_followup_title(
    saturation_recovery: dict[str, str] | None,
    replaced_task: dict[str, Any] | None,
    category: str,
) -> str:
    if not isinstance(saturation_recovery, dict):
        return SATURATION_RESCUE_TEMPLATE["title"]

    replaced_title = str(saturation_recovery.get("replaces_title") or "").strip()
    replaced_category = normalize_text(saturation_recovery.get("replaces_category") or category or "strategy") or "strategy"
    replaced_template = normalize_text(
        (replaced_task or {}).get("strategy_template")
        or (replaced_task or {}).get("strategyTemplate")
        or saturation_recovery.get("replaces_strategy_template")
        or ""
    )
    failed_step = saturation_recovery_failed_step(replaced_task)

    if replaced_template == "bounded_failed_step_child" and failed_step:
        narrowed_match = re.search(
            r"limit (?:the )?follow-up (?:fix )?(?:strictly )?to (?:the )?(.+?)(?: surfaced by .*?| before .*?| while .*?| using .*?| after .*?|$|[.;])",
            failed_step,
            re.IGNORECASE,
        )
        if narrowed_match:
            narrowed_focus = excerpt_text(str(narrowed_match.group(1) or "").strip(), 88).rstrip(".")
            if narrowed_focus:
                return f"Fix {narrowed_focus}"

        verify_match = re.search(
            r"Run [`'\"]?([^`'\"]+)[`'\"]? as the single deterministic verification command",
            failed_step,
            re.IGNORECASE,
        )
        if verify_match and replaced_title:
            command = excerpt_text(str(verify_match.group(1) or "").strip(), 48).rstrip(".")
            if command:
                return f"Verify {excerpt_text(replaced_title, 64)} with `{command}`"
            return f"Verify {excerpt_text(replaced_title, 72)} with one deterministic command"

        candidate = re.split(r"[.;]", failed_step, maxsplit=1)[0].strip()
        candidate = re.sub(r"^Execute only this bounded child step next:\s*", "", candidate, flags=re.IGNORECASE)
        if candidate:
            if re.match(r"^Run\b", candidate, re.IGNORECASE):
                if replaced_title:
                    return f"Verify {excerpt_text(replaced_title, 72)} with one deterministic command"
                candidate = re.sub(r"^Run\b", "Verify", candidate, flags=re.IGNORECASE)
            elif re.match(r"^Inspect\b", candidate, re.IGNORECASE):
                candidate = re.sub(r"^Inspect\b", "Document", candidate, flags=re.IGNORECASE)
            elif re.match(r"^Review\b", candidate, re.IGNORECASE):
                candidate = re.sub(r"^Review\b", "Check", candidate, flags=re.IGNORECASE)
            candidate = excerpt_text(candidate.replace("`", ""), 88).rstrip(".")
            if candidate:
                return candidate

    if replaced_title:
        return f"Replace {excerpt_text(replaced_title, 88)} with a different bounded experiment"
    return f"Replace saturated {replaced_category} experiment with a different bounded task"


def derive_saturation_recovery_context_hint(
    saturation_recovery: dict[str, str] | None,
    replaced_task: dict[str, Any] | None,
    category: str,
) -> str:
    replaced_title = str((saturation_recovery or {}).get("replaces_title") or "").strip()
    replaced_template = normalize_text(
        (replaced_task or {}).get("strategy_template")
        or (replaced_task or {}).get("strategyTemplate")
        or (saturation_recovery or {}).get("replaces_strategy_template")
        or ""
    )
    if replaced_title and replaced_template == "bounded_failed_step_child":
        return f"Derived from saturated experiment: {excerpt_text(replaced_title, 120)}"
    if replaced_title:
        return f"Replace saturated experiment: {excerpt_text(replaced_title, 120)}"
    replaced_category = normalize_text((saturation_recovery or {}).get("replaces_category") or category or "strategy") or "strategy"
    return f"Replace the saturated {replaced_category} experiment with a different bounded follow-up."


def derive_saturation_recovery_verification_command(
    saturation_recovery: dict[str, str] | None,
    replaced_task: dict[str, Any] | None,
) -> str:
    if not isinstance(saturation_recovery, dict):
        return ""
    if normalize_text(saturation_recovery.get("kind")) != "replace_saturated_experiment":
        return ""
    if not isinstance(replaced_task, dict):
        return ""

    task_shape = replaced_task.get("task_shape") if isinstance(replaced_task.get("task_shape"), dict) else {}
    existing_command = str(task_shape.get("verification_command") or "").strip()
    if existing_command:
        return existing_command

    failed_step = saturation_recovery_failed_step(replaced_task)
    if not failed_step:
        return ""

    verify_match = re.search(
        r"Run [`'\"]?([^`'\"]+)[`'\"]? as the single deterministic verification command",
        failed_step,
        re.IGNORECASE,
    )
    if verify_match:
        return str(verify_match.group(1) or "").strip()
    return ""


def build_normalized_task_intent(
    source: Any,
    objective: Any,
    project: str,
    category: str,
    context_hint: Any,
    existing_intent: dict[str, Any] | None = None,
) -> dict[str, Any]:
    normalized_intent = existing_intent if isinstance(existing_intent, dict) else {}
    return {
        "source": str(normalized_intent.get("source") or source).strip() or str(source or "").strip(),
        "objective": str(objective or "").strip(),
        "project": project,
        "category": category,
        "context_hint": str(context_hint or "").strip(),
        "constraints": list(normalized_intent.get("constraints")) if isinstance(normalized_intent.get("constraints"), list) else [],
        "success_signals": (
            list(normalized_intent.get("success_signals"))
            if isinstance(normalized_intent.get("success_signals"), list)
            else []
        ),
        "affected_files": (
            list(normalized_intent.get("affected_files"))
            if isinstance(normalized_intent.get("affected_files"), list)
            else []
        ),
    }


def derive_timeout_enterprise_guidance(
    tasks: list[dict[str, Any]],
    project: str,
) -> dict[str, Any]:
    status_rank = {"completed": 4, "failed": 3, "running": 2, "approved": 2, "pending_approval": 1}
    selected: dict[str, Any] | None = None
    selected_rank: tuple[int, str, str, int] | None = None

    for index, task in enumerate(tasks):
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("strategy_template")) != "enterprise_timeout_stability":
            continue

        task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
        timeout_learning = task.get("timeout_failure_learning") if isinstance(task.get("timeout_failure_learning"), dict) else {}
        context_hint = str(task_intent.get("context_hint") or "").strip()
        constraints = task_intent.get("constraints") if isinstance(task_intent.get("constraints"), list) else []
        success_signals = task_intent.get("success_signals") if isinstance(task_intent.get("success_signals"), list) else []
        affected_files = task_intent.get("affected_files") if isinstance(task_intent.get("affected_files"), list) else []
        if not (
            (context_hint and normalize_text(context_hint) != "observed queue timeout pressure")
            or constraints
            or success_signals
            or affected_files
            or str(timeout_learning.get("observed_example_project") or "").strip()
            or str(timeout_learning.get("observed_example_lane") or "").strip()
            or str(timeout_learning.get("observed_example_task") or "").strip()
        ):
            continue

        rank = (
            status_rank.get(normalize_text(task.get("status")), 0),
            str(task.get("updated_at") or ""),
            str(task.get("created_at") or ""),
            index,
        )
        if selected_rank is None or rank > selected_rank:
            selected_rank = rank
            selected = task

    default_constraints = [
        "Touch only one timeout-prone queue or orchestration path surfaced by the current timeout evidence.",
        "Do not change retry limits, queue worker counts, or broad strategy seeding behavior.",
    ]
    default_success_signals = [
        "The chosen timeout-prone path is narrowed or reconciled without introducing another generic timeout classification.",
        "A focused timeout-specific regression test proves the behavior deterministically.",
    ]
    guidance = {
        "context_hint": "Observed queue timeout pressure",
        "constraints": default_constraints,
        "success_signals": default_success_signals,
        "affected_files": [],
        "observed_example_project": "",
        "observed_example_lane": "",
        "observed_example_task": "",
    }
    if not isinstance(selected, dict):
        return guidance

    task_intent = selected.get("task_intent") if isinstance(selected.get("task_intent"), dict) else {}
    timeout_learning = selected.get("timeout_failure_learning") if isinstance(selected.get("timeout_failure_learning"), dict) else {}

    context_hint = str(task_intent.get("context_hint") or "").strip()
    observed_project = str(timeout_learning.get("observed_example_project") or "").strip()
    observed_lane = str(timeout_learning.get("observed_example_lane") or "").strip()
    observed_task = str(timeout_learning.get("observed_example_task") or "").strip()
    if not context_hint or normalize_text(context_hint) == "observed queue timeout pressure":
        example_parts = []
        if observed_lane:
            example_parts.append(observed_lane)
        if observed_project:
            example_parts.append(observed_project)
        example_scope = " on ".join(example_parts)
        if example_scope and observed_task:
            context_hint = f"Most recent unresolved timeout: {example_scope} task `{observed_task}`. Focus on one bounded timeout-reduction path from that example."
        elif observed_project and observed_task:
            context_hint = f"Most recent unresolved timeout in {observed_project}: `{observed_task}`. Focus on one bounded timeout-reduction path from that example."
        elif observed_task:
            context_hint = f"Most recent unresolved timeout task: `{observed_task}`. Focus on one bounded timeout-reduction path from that example."

    if context_hint:
        guidance["context_hint"] = context_hint
    if isinstance(task_intent.get("constraints"), list) and task_intent.get("constraints"):
        guidance["constraints"] = list(task_intent.get("constraints"))
    if isinstance(task_intent.get("success_signals"), list) and task_intent.get("success_signals"):
        guidance["success_signals"] = list(task_intent.get("success_signals"))
    if isinstance(task_intent.get("affected_files"), list) and task_intent.get("affected_files"):
        guidance["affected_files"] = list(task_intent.get("affected_files"))
    guidance["observed_example_project"] = observed_project
    guidance["observed_example_lane"] = observed_lane
    guidance["observed_example_task"] = observed_task
    return guidance


def repair_pending_timeout_enterprise_task(
    task: dict[str, Any],
    tasks: list[dict[str, Any]],
    project: str,
) -> tuple[dict[str, Any], bool]:
    if normalize_text(task.get("status")) != "pending_approval":
        return task, False
    if normalize_text(task.get("strategy_template")) != "enterprise_timeout_stability":
        return task, False

    guidance = derive_timeout_enterprise_guidance(tasks, project)
    existing_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    repaired_intent = build_normalized_task_intent(
        "strategy_seed",
        task_execution_text(task),
        project,
        normalize_text(task.get("category")) or "stability",
        guidance.get("context_hint") or "Observed queue timeout pressure",
        {
            "source": existing_intent.get("source") or "strategy_seed",
            "constraints": list(guidance.get("constraints") or []),
            "success_signals": list(guidance.get("success_signals") or []),
            "affected_files": list(guidance.get("affected_files") or []),
        },
    )

    repaired_task = dict(task)
    changed = False
    if repaired_task.get("task_intent") != repaired_intent:
        repaired_task["task_intent"] = repaired_intent
        changed = True

    existing_timeout_learning = (
        task.get("timeout_failure_learning") if isinstance(task.get("timeout_failure_learning"), dict) else {}
    )
    repaired_timeout_learning = dict(existing_timeout_learning)
    for field in ("observed_example_project", "observed_example_lane", "observed_example_task"):
        value = str(guidance.get(field) or "").strip()
        if value and repaired_timeout_learning.get(field) != value:
            repaired_timeout_learning[field] = value
            changed = True
    if changed and repaired_timeout_learning:
        repaired_task["timeout_failure_learning"] = repaired_timeout_learning

    if not changed:
        return repaired_task, False

    transition_at = now_utc()
    repaired_task["updated_at"] = transition_at
    repaired_task["history"] = append_history(
        repaired_task,
        build_history_entry(
            repaired_task,
            "auto_repair",
            "pending_approval",
            "pending_approval",
            "Task was automatically reshaped from prior timeout guidance before strategy reported the blocker.",
            at=transition_at,
            project=project,
            queue_task=task_execution_text(repaired_task),
        ),
    )
    return repaired_task, True


def repair_pending_saturation_recovery_task(
    task: dict[str, Any],
    tasks: list[dict[str, Any]],
    project: str,
) -> tuple[dict[str, Any], bool]:
    if normalize_text(task.get("status")) != "pending_approval":
        return task, False

    saturation_recovery = derive_saturation_recovery_metadata(task, tasks, project)
    if not saturation_recovery:
        return task, False

    replaced_task = find_saturation_recovery_replaced_task(saturation_recovery, tasks, project)
    repaired_title = derive_saturation_recovery_followup_title(
        saturation_recovery,
        replaced_task,
        normalize_text(task.get("category")) or "learning",
    )
    context_hint = derive_saturation_recovery_context_hint(
        saturation_recovery,
        replaced_task,
        normalize_text(task.get("category")) or "learning",
    )
    verification_command = derive_saturation_recovery_verification_command(
        saturation_recovery,
        replaced_task,
    )
    normalized_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    repaired_intent = build_normalized_task_intent(
        "strategy_saturation",
        repaired_title,
        project,
        normalize_text(task.get("category")) or "learning",
        context_hint,
        existing_intent=normalized_intent,
    )

    next_task = dict(task)
    changed = False
    canonical_source_ids = {
        "source_task_id": "strategy::saturation-recovery",
        "source_task_title": "Strategy saturation recovery",
        "root_source_task_id": "strategy::saturation-recovery",
        "original_failed_root_id": "strategy::saturation-recovery",
        "related_source_task_ids": ["strategy::saturation-recovery"],
    }
    for key, value in canonical_source_ids.items():
        if next_task.get(key) != value:
            next_task[key] = value
            changed = True
    if next_task.get("saturation_recovery") != saturation_recovery:
        next_task["saturation_recovery"] = saturation_recovery
        changed = True

    existing_provider_selection = (
        task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    )
    if normalize_text(existing_provider_selection.get("source")) not in {"input", "manual_assessment"}:
        replaced_provider = task_execution_provider(replaced_task or {})
        replacement_provider = alternate_provider_name(replaced_provider)
        if replacement_provider:
            updated_provider_selection_base = {
                "selected": replacement_provider,
                "source": "task_registry",
                "reason": (
                    f"Saturation recovery rerouted this replacement task from {replaced_provider} to "
                    f"{replacement_provider} because the replaced experiment already saturated on {replaced_provider}."
                ),
            }
            if (
                task_execution_provider(next_task) != replacement_provider
                or stable_mapping_without_updated_at(next_task.get("provider_selection")) != updated_provider_selection_base
            ):
                updated_provider_selection = dict(updated_provider_selection_base)
                preserved_updated_at = str(existing_provider_selection.get("updated_at") or "").strip()
                updated_provider_selection["updated_at"] = preserved_updated_at or now_utc()
                next_task["execution_provider"] = replacement_provider
                next_task["provider_selection"] = updated_provider_selection
                changed = True

    if task_execution_text(next_task) != repaired_title:
        next_task["title"] = repaired_title
        next_task["execution_task"] = repaired_title
        changed = True
    if next_task.get("task_intent") != repaired_intent:
        next_task["task_intent"] = repaired_intent
        changed = True
    existing_task_shape = task.get("task_shape") if isinstance(task.get("task_shape"), dict) else None
    if existing_task_shape is not None and verification_command:
        repaired_task_shape = dict(existing_task_shape)
        if str(repaired_task_shape.get("verification_command") or "").strip() != verification_command:
            repaired_task_shape["verification_command"] = verification_command
            next_task["task_shape"] = repaired_task_shape
            changed = True

    if not changed:
        return next_task, False

    transition_at = now_utc()
    next_task["updated_at"] = transition_at
    next_task["history"] = append_history(
        next_task,
        build_history_entry(
            next_task,
            "auto_repair",
            "pending_approval",
            "pending_approval",
            "Task was automatically reshaped from legacy saturation recovery metadata before strategy reported the blocker.",
            at=transition_at,
            project=project,
            queue_task=repaired_title,
        ),
    )
    return next_task, True


def build_strategy_board_snapshot(tasks: list[dict[str, Any]], project: str) -> list[dict[str, Any]]:
    status_rank = {
        "pending_approval": 0,
        "approved": 1,
    }
    snapshot: list[dict[str, Any]] = []
    for task in tasks:
        if sanitize_project(task.get("project")) != project:
            continue
        status = normalize_text(task.get("status"))
        if status not in status_rank:
            continue
        board_task = {
            "id": str(task.get("id") or "").strip(),
            "action": "existing",
            "status": status,
            "title": str(task.get("title") or "").strip(),
            "category": str(task.get("category") or "").strip(),
            "source_task_id": root_source_task_id(task),
            "updated_at": task_timestamp(task),
        }
        task_shape = task.get("task_shape") if isinstance(task.get("task_shape"), dict) else {}
        verification_command = str(task_shape.get("verification_command") or "").strip()
        if verification_command:
            board_task["verification_command"] = verification_command
        snapshot.append(board_task)
    snapshot.sort(key=lambda task: (status_rank.get(str(task.get("status") or "").strip(), 99), str(task.get("updated_at") or ""), str(task.get("id") or "")))
    return snapshot


def build_strategy_message(project: str, actions: list[dict[str, str]], board_tasks: list[dict[str, Any]]) -> str:
    if actions:
        return f"Applied {len(actions)} strategy board update(s) for {project}."

    pending_tasks = [
        task for task in board_tasks if normalize_text(task.get("status")) == "pending_approval"
    ]
    approved_tasks = [
        task for task in board_tasks if normalize_text(task.get("status")) == "approved"
    ]
    running_tasks = [
        task for task in board_tasks if normalize_text(task.get("status")) == "running"
    ]
    saturation_rescue_tasks = [
        task
        for task in pending_tasks
        if str(task.get("source_task_id") or "").strip() == "strategy::saturation-recovery"
    ]
    recommended_pending_task = (
        sorted(
            pending_tasks,
            key=lambda task: (str(task.get("updated_at") or ""), str(task.get("id") or "")),
        )[0]
        if pending_tasks
        else None
    )
    verification_suffix = ""
    if len(pending_tasks) == 1 and isinstance(recommended_pending_task, dict):
        verification_command = str(recommended_pending_task.get("verification_command") or "").strip()
        if verification_command:
            verification_suffix = f" Verification: {excerpt_text(verification_command, 96)}."

    if pending_tasks and not approved_tasks and not running_tasks:
        recommendation_suffix = ""
        if recommended_pending_task and len(pending_tasks) > 1:
            recommendation_suffix = (
                f" Review oldest first: {str(recommended_pending_task.get('title') or '').strip()}."
            )
        if saturation_rescue_tasks:
            return (
                f"No new strategy updates for {project}; waiting on "
                f"{len(pending_tasks)} pending approval task(s), including saturation recovery."
                f"{recommendation_suffix}{verification_suffix}"
            )
        return (
            f"No new strategy updates for {project}; waiting on {len(pending_tasks)} pending approval task(s)."
            f"{recommendation_suffix}{verification_suffix}"
        )

    if board_tasks:
        return f"No new strategy updates for {project}; {len(board_tasks)} actionable board task(s) already exist."

    return f"No strategy board changes were needed for {project}."


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
        entry = {
            "weight": weight,
            "success_rate": max(0.0, min(success_rate, 1.0)),
        }
        if config.get("observed_success_rate") not in (None, ""):
            try:
                observed_success_rate = float(config.get("observed_success_rate", 0))
            except (TypeError, ValueError):
                observed_success_rate = 0.0
            entry["observed_success_rate"] = max(0.0, min(observed_success_rate, 1.0))
        normalized[str(name)] = entry
    return normalized or DEFAULT_PRIORITY_CATEGORIES


def task_score(impact: int, effort: int, confidence: float, category_weight: float) -> float:
    return round((impact * confidence * category_weight) / max(effort, 1), 2)


def manual_recovery_records(records: list[dict[str, Any]]) -> int:
    return sum(1 for record in records if str(record.get("source") or "").strip() == "manual_recovery")


def build_metrics(
    tasks: list[dict[str, Any]],
    records: list[dict[str, Any]],
    external_signals_payload: dict[str, Any] | None = None,
    task_registry_payload_bytes: int | None = None,
) -> dict[str, Any]:
    if callable(build_persisted_metrics):
        return build_persisted_metrics(tasks, records, external_signals_payload, task_registry_payload_bytes)

    # Fallback preserves older behavior if the shared task metrics helper is unavailable.
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
    project = sanitize_project(source_task.get("project"))
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
            "project": project,
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
            "task_intent": build_strategy_followup_intent(source_task, template, project),
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
        "task_intent": build_strategy_followup_intent(source_task, template, project),
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
    if template_key == "system_work_buffer":
        preferred_statuses = {"pending_approval", "approved", "running"}

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


def seed_equivalent_timestamp(task: dict[str, Any]) -> str:
    for key in ("completed_at", "failed_at", "updated_at", "created_at"):
        value = str(task.get(key) or "").strip()
        if value:
            return value
    return ""


def matches_seed_equivalent(task: dict[str, Any], project: str, template: dict[str, Any]) -> bool:
    normalized_title = normalize_text(template["title"])
    template_key = template["key"]
    return (
        sanitize_project(task.get("project")) == project
        and (
            str(task.get("strategy_template") or "").strip() == template_key
            or normalize_text(task.get("title")) == normalized_title
        )
    )


def count_failed_seed_equivalents(tasks: list[dict[str, Any]], project: str, template: dict[str, Any]) -> int:
    equivalent_tasks = [
        task for task in tasks if isinstance(task, dict) and matches_seed_equivalent(task, project, template)
    ]
    latest_success_at = max(
        (
            seed_equivalent_timestamp(task)
            for task in equivalent_tasks
            if normalize_text(task.get("status")) == "completed"
        ),
        default="",
    )
    failed_count = 0

    for task in equivalent_tasks:
        if normalize_text(task.get("status")) != "failed":
            continue
        failed_at = seed_equivalent_timestamp(task)
        if latest_success_at and failed_at and failed_at <= latest_success_at:
            continue
        failed_count += 1
    return failed_count


def learned_category_success_signal(
    tasks: list[dict[str, Any]],
    project: str,
    priority_categories: dict[str, dict[str, float]],
    category: Any,
) -> tuple[int, float] | None:
    normalized_category = normalize_text(category)
    if not normalized_category:
        return None

    resolved_count = 0
    completed_count = 0
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("category")) != normalized_category:
            continue
        status = normalize_text(task.get("status"))
        if status not in {"completed", "failed"}:
            continue
        resolved_count += 1
        if status == "completed":
            completed_count += 1

    if resolved_count > 0:
        success_rate = completed_count / resolved_count
        if success_rate > 0:
            return (0, round(success_rate, 4))
        return None

    category_config = priority_categories.get(normalized_category)
    if not isinstance(category_config, dict):
        return None
    try:
        observed_success_rate = float(
            category_config.get("observed_success_rate", category_config.get("success_rate", 0)) or 0
        )
    except (TypeError, ValueError):
        observed_success_rate = 0.0
    if observed_success_rate > 0:
        return (1, round(min(observed_success_rate, 1.0), 4))
    return None


def task_attempt_count(task: dict[str, Any]) -> int:
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    for container, key in ((execution, "attempt"), (execution_context, "attempts"), (failure_context, "attempts")):
        if key in container and container.get(key) not in (None, ""):
            return max(safe_int(container.get(key)), 0)
    return 0


def task_total_step_attempt_count(task: dict[str, Any]) -> int | None:
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    for container in (execution, execution_context, failure_context):
        if "total_step_attempts" in container and container.get("total_step_attempts") not in (None, ""):
            return max(safe_int(container.get("total_step_attempts")), 0)
    return None


def learned_category_loop_effort_signal(
    tasks: list[dict[str, Any]],
    project: str,
    category: Any,
) -> float | None:
    normalized_category = normalize_text(category)
    if not normalized_category:
        return None

    measured_count = 0
    extra_step_attempts_total = 0
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("category")) != normalized_category:
            continue
        if normalize_text(task.get("status")) not in {"completed", "failed"}:
            continue
        total_step_attempts = task_total_step_attempt_count(task)
        if total_step_attempts is None:
            continue
        measured_count += 1
        extra_step_attempts_total += max(total_step_attempts - task_attempt_count(task), 0)

    if measured_count <= 0:
        return None
    return round(extra_step_attempts_total / measured_count, 4)


def prioritized_enterprise_templates(
    tasks: list[dict[str, Any]],
    project: str,
    priority_categories: dict[str, dict[str, float]],
    loop_effort_learning: dict[str, int | bool],
    timeout_failure_learning: dict[str, int | float | bool],
    task_registry_pressure_learning: dict[str, int | bool],
) -> list[dict[str, Any]]:
    ranked_templates: list[tuple[bool, int, int, int, int, int, float, float, int, dict[str, Any]]] = []
    prefer_lower_execution_depth = loop_effort_learning.get("prefer_lower_execution_depth") is True
    prefer_timeout_enterprise_work = timeout_failure_learning.get("prefer_timeout_enterprise_work") is True
    prefer_performance_enterprise_work = task_registry_pressure_learning.get("prefer_performance_enterprise_work") is True
    for index, template in enumerate(ENTERPRISE_TEMPLATES):
        if (
            normalize_text(template.get("key")) == "enterprise_timeout_stability"
            and not prefer_timeout_enterprise_work
        ):
            continue
        failed_equivalents = count_failed_seed_equivalents(tasks, project, template)
        learned_success_signal = learned_category_success_signal(tasks, project, priority_categories, template.get("category"))
        learned_source_rank = learned_success_signal[0] if learned_success_signal is not None else 2
        learned_success_rate = learned_success_signal[1] if learned_success_signal is not None else 0.0
        timeout_failure_rank = (
            0
            if prefer_timeout_enterprise_work and normalize_text(template.get("key")) == "enterprise_timeout_stability"
            else 1
        )
        registry_pressure_rank = (
            0
            if prefer_performance_enterprise_work and normalize_text(template.get("category")) == "performance"
            else 1
        )
        category_loop_effort = learned_category_loop_effort_signal(tasks, project, template.get("category"))
        loop_effort_source_rank = 0 if prefer_lower_execution_depth and category_loop_effort is not None else 1
        loop_effort_average = category_loop_effort if prefer_lower_execution_depth and category_loop_effort is not None else 0.0
        ranked_templates.append(
            (
                failed_equivalents >= STRATEGY_SATURATED_FAILURE_THRESHOLD,
                failed_equivalents,
                timeout_failure_rank,
                registry_pressure_rank,
                learned_source_rank,
                loop_effort_source_rank,
                loop_effort_average,
                -learned_success_rate,
                index,
                template,
            )
        )
    ranked_templates.sort(key=lambda entry: (entry[0], entry[1], entry[2], entry[3], entry[4], entry[5], entry[6], entry[7], entry[8]))
    return [template for _, _, _, _, _, _, _, _, _, template in ranked_templates]


def learned_followup_success_rate(
    tasks: list[dict[str, Any]],
    project: str,
    priority_categories: dict[str, dict[str, float]],
    failed_task: dict[str, Any],
    template: dict[str, Any],
) -> tuple[int, float] | None:
    _ = template
    return learned_category_success_signal(tasks, project, priority_categories, failed_task.get("category"))


def prioritized_failed_candidates(
    tasks: list[dict[str, Any]],
    project: str,
    priority_categories: dict[str, dict[str, float]],
    loop_effort_learning: dict[str, int | bool],
) -> list[dict[str, Any]]:
    ranked_candidates: list[tuple[int, float, int, float, str, dict[str, Any]]] = []
    prefer_smaller_followups = loop_effort_learning.get("prefer_smaller_followups") is True
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("status")) != "failed":
            continue
        if not (
            strategy_depth(task) < 1
            or (normalize_text(task.get("category")) == "ui" and strategy_depth(task) < 2)
        ):
            continue
        template = strategy_template(task)
        learned_success_signal = learned_followup_success_rate(tasks, project, priority_categories, task, template)
        learned_source_rank = learned_success_signal[0] if learned_success_signal is not None else 2
        learned_success_rate = learned_success_signal[1] if learned_success_signal is not None else 0.0
        loop_effort_effort_rank = safe_int(template.get("effort"), 0) if prefer_smaller_followups else 0
        failed_at = parse_utc(task_timestamp(task))
        ranked_candidates.append(
            (
                learned_source_rank,
                -learned_success_rate,
                loop_effort_effort_rank,
                -(failed_at.timestamp() if failed_at is not None else 0.0),
                str(task.get("id") or ""),
                {
                    "task": task,
                    "template": template,
                    "learned_success_signal": learned_success_signal,
                },
            )
        )
    ranked_candidates.sort(key=lambda entry: (entry[0], entry[1], entry[2], entry[3], entry[4]))
    return [candidate for _, _, _, _, _, candidate in ranked_candidates]


def create_enterprise_seed_task(
    tasks: list[dict[str, Any]],
    project: str,
    template: dict[str, Any],
    category_weight: float,
    approval_mode: str,
    timeout_failure_learning: dict[str, int | float | bool] | None = None,
    task_registry_pressure_learning: dict[str, int | bool | str] | None = None,
) -> dict[str, Any]:
    transition_at = now_utc()
    selected_template = specialize_enterprise_template(template, task_registry_pressure_learning)
    title = selected_template["title"]
    context_hint = "Enterprise readiness backlog"
    timeout_guidance: dict[str, Any] | None = None
    if str(selected_template.get("key") or "").strip() == "enterprise_timeout_stability":
        timeout_guidance = derive_timeout_enterprise_guidance(tasks, project)
        context_hint = str(timeout_guidance.get("context_hint") or "Observed queue timeout pressure").strip()
    if (
        str(selected_template.get("key") or "").strip() == "enterprise_registry_pressure_relief"
        and normalize_text((task_registry_pressure_learning or {}).get("primary_surface")) == "dashboard_read_path"
    ):
        context_hint = "Task-registry pressure on dashboard read path"
    next_task = {
        "id": next_task_registry_id(tasks, title),
        "title": title,
        "impact": selected_template["impact"],
        "effort": selected_template["effort"],
        "confidence": selected_template["confidence"],
        "category": selected_template["category"],
        "project": project,
        "reason": selected_template["reason"],
        "hypothesis": selected_template["hypothesis"],
        "experiment": selected_template["experiment"],
        "success_criteria": selected_template["success_criteria"],
        "rollback": selected_template["rollback"],
        "source_task_id": f"enterprise-readiness::{project}",
        "source_task_title": "Enterprise readiness backlog",
        "root_source_task_id": f"enterprise-readiness::{project}",
        "original_failed_root_id": f"enterprise-readiness::{project}",
        "related_source_task_ids": [f"enterprise-readiness::{project}"],
        "strategy_template": selected_template["key"],
        "strategy_depth": 0,
        "task_intent": build_normalized_task_intent(
            "strategy_seed",
            title,
            project,
            selected_template["category"],
            context_hint,
            {
                "constraints": list((timeout_guidance or {}).get("constraints") or []),
                "success_signals": list((timeout_guidance or {}).get("success_signals") or []),
                "affected_files": list((timeout_guidance or {}).get("affected_files") or []),
            },
        ),
        "score": task_score(
            selected_template["impact"],
            selected_template["effort"],
            selected_template["confidence"],
            category_weight,
        ),
        "status": "pending_approval",
        "created_at": transition_at,
        "updated_at": transition_at,
        "execution_provider": DEFAULT_PROVIDER,
        "provider_selection": build_provider_selection(DEFAULT_PROVIDER),
    }
    if str(selected_template.get("key") or "").strip() == "enterprise_registry_pressure_relief":
        next_task["task_registry_pressure_learning"] = {
            "detected": (task_registry_pressure_learning or {}).get("detected") is True,
            "payload_bytes": max(safe_int((task_registry_pressure_learning or {}).get("payload_bytes")), 0),
            "primary_surface": str((task_registry_pressure_learning or {}).get("primary_surface") or "").strip(),
        }
    if str(selected_template.get("key") or "").strip() == "enterprise_timeout_stability":
        next_task["timeout_failure_learning"] = {
            "detected": (timeout_failure_learning or {}).get("detected") is True,
            "timeout_failure_records": max(safe_int((timeout_failure_learning or {}).get("timeout_failure_records")), 0),
            "timeout_failure_rate": round(float((timeout_failure_learning or {}).get("timeout_failure_rate") or 0), 2),
        }
        for field in ("observed_example_project", "observed_example_lane", "observed_example_task"):
            value = str((timeout_guidance or {}).get(field) or "").strip()
            if value:
                next_task["timeout_failure_learning"][field] = value
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


def strategy_saturation_key(task: dict[str, Any], project: str) -> str:
    title = normalize_text(task.get("title"))
    strategy_template = normalize_text(task.get("strategy_template"))
    if not title and not strategy_template:
        return ""
    return f"{project}::{strategy_template}::{title}"


def latest_saturated_failed_task(tasks: list[dict[str, Any]], project: str) -> dict[str, Any] | None:
    saturation_counts: dict[str, int] = {}
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("status")) != "failed":
            continue
        key = strategy_saturation_key(task, project)
        if not key:
            continue
        saturation_counts[key] = saturation_counts.get(key, 0) + 1

    latest_task: dict[str, Any] | None = None
    latest_rank: tuple[float, str] | None = None
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        if normalize_text(task.get("status")) != "failed":
            continue
        key = strategy_saturation_key(task, project)
        if not key or saturation_counts.get(key, 0) < STRATEGY_SATURATED_FAILURE_THRESHOLD:
            continue
        failed_at = parse_utc(task_timestamp(task))
        rank = (
            failed_at.timestamp() if failed_at is not None else 0.0,
            str(task.get("id") or ""),
        )
        if latest_rank is None or rank > latest_rank:
            latest_rank = rank
            latest_task = task
    return latest_task


def saturation_recovery_matches_target(
    task: dict[str, Any],
    tasks: list[dict[str, Any]],
    project: str,
    target_task: dict[str, Any] | None,
) -> bool:
    metadata = derive_saturation_recovery_metadata(task, tasks, project)
    if not isinstance(metadata, dict):
        return False
    if not isinstance(target_task, dict):
        return True

    target_task_id = str(target_task.get("id") or "").strip()
    target_title = task_execution_text(target_task)
    target_template = str(target_task.get("strategy_template") or target_task.get("strategyTemplate") or "").strip()

    replaced_task_id = str(metadata.get("replaces_task_id") or "").strip()
    replaced_title = str(metadata.get("replaces_title") or "").strip()
    replaced_template = str(metadata.get("replaces_strategy_template") or "").strip()

    if replaced_task_id and target_task_id and replaced_task_id == target_task_id:
        return True
    if replaced_title and target_title and replaced_title == target_title:
        if not replaced_template or not target_template:
            return True
        return replaced_template == target_template
    if replaced_template and target_template and replaced_template == target_template:
        return True
    return False


def find_equivalent_saturation_recovery_task(
    tasks: list[dict[str, Any]],
    project: str,
    target_task: dict[str, Any] | None,
) -> dict[str, Any] | None:
    actionable_statuses = {"pending_approval", "approved", "running"}
    resolved_statuses = {"completed", "rejected"}

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if sanitize_project(task.get("project")) != project:
            continue
        status = normalize_text(task.get("status"))
        if status not in actionable_statuses and status not in resolved_statuses:
            continue
        if not derive_saturation_recovery_metadata(task, tasks, project):
            continue
        if status in actionable_statuses:
            return task
        if saturation_recovery_matches_target(task, tasks, project, target_task):
            return task
    return None


def all_enterprise_templates_saturated(tasks: list[dict[str, Any]], project: str) -> bool:
    return all(
        count_failed_seed_equivalents(tasks, project, template) >= STRATEGY_SATURATED_FAILURE_THRESHOLD
        for template in ENTERPRISE_TEMPLATES
    )


def create_saturation_rescue_task(
    tasks: list[dict[str, Any]],
    project: str,
    category_weight: float,
    approval_mode: str,
    saturated_task: dict[str, Any] | None,
) -> dict[str, Any]:
    transition_at = now_utc()
    saturated_task_id = str((saturated_task or {}).get("id") or "").strip()
    saturated_title = str((saturated_task or {}).get("title") or "").strip()
    saturated_template = str((saturated_task or {}).get("strategy_template") or "").strip()
    saturated_category = normalize_text((saturated_task or {}).get("category") or "")
    reason = (
        "All enterprise-readiness seed templates are saturated and the board has no actionable tasks, "
        "so the strategy loop needs one explicit recovery task instead of returning a silent no-op."
    )
    if saturated_title:
        reason = (
            f"{reason} The latest saturated failure is '{saturated_title}'"
            f"{f' ({saturated_template})' if saturated_template else ''}."
        )

    saturation_recovery = {
        "kind": "replace_saturated_experiment",
        "replaces_task_id": saturated_task_id,
        "replaces_title": saturated_title,
        "replaces_strategy_template": saturated_template,
        "replaces_category": saturated_category,
    }
    repaired_title = derive_saturation_recovery_followup_title(
        saturation_recovery,
        saturated_task,
        SATURATION_RESCUE_TEMPLATE["category"],
    )
    context_hint = derive_saturation_recovery_context_hint(
        saturation_recovery,
        saturated_task,
        SATURATION_RESCUE_TEMPLATE["category"],
    )
    selected_provider = DEFAULT_PROVIDER
    provider_selection = build_provider_selection(DEFAULT_PROVIDER)
    replaced_provider = task_execution_provider(saturated_task or {})
    replacement_provider = alternate_provider_name(replaced_provider)
    if replacement_provider:
        selected_provider = replacement_provider
        provider_selection = {
            "selected": replacement_provider,
            "source": "task_registry",
            "reason": (
                f"Saturation recovery rerouted this replacement task from {replaced_provider} to "
                f"{replacement_provider} because the replaced experiment already saturated on {replaced_provider}."
            ),
            "updated_at": transition_at,
        }

    next_task = {
        "id": next_task_registry_id(tasks, repaired_title),
        "title": repaired_title,
        "impact": SATURATION_RESCUE_TEMPLATE["impact"],
        "effort": SATURATION_RESCUE_TEMPLATE["effort"],
        "confidence": SATURATION_RESCUE_TEMPLATE["confidence"],
        "category": SATURATION_RESCUE_TEMPLATE["category"],
        "project": project,
        "reason": reason,
        "hypothesis": SATURATION_RESCUE_TEMPLATE["hypothesis"],
        "experiment": SATURATION_RESCUE_TEMPLATE["experiment"],
        "success_criteria": SATURATION_RESCUE_TEMPLATE["success_criteria"],
        "rollback": SATURATION_RESCUE_TEMPLATE["rollback"],
        "source_task_id": "strategy::saturation-recovery",
        "source_task_title": "Strategy saturation recovery",
        "root_source_task_id": "strategy::saturation-recovery",
        "original_failed_root_id": "strategy::saturation-recovery",
        "related_source_task_ids": ["strategy::saturation-recovery"],
        "strategy_template": SATURATION_RESCUE_TEMPLATE["key"],
        "strategy_depth": 0,
        "task_intent": build_normalized_task_intent(
            "strategy_saturation",
            repaired_title,
            project,
            SATURATION_RESCUE_TEMPLATE["category"],
            context_hint,
        ),
        "saturation_recovery": saturation_recovery,
        "score": task_score(
            SATURATION_RESCUE_TEMPLATE["impact"],
            SATURATION_RESCUE_TEMPLATE["effort"],
            SATURATION_RESCUE_TEMPLATE["confidence"],
            category_weight,
        ),
        "status": "pending_approval",
        "created_at": transition_at,
        "updated_at": transition_at,
        "execution_provider": selected_provider,
        "provider_selection": provider_selection,
    }
    next_task["history"] = append_history(
        next_task,
        build_history_entry(
            next_task,
            "create",
            "",
            "pending_approval",
            "Task was added from strategy saturation recovery after all enterprise templates hit the saturation guard.",
            at=transition_at,
            project=project,
            queue_task=repaired_title,
        ),
    )
    return finalize_task_for_approval(next_task, approval_mode)


def build_strategy_followup_intent(source_task: dict[str, Any], template: dict[str, Any], project: str) -> dict[str, Any]:
    return {
        "source": "strategy_followup",
        "objective": template["title"],
        "project": project,
        "category": template["category"],
        "context_hint": str(source_task.get("title") or source_task.get("id") or "").strip(),
    }


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


def loop_effort_learning_snapshot(metrics: dict[str, Any]) -> dict[str, int | bool]:
    task_count = max(safe_int(metrics.get("loop_effort_task_count")), 0)
    extra_step_attempts = max(safe_int(metrics.get("loop_effort_extra_step_attempts")), 0)
    detected = metrics.get("loop_effort_detected") is True or task_count > 0 or extra_step_attempts > 0
    return {
        "detected": detected,
        "task_count": task_count,
        "extra_step_attempts": extra_step_attempts,
        "prefer_smaller_followups": detected and extra_step_attempts >= 2,
        "prefer_lower_execution_depth": detected and extra_step_attempts >= 2,
    }


def timeout_failure_learning_snapshot(metrics: dict[str, Any]) -> dict[str, int | float | bool]:
    timeout_failure_records = max(safe_int(metrics.get("timeout_failure_records")), 0)
    try:
        timeout_failure_rate = float(metrics.get("timeout_failure_rate") or 0)
    except (TypeError, ValueError):
        timeout_failure_rate = 0.0
    detected = (
        timeout_failure_records >= TIMEOUT_FAILURE_RECORDS_THRESHOLD
        and timeout_failure_rate >= TIMEOUT_FAILURE_RATE_THRESHOLD
    )
    return {
        "detected": detected,
        "timeout_failure_records": timeout_failure_records,
        "timeout_failure_rate": round(timeout_failure_rate, 2),
        "prefer_timeout_enterprise_work": detected,
    }


def task_registry_pressure_learning_snapshot(metrics: dict[str, Any]) -> dict[str, int | bool | str]:
    payload_bytes = max(safe_int(metrics.get("task_registry_payload_bytes")), 0)
    detected = (
        metrics.get("task_registry_pressure_detected") is True
        or payload_bytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
    )
    primary_surface = normalize_text(metrics.get("task_registry_pressure_primary_surface"))
    if detected and not primary_surface:
        primary_surface = "dashboard_read_path"
    return {
        "detected": detected,
        "payload_bytes": payload_bytes,
        "prefer_performance_enterprise_work": detected,
        "primary_surface": primary_surface,
        "prefer_dashboard_read_path_relief": detected and primary_surface == "dashboard_read_path",
    }


def board_health_learning_snapshot(metrics: dict[str, Any]) -> dict[str, bool]:
    return {
        "retry_churn_detected": metrics.get("retry_churn_detected") is True,
        "queue_starvation_detected": metrics.get("queue_starvation_detected") is True,
        "pending_approval_blocked_detected": metrics.get("pending_approval_blocked_detected") is True,
        "low_completion_drain_detected": metrics.get("low_completion_drain_detected") is True,
    }


def specialize_enterprise_template(
    template: dict[str, Any],
    task_registry_pressure_learning: dict[str, int | bool | str] | None = None,
) -> dict[str, Any]:
    specialized = dict(template)
    learning = task_registry_pressure_learning or {}
    if str(template.get("key") or "").strip() != "enterprise_registry_pressure_relief":
        return specialized
    if learning.get("prefer_dashboard_read_path_relief") is True:
        specialized["title"] = "Cut dashboard task-registry read amplification before growth stalls the loop"
        specialized["reason"] = (
            "The shared task registry is already large, and the dashboard remains the highest-frequency read surface "
            "because fixed operator refreshes still drive multiple registry-backed views."
        )
        specialized["experiment"] = (
            "Implement one bounded optimization or observability change on a dashboard task-registry read path, "
            "without changing task schemas or queue semantics."
        )
        specialized["success_criteria"] = [
            "The change targets an existing dashboard task-registry read endpoint, preload path, or refresh contract.",
            "The optimization stays deterministic and preserves current runtime artifacts.",
            "A focused test proves the dashboard-specific read-path behavior or signal.",
        ]
        specialized["rollback"] = "Remove the bounded dashboard registry-read optimization and restore the previous read path."
    return specialized


def task_has_current_retry_pressure(task: dict[str, Any], project: str) -> bool:
    if sanitize_project(task.get("project")) != project:
        return False

    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    status = normalize_text(task.get("status"))
    execution_state = normalize_text(execution.get("state"))
    attempt = task_attempt_count(task)
    max_retries = max(safe_int(execution.get("max_retries"), 0), 0)
    lease_state = normalize_text(execution.get("lease_state"))
    lease_expires_at = parse_utc(execution.get("lease_expires_at"))
    stale_running = (
        status == "running"
        and lease_state == "claimed"
        and lease_expires_at is not None
        and lease_expires_at <= datetime.now(timezone.utc)
    )
    if not (status in {"approved", "running"} or execution_state in {"running", "retrying"} or stale_running):
        return False
    if execution_state == "retrying":
        return True
    if status == "approved" and normalize_text(execution.get("result")) == "failure":
        return True
    return attempt >= RETRY_CHURN_ATTEMPT_THRESHOLD and (max_retries == 0 or attempt <= max_retries)


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


primary_registry_path = os.path.abspath(tasks_path)
project_key = sanitize_project(project_name)
project_registry_path = resolve_project_registry_path(project_key, primary_registry_path, projects_dir)

registry = read_json(project_registry_path, {"tasks": []})
tasks = [task for task in registry.get("tasks", []) if isinstance(task, dict)]
registry_changed = False
records = read_json_lines(task_log_path)
priority_categories = read_priority_categories()
settings = read_dashboard_settings()
approval_mode = settings["approval_mode"]
external_signals_payload = read_external_signals_payload()
external_signals = [
    signal for signal in (external_signals_payload.get("signals") or []) if isinstance(signal, dict)
]
metrics_snapshot = read_metrics_snapshot()
external_signal_learning = external_signal_learning_snapshot(metrics_snapshot)
loop_effort_learning = loop_effort_learning_snapshot(metrics_snapshot)
timeout_failure_learning = timeout_failure_learning_snapshot(metrics_snapshot)
task_registry_pressure_learning = task_registry_pressure_learning_snapshot(metrics_snapshot)
board_health_learning = board_health_learning_snapshot(metrics_snapshot)

for index, task in enumerate(tasks):
    if sanitize_project(task.get("project")) != project_key:
        continue
    repaired_task, repaired = repair_pending_timeout_enterprise_task(task, tasks, project_key)
    if repaired:
        tasks[index] = repaired_task
        registry_changed = True
        task = repaired_task
    repaired_task, repaired = repair_pending_saturation_recovery_task(task, tasks, project_key)
    if not repaired:
        continue
    tasks[index] = repaired_task
    registry_changed = True

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
current_actionable_backlog_count = sum(
    1
    for task in tasks
    if sanitize_project(task.get("project")) == project_key and normalize_text(task.get("status")) in {"pending_approval", "approved"}
)
current_executable_backlog_count = sum(
    1
    for task in tasks
    if sanitize_project(task.get("project")) == project_key and normalize_text(task.get("status")) in {"approved", "running"}
)
current_active_execution_count = sum(
    1
    for task in tasks
    if sanitize_project(task.get("project")) == project_key
    and normalize_text((task.get("execution") if isinstance(task.get("execution"), dict) else {}).get("state")) in {"running", "retrying"}
)
current_retry_pressure_count = sum(1 for task in tasks if task_has_current_retry_pressure(task, project_key))
current_queue_starvation_detected = current_executable_backlog_count > 0 and current_active_execution_count == 0
pending_approval_creation_guard = (
    (board_health_learning["pending_approval_blocked_detected"] or bool(pending_tasks))
    and current_executable_backlog_count == 0
    and current_active_execution_count == 0
)
fresh_external_signals = [
    signal for signal in external_signals if signal.get("fresh") is True and signal.get("source_task_id")
]
fresh_external_signals.sort(key=external_signal_sort_key, reverse=True)

failed_candidates = prioritized_failed_candidates(tasks, project_key, priority_categories, loop_effort_learning)

actions: list[dict[str, str]] = []
hypotheses: list[dict[str, str]] = []
experiments: list[dict[str, str]] = []
processed_templates: set[str] = set()

for failed_candidate in failed_candidates:
    if len(actions) >= 2:
        break

    failed_task = failed_candidate["task"]
    template = failed_candidate["template"]

    if normalize_text(failed_task.get("category")) == "ui" and ui_requirement_is_already_covered(tasks, failed_task):
        continue

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

    if pending_approval_creation_guard or len(pending_tasks) >= 2:
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

if len(actions) < 2 and len(pending_tasks) < 2 and not pending_approval_creation_guard:
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
live_low_completion_drain_detected = total_records > 0 and completion_rate < 0.5
persisted_board_health_requires_buffer = (
    board_health_learning["low_completion_drain_detected"]
    or (
        board_health_learning["retry_churn_detected"]
        and current_retry_pressure_count > 0
        and current_queue_starvation_detected
    )
)

if (
    len(actions) < 2
    and not pending_approval_creation_guard
    and (live_low_completion_drain_detected or persisted_board_health_requires_buffer)
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

if len(actions) < 2 and len(actionable_tasks) < ENTERPRISE_ACTIONABLE_TARGET and not pending_approval_creation_guard:
    for template in prioritized_enterprise_templates(
        tasks,
        project_key,
        priority_categories,
        loop_effort_learning,
        timeout_failure_learning,
        task_registry_pressure_learning,
    ):
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
            timeout_failure_learning,
            task_registry_pressure_learning,
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

candidate_saturated_task = latest_saturated_failed_task(tasks, project_key) if not actions and not actionable_tasks else None
if (
    not actions
    and not actionable_tasks
    and all_enterprise_templates_saturated(tasks, project_key)
    and count_failed_seed_equivalents(tasks, project_key, SATURATION_RESCUE_TEMPLATE) < STRATEGY_SATURATED_FAILURE_THRESHOLD
    and find_equivalent_saturation_recovery_task(tasks, project_key, candidate_saturated_task) is None
):
    saturation_category_config = priority_categories.get(
        SATURATION_RESCUE_TEMPLATE["category"],
        DEFAULT_PRIORITY_CATEGORIES["code_quality"],
    )
    saturated_task = candidate_saturated_task
    created_task = create_saturation_rescue_task(
        tasks,
        project_key,
        float(saturation_category_config.get("weight", 1.0)),
        approval_mode,
        saturated_task,
    )
    tasks.append(created_task)
    if normalize_text(created_task.get("status")) == "pending_approval":
        pending_tasks.append(created_task)
    actionable_tasks.append(created_task)
    actions.append(
        {
            "id": created_task["id"],
            "action": "created",
            "source_task_id": "strategy::saturation-recovery",
        }
    )
    hypotheses.append(
        {
            "task_id": created_task["id"],
            "source_task_id": "strategy::saturation-recovery",
            "hypothesis": SATURATION_RESCUE_TEMPLATE["hypothesis"],
        }
    )
    experiments.append(
        {
            "task_id": created_task["id"],
            "source_task_id": "strategy::saturation-recovery",
            "experiment": SATURATION_RESCUE_TEMPLATE["experiment"],
        }
    )

if actions or registry_changed:
    registry["tasks"] = tasks
    write_json(project_registry_path, registry)

metric_registry_paths = discover_task_registry_paths(primary_registry_path)
metrics = build_metrics(
    read_registry_tasks(metric_registry_paths),
    records,
    external_signals_payload,
    registry_payload_bytes(metric_registry_paths),
)
write_json(metrics_path, metrics)

board_tasks = actions if actions else build_strategy_board_snapshot(tasks, project_key)
payload = {
    "status": "success",
    "message": build_strategy_message(project_key, actions, board_tasks),
    "data": {
        "hypotheses": hypotheses,
        "experiments": experiments,
        "board_updates": actions,
        "board_tasks": board_tasks,
    },
}
write_json(output_path, payload)
PY

print_json_file "$OUTPUT_FILE"
