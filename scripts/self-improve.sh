#!/usr/bin/env bash
# self-improve.sh — Autonomous system improvement task generator
#
# Analyzes system metrics and failure patterns to autonomously create
# targeted improvement tasks. Designed to be called from strategy-loop.sh.
#
# Usage: bash scripts/self-improve.sh [project_name]

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap self-improve

# Pause gate: touch $LOG_DIR/self-improve-paused to disable self-improve generation.
# The actual exit is handled in the main execution path so paused runs still
# refresh self-improve-run.json for downstream automation context consumers.
SELF_IMPROVE_PAUSE_FILE="${SELF_IMPROVE_PAUSE_FILE:-$LOG_DIR/self-improve-paused}"

PROJECT_NAME="${1:-codex-agent-system}"
PROJECT_KEY="$(
  printf '%s' "$PROJECT_NAME" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
)"
[ -n "$PROJECT_KEY" ] || PROJECT_KEY="default"
METRICS_FILE="${METRICS_FILE:-$LEARNING_DIR/metrics.json}"
PROJECT_REGISTRY_FILE="$(task_registry_file_for_project "$PROJECT_NAME")"
REGISTRY_FILE="${SELF_IMPROVE_REGISTRY_FILE:-$PROJECT_REGISTRY_FILE}"
IMPROVEMENT_LOG="$LOG_DIR/self-improve.log"
IMPROVEMENT_COOLDOWN_FILE="${IMPROVEMENT_COOLDOWN_FILE:-$LOG_DIR/self-improve-${PROJECT_KEY}-cooldown}"
SELF_IMPROVE_RUN_FILE="${SELF_IMPROVE_RUN_FILE:-$LEARNING_DIR/self-improve-run.json}"
SELF_IMPROVE_METRICS_INPUT_STATUS="unknown"
SELF_IMPROVE_METRICS_INPUT_REASON="not_checked"
SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED="false"
SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="[]"
SELF_IMPROVE_START_EPOCH="$(date +%s)"
SELF_IMPROVE_AUTOMATION_CONTEXT_FILE="${SELF_IMPROVE_AUTOMATION_CONTEXT_FILE:-$LEARNING_DIR/self-improve-automation-memory.json}"
SELF_IMPROVE_FORCE_METRICS_REFRESH="false"
SELF_IMPROVE_PREVALIDATE_COMPLETE="false"
SELF_IMPROVE_PREVALIDATE_REASON="not_checked"
SELF_IMPROVE_PREVALIDATE_MISSING_KEYS_CSV=""
SELF_IMPROVE_PAUSE_ESCALATION_SECONDS="${SELF_IMPROVE_PAUSE_ESCALATION_SECONDS:-21600}"

# Cooldown: keep the core repo conservative, but let external projects refresh
# faster so scheduled per-project self-improve runs are not effectively hourly-only.
DEFAULT_IMPROVEMENT_COOLDOWN_SECONDS="${DEFAULT_IMPROVEMENT_COOLDOWN_SECONDS:-3600}"
EXTERNAL_PROJECT_IMPROVEMENT_COOLDOWN_SECONDS="${EXTERNAL_PROJECT_IMPROVEMENT_COOLDOWN_SECONDS:-600}"
if [ -n "${IMPROVEMENT_COOLDOWN_SECONDS:-}" ]; then
  IMPROVEMENT_COOLDOWN_SECONDS="${IMPROVEMENT_COOLDOWN_SECONDS}"
elif [ "$PROJECT_NAME" = "codex-agent-system" ]; then
  IMPROVEMENT_COOLDOWN_SECONDS="$DEFAULT_IMPROVEMENT_COOLDOWN_SECONDS"
else
  IMPROVEMENT_COOLDOWN_SECONDS="$EXTERNAL_PROJECT_IMPROVEMENT_COOLDOWN_SECONDS"
fi
IMPROVEMENT_EMERGENCY_COOLDOWN_SECONDS="${IMPROVEMENT_EMERGENCY_COOLDOWN_SECONDS:-300}"
SELF_IMPROVE_SHARED_METRICS_FALLBACK="false"
if project_uses_shared_metrics_fallback "$PROJECT_NAME" "$METRICS_FILE"; then
  SELF_IMPROVE_SHARED_METRICS_FALLBACK="true"
fi

cooldown_bypass_reason() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$METRICS_FILE" "$REGISTRY_FILE" "$TASK_LOG" "$PROJECT_NAME" "$ROOT_DIR" "${SELF_IMPROVE_ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD:-0.75}" "$SELF_IMPROVE_RUN_FILE" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def safe_float(value: object) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def safe_int(value: object) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def normalize_text(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def read_json_lines(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows: list[dict] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            payload = json.loads(raw_line)
        except Exception:
            continue
        if isinstance(payload, dict):
            rows.append(payload)
    return rows


def read_registry_tasks(path: Path) -> list[dict]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return [task for task in tasks if isinstance(task, dict)] if isinstance(tasks, list) else []


def is_active_self_improve_task(task: object) -> bool:
    if not isinstance(task, dict):
        return False
    status = normalize_text(task.get("status"))
    if status not in {"pending_approval", "approved", "queued", "running"}:
        return False
    task_intent = task.get("task_intent")
    if isinstance(task_intent, dict) and normalize_text(task_intent.get("source")) == "self-improve":
        return True
    source = normalize_text(task.get("source"))
    if source == "self-improve":
        return True
    title = normalize_text(task.get("title") or task.get("execution_task"))
    return "[self-improve:" in title


metrics_path = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3])
project_name = str(sys.argv[4] or "codex-agent-system").strip() or "codex-agent-system"
root_dir = Path(sys.argv[5])
threshold = max(0.0, min(1.0, safe_float(sys.argv[6] if len(sys.argv) > 6 else 0.75) or 0.75))
run_artifact_path = Path(sys.argv[7]) if len(sys.argv) > 7 and str(sys.argv[7] or "").strip() else None
sandbox_scripts_dir = root_dir / "scripts"
if str(sandbox_scripts_dir) not in sys.path:
    sys.path.insert(0, str(sandbox_scripts_dir))

try:
    from task_metrics import _compute_pipeline_staleness
except Exception:
    _compute_pipeline_staleness = None

try:
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    metrics = {}

if not isinstance(metrics, dict):
    metrics = {}

project_key = normalize_text(project_name)
project_tasks = [
    task for task in read_registry_tasks(registry_path)
    if normalize_text(task.get("project") or task.get("target_project") or project_name) == project_key
]
project_active_self_improve_count = sum(
    1 for task in project_tasks if is_active_self_improve_task(task)
)
project_active_execution_count = sum(
    1
    for task in project_tasks
    if normalize_text(task.get("status")) in {"queued", "running"}
)
project_task_log_records = [
    record for record in read_json_lines(task_log_path)
    if normalize_text(record.get("project") or project_name) == project_key
]

last_run_blocked_by_external_control_plane = False
if run_artifact_path is not None and run_artifact_path.exists():
    try:
        run_artifact = json.loads(run_artifact_path.read_text(encoding="utf-8"))
    except Exception:
        run_artifact = {}
    if isinstance(run_artifact, dict):
        artifact_project_key = normalize_text(run_artifact.get("project") or "")
        if artifact_project_key == project_key:
            gating = run_artifact.get("gating") if isinstance(run_artifact.get("gating"), dict) else {}
            counts = run_artifact.get("counts") if isinstance(run_artifact.get("counts"), dict) else {}
            dominant_reason = normalize_text(
                gating.get("dominant_reason") or gating.get("analysis_reason") or ""
            )
            generated_count = safe_int(counts.get("generated"), 0)
            submitted_count = safe_int(counts.get("submitted"), 0)
            blocked_analysis_count = safe_int(counts.get("blocked_analysis"), 0)
            selected_improvement = normalize_text(run_artifact.get("selected_improvement") or "")
            if (
                dominant_reason == "external_control_plane_task"
                and generated_count <= 0
                and submitted_count <= 0
                and blocked_analysis_count > 0
                and not selected_improvement
            ):
                last_run_blocked_by_external_control_plane = True

project_timeout_records = [
    record for record in project_task_log_records
    if normalize_text(record.get("result")) == "failure"
    and normalize_text(record.get("failure_kind")) == "timeout"
]
if project_timeout_records:
    project_zero_step_timeout_rate = round(
        sum(1 for record in project_timeout_records if safe_int(record.get("total_step_attempts")) == 0)
        / len(project_timeout_records),
        2,
    )
elif project_task_log_records or project_tasks:
    project_zero_step_timeout_rate = 0.0
else:
    project_zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))

project_pipeline_stale = metrics.get("pipeline_stale") is True
if _compute_pipeline_staleness is not None:
    pipeline_stale_signal = _compute_pipeline_staleness(project_task_log_records, project_tasks)
    project_pipeline_stale = pipeline_stale_signal.get("pipeline_stale") is True

if project_zero_step_timeout_rate >= threshold:
    if project_active_self_improve_count == 0 and project_active_execution_count == 0:
        if not last_run_blocked_by_external_control_plane:
            print("zero_step_timeout_emergency_no_active_self_improve")
    elif project_active_self_improve_count > 0:
        print("zero_step_timeout_emergency")
elif project_pipeline_stale:
    print("pipeline_stale")
PY
}

check_cooldown() {
  if [ -f "$IMPROVEMENT_COOLDOWN_FILE" ]; then
    local last_run
    last_run="$(cat "$IMPROVEMENT_COOLDOWN_FILE" 2>/dev/null || printf '0')"
    local now_epoch
    now_epoch="$(date +%s)"
    local elapsed=$((now_epoch - last_run))
    if [ "$elapsed" -lt "$IMPROVEMENT_COOLDOWN_SECONDS" ]; then
      local bypass_reason=""
      bypass_reason="$(cooldown_bypass_reason 2>/dev/null || true)"
      if [ -n "$bypass_reason" ]; then
        if [ "$elapsed" -lt "$IMPROVEMENT_EMERGENCY_COOLDOWN_SECONDS" ] && [ "$bypass_reason" != "zero_step_timeout_emergency_no_active_self_improve" ]; then
          bypass_reason=""
        fi
      fi
      if [ -n "$bypass_reason" ]; then
        if [ "$bypass_reason" = "zero_step_timeout_emergency_no_active_self_improve" ]; then
          log_msg WARN self-improve "Bypassing cooldown after ${elapsed}s due to ${bypass_reason} (no active self-improve tasks; ${IMPROVEMENT_COOLDOWN_SECONDS}s standard cooldown)"
        else
          log_msg WARN self-improve "Bypassing cooldown after ${elapsed}s due to ${bypass_reason} (${IMPROVEMENT_EMERGENCY_COOLDOWN_SECONDS}s emergency interval, ${IMPROVEMENT_COOLDOWN_SECONDS}s standard cooldown)"
        fi
      else
      log_msg DEBUG self-improve "Cooldown active (${elapsed}s / ${IMPROVEMENT_COOLDOWN_SECONDS}s)"
      return 1
      fi
    fi
  fi
  date +%s > "$IMPROVEMENT_COOLDOWN_FILE"
  return 0
}

generate_improvements() {
  local automation_id=""
  local automation_memory_file=""
  local project_workspace=""

  automation_id="$(project_automation_id "$PROJECT_NAME" 2>/dev/null || true)"
  if [ -n "$automation_id" ] && resolve_automation_memory_read_file "$PROJECT_NAME" "$automation_id" >/dev/null 2>&1; then
    automation_memory_file="${AUTOMATION_MEMORY_RESOLVED_FILE:-}"
  fi
  project_workspace="$(resolve_project_workspace "$PROJECT_NAME" 2>/dev/null || printf '%s' "$ROOT_DIR")"
  python3 - "$SELF_IMPROVE_AUTOMATION_CONTEXT_FILE" "$automation_id" "$automation_memory_file" "${AUTOMATION_MEMORY_RESOLVED_SOURCE:-none}" "${AUTOMATION_MEMORY_EXTERNAL_HYDRATED:-false}" "${AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING:-true}" <<'PY' >/dev/null 2>&1 || true
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
import sys

target = Path(sys.argv[1])
payload = {
    "automation_id": str(sys.argv[2] or "").strip(),
    "memory_file": str(sys.argv[3] or "").strip(),
    "source": str(sys.argv[4] or "").strip() or "none",
    "external_hydrated": str(sys.argv[5] or "").strip().lower() == "true",
    "external_sync_pending": str(sys.argv[6] or "").strip().lower() == "true",
}

target.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile("w", delete=False, dir=target.parent, encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
    temp_path = handle.name
os.replace(temp_path, str(target))
PY

  python3 - "$METRICS_FILE" "$REGISTRY_FILE" "$TASK_LOG" "$RETRY_ANALYSIS_LOG" "$PROJECT_NAME" "$ROOT_DIR" "$automation_memory_file" "$project_workspace" "$(project_spec_file "$PROJECT_NAME" 2>/dev/null || true)" <<'PYIMPROVE'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

metrics_path = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3])
retry_analysis_path = Path(sys.argv[4])
project_name = sys.argv[5]
root_dir = Path(sys.argv[6])
automation_memory_path = Path(sys.argv[7]) if len(sys.argv) > 7 and str(sys.argv[7]).strip() else None
project_workspace = Path(sys.argv[8]).resolve() if len(sys.argv) > 8 and str(sys.argv[8]).strip() else root_dir.resolve()
project_spec_path = Path(sys.argv[9]).resolve() if len(sys.argv) > 9 and str(sys.argv[9]).strip() else (root_dir / "projects" / project_name / "spec.md").resolve()
enforce_workspace_target_validation = project_workspace != root_dir.resolve()
scripts_dir = root_dir / "scripts"
if str(scripts_dir) not in sys.path:
    sys.path.insert(0, str(scripts_dir))

try:
    from task_metrics import (
        _compute_pipeline_staleness,
        build_first_pass_success_signal,
        build_latest_success_timestamp_by_identity,
        build_loop_effort_signal,
        build_persisted_board_health_signals,
        build_retry_failure_kind_index,
        build_strategy_saturation_signal,
        build_task_index_by_id,
        effective_retry_classification,
        is_unresolved_timeout_record,
    )
except Exception:
    _compute_pipeline_staleness = None
    build_first_pass_success_signal = None
    build_latest_success_timestamp_by_identity = None
    build_loop_effort_signal = None
    build_persisted_board_health_signals = None
    build_retry_failure_kind_index = None
    build_strategy_saturation_signal = None
    build_task_index_by_id = None
    effective_retry_classification = None
    is_unresolved_timeout_record = None

TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000
EXTREME_TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD * 2
BACKLOG_DRAIN_SIGNAL_THRESHOLD = 8
BACKLOG_OVERLOAD_THRESHOLD = 12
BACKLOG_OVERLOAD_SUCCESS_RATE_THRESHOLD = 0.30
APPROVAL_BACKLOG_IMPROVEMENT_TITLE = "Drain approval backlog"
RETRY_CLASSIFICATION_COVERAGE_THRESHOLD = 0.50
RETRY_CLASSIFICATION_MIN_SAMPLE_SIZE = 10
RETRY_CLASSIFICATION_CRITICAL_COVERAGE_THRESHOLD = RETRY_CLASSIFICATION_COVERAGE_THRESHOLD / 2
RETRY_CLASSIFICATION_CRITICAL_MIN_SAMPLE_SIZE = 40
DIAGNOSTIC_COVERAGE_THRESHOLD = 0.35
DIAGNOSTIC_COVERAGE_CRITICAL_THRESHOLD = 0.25
DIAGNOSTIC_COVERAGE_MIN_SAMPLE_SIZE = 20
ACTIVE_IMPROVEMENT_STATUSES = {"pending_approval", "approved", "queued", "running"}
TITLE_FAMILY_RETRY_COOLDOWN_SECONDS = max(
    0,
    int(os.environ.get("SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS", "7200") or "7200"),
)
TITLE_FAMILY_FAILURE_STREAK_THRESHOLD = max(
    1,
    int(os.environ.get("SELF_IMPROVE_TITLE_FAMILY_FAILURE_STREAK_THRESHOLD", "2") or "2"),
)
TITLE_FAMILY_SATURATION_COOLDOWN_SECONDS = max(
    TITLE_FAMILY_RETRY_COOLDOWN_SECONDS,
    int(os.environ.get("SELF_IMPROVE_TITLE_FAMILY_SATURATION_COOLDOWN_SECONDS", "86400") or "86400"),
)
SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS = max(
    TITLE_FAMILY_RETRY_COOLDOWN_SECONDS,
    int(os.environ.get("SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS", "86400") or "86400"),
)
PIPELINE_STALE_RETRY_SECONDS = max(
    TITLE_FAMILY_RETRY_COOLDOWN_SECONDS,
    int(os.environ.get("SELF_IMPROVE_PIPELINE_STALE_RETRY_SECONDS", "14400") or "14400"),
)
OVERLOAD_FAMILY_OUTCOME_LOOKBACK_SECONDS = max(
    SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS,
    int(os.environ.get("SELF_IMPROVE_OVERLOAD_FAMILY_OUTCOME_LOOKBACK_SECONDS", "604800") or "604800"),
)
TERMINAL_SUCCESS_STATUSES = {"completed"}
TERMINAL_FAILURE_STATUSES = {"failed", "shelved"}
ZOMBIE_FAILURE_THRESHOLD = 5
NON_RETRYABLE_FAILURE_KINDS = {"timeout", "missing_environment", "missing_platform"}


def env_float(name: str, default: float) -> float:
    raw = str(os.environ.get(name, "") or "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


ZERO_STEP_TIMEOUT_ALERT_THRESHOLD = min(
    1.0,
    max(
        0.0,
        env_float("SELF_IMPROVE_ZERO_STEP_TIMEOUT_ALERT_THRESHOLD", 0.5),
    ),
)
ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD = min(
    1.0,
    max(
        ZERO_STEP_TIMEOUT_ALERT_THRESHOLD,
        env_float("SELF_IMPROVE_ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD", 0.75),
    ),
)
PLANNING_BUDGET_RETRY_SECONDS = max(
    0,
    int(os.environ.get("SELF_IMPROVE_PLANNING_BUDGET_RETRY_SECONDS", "7200") or "7200"),
)

# Read metrics
try:
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    metrics = {}

# Read registry
try:
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    tasks = registry.get("tasks", [])
except Exception:
    tasks = []
if not isinstance(tasks, list):
    tasks = []

explicit_registry_project_keys = {
    re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", re.sub(r"\s+", " ", str(task.get("project") or task.get("target_project") or "").strip().lower())))
    for task in tasks
    if isinstance(task, dict) and str(task.get("project") or task.get("target_project") or "").strip()
}
registry_uses_explicit_project_scoping = bool(explicit_registry_project_keys)


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project_key(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", normalize_text(value)))


def improvement_title_key(value: Any) -> str:
    text = normalize_text(value)
    if text.startswith("[self-improve:") and "]" in text:
        text = text.split("]", 1)[1].strip()
    if " (files:" in text:
        text = text.split(" (files:", 1)[0].strip()
    if " -- " in text:
        text = text.split(" -- ", 1)[0].strip()
    if not text:
        return ""

    if "drain approved task backlog" in text or "drain approval backlog" in text:
        return "drain approval backlog"
    if text.startswith("inventory current decision path for "):
        return text

    stable_prefixes = (
        "recover stale pipeline",
        "improve timeout diagnostic coverage",
        "cap pre-step planning budget",
        "improve retry failure classification coverage",
        "improve retry success rate",
        "improve first-pass success rate",
        "reduce timeout rate",
        "reduce registry pressure",
        "break retry churn",
        "reduce strategy saturation",
        "drain approval backlog",
        "refresh stale external signals",
    )
    for prefix in stable_prefixes:
        if prefix in text:
            return prefix
    if text.startswith("fix repeated failure:"):
        return text
    return text


def extract_spec_milestone_seed_block(spec_text: str) -> str | None:
    match = re.search(
        r"(?ms)^## Milestone Seeds\s*\n```json\s*\n(.*?)\n```\s*(?=^## |\Z)",
        spec_text,
    )
    if not match:
        return None
    payload = str(match.group(1) or "").strip()
    return payload or None


def strip_spec_milestone_seed_block(spec_text: str) -> str:
    return re.sub(
        r"(?ms)^## Milestone Seeds\s*\n```json\s*\n.*?\n```\s*(?=^## |\Z)",
        "",
        spec_text,
    ).strip()


def parse_spec_milestone_seeds(spec_text: str) -> tuple[bool, list[dict[str, Any]]]:
    payload = extract_spec_milestone_seed_block(spec_text)
    if not payload:
        return False, []
    try:
        decoded = json.loads(payload)
    except Exception:
        return False, []
    if isinstance(decoded, dict):
        decoded = decoded.get("seeds")
    if not isinstance(decoded, list):
        return True, []
    return True, [item for item in decoded if isinstance(item, dict)]


def seed_string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item or "").strip()]
    text = str(value or "").strip()
    return [text] if text else []


def resolve_workspace_file(candidate: Any) -> tuple[Path | None, str]:
    relative_path = str(candidate or "").strip()
    if not relative_path:
        return None, ""
    path = Path(relative_path)
    resolved = path.resolve() if path.is_absolute() else (project_workspace / path).resolve()
    try:
        relative = resolved.relative_to(project_workspace).as_posix()
    except Exception:
        return None, ""
    if not resolved.is_file():
        return None, relative
    return resolved, relative


def expand_workspace_seed_paths(entries: Any) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for entry in seed_string_list(entries):
        matched_paths: list[Path] = []
        if any(token in entry for token in "*?[]"):
            matched_paths = sorted(project_workspace.glob(entry))
        else:
            matched_paths = [project_workspace / entry]
        for path in matched_paths:
            resolved = path.resolve()
            try:
                relative = resolved.relative_to(project_workspace).as_posix()
            except Exception:
                continue
            if not resolved.is_file() or relative in seen:
                continue
            seen.add(relative)
            results.append(relative)
    return results


class SeedFormatMap(dict[str, str]):
    def __missing__(self, key: str) -> str:
        return ""


def external_project_structured_spec_seed_improvements(
    spec_seeds: list[dict[str, Any]],
    spec_ref: str,
) -> list[dict[str, Any]]:
    improvements: list[dict[str, Any]] = []
    for seed in spec_seeds:
        title = str(seed.get("title") or "").strip()
        target_file = str(seed.get("target_file") or "").strip()
        reason_template = str(seed.get("reason_template") or "").strip()
        done_markers = seed_string_list(seed.get("done_markers"))
        if not title or not target_file or not reason_template or not done_markers:
            continue

        target_path, target_relative = resolve_workspace_file(target_file)
        if target_path is None or not target_relative:
            continue

        required_files = expand_workspace_seed_paths(seed.get("required_files"))
        if seed_string_list(seed.get("required_files")) and not required_files:
            continue

        required_markers = seed.get("required_markers")
        required_markers_ok = True
        if isinstance(required_markers, list):
            for item in required_markers:
                if not isinstance(item, dict):
                    required_markers_ok = False
                    break
                marker = str(item.get("marker") or "").strip()
                marker_path, _ = resolve_workspace_file(item.get("file"))
                if not marker or marker_path is None:
                    required_markers_ok = False
                    break
                try:
                    marker_text = marker_path.read_text(encoding="utf-8")
                except Exception:
                    required_markers_ok = False
                    break
                if normalize_text(marker).lower() not in normalize_text(marker_text).lower():
                    required_markers_ok = False
                    break
        if not required_markers_ok:
            continue

        try:
            target_text = target_path.read_text(encoding="utf-8")
        except Exception:
            continue
        normalized_target_text = normalize_text(target_text).lower()
        if all(normalize_text(marker).lower() in normalized_target_text for marker in done_markers):
            continue

        reference_paths = expand_workspace_seed_paths(seed.get("reference_files"))
        reference_paths.extend(
            path
            for path in expand_workspace_seed_paths(seed.get("reference_globs"))
            if path not in reference_paths
        )
        reference_limit = max(0, safe_int(seed.get("reference_limit"), 0))
        if reference_limit > 0:
            reference_paths = reference_paths[:reference_limit]
        reference_min_count = max(0, safe_int(seed.get("reference_min_count"), 0))
        if reference_min_count > 0 and len(reference_paths) < reference_min_count:
            continue

        anchor = str(seed.get("anchor") or "").strip()
        reason = reason_template.format_map(SeedFormatMap({
            "anchor": anchor,
            "done_markers": ", ".join(f"`{marker}`" for marker in done_markers),
            "first_done_marker": done_markers[0],
            "milestone": str(seed.get("milestone") or "").strip(),
            "reference_paths": ", ".join(f"`{path}`" for path in reference_paths),
            "spec_ref": spec_ref,
            "target_file": target_relative,
        })).strip()
        if not reason:
            continue

        improvements.append({
            "title": title,
            "category": str(seed.get("category") or "learning").strip() or "learning",
            "reason": reason,
            "priority": str(seed.get("priority") or "medium").strip() or "medium",
            "target_files": [target_relative],
            "impact": max(1, safe_int(seed.get("impact"), 4)),
            "effort": max(1, safe_int(seed.get("effort"), 2)),
            "confidence": max(0.0, min(1.0, safe_float(seed.get("confidence"), 0.8))),
            "success_signals": seed_string_list(seed.get("success_signals")),
            "verification_command": str(seed.get("verification_command") or "").strip(),
        })

    return improvements


SELF_IMPROVE_PLAYBOOKS = {
    "retry-classification": "playbooks/retry-classification.md",
    "zero-step-timeouts": "playbooks/zero-step-timeouts.md",
    "stale-pipeline": "playbooks/stale-pipeline.md",
}


def select_self_improve_playbook_metadata(title: Any, reason: Any = "", target_files: Any = None) -> dict[str, str]:
    title_key = improvement_title_key(title)
    normalized_reason = normalize_text(reason).lower()
    normalized_files = " ".join(
        normalize_text(path).lower()
        for path in (target_files if isinstance(target_files, list) else [])
        if normalize_text(path)
    )

    family = ""
    if (
        title_key == "improve retry failure classification coverage"
        or ("retry" in title_key and "classif" in title_key)
        or ("retry" in normalized_reason and "classif" in normalized_reason)
    ):
        family = "retry-classification"
    elif (
        title_key in {
            "cap pre-step planning budget",
            "reduce timeout rate",
            "improve timeout diagnostic coverage",
        }
        or "zero-step" in normalized_reason
        or ("timeout" in title_key and "planning" in normalized_reason)
        or ("timeout" in title_key and "planner" in normalized_files)
    ):
        family = "zero-step-timeouts"
    elif "stale pipeline" in title_key or "stale pipeline" in normalized_reason:
        family = "stale-pipeline"

    playbook = SELF_IMPROVE_PLAYBOOKS.get(family, "")
    if not family or not playbook:
        return {}
    return {"family": family, "playbook": playbook}


EXTERNAL_PROJECT_INTERNAL_TITLE_KEYS = {
    "recover stale pipeline",
    "improve timeout diagnostic coverage",
    "cap pre-step planning budget",
    "improve retry failure classification coverage",
    "improve retry success rate",
    "improve first-pass success rate",
    "reduce timeout rate",
    "reduce registry pressure",
    "break retry churn",
    "reduce strategy saturation",
    "drain approval backlog",
    "refresh stale external signals",
}


def external_project_internal_improvement_title(title: Any) -> bool:
    if not enforce_workspace_target_validation:
        return False

    structured_seed_title_keys: set[str] = set()
    if project_spec_path.is_file():
        try:
            _parsed_structured_seeds, structured_spec_seeds = parse_spec_milestone_seeds(
                project_spec_path.read_text(encoding="utf-8")
            )
            structured_seed_title_keys = {
                normalize_improvement_title(seed.get("title") or "")
                for seed in structured_spec_seeds
                if normalize_improvement_title(seed.get("title") or "")
            }
        except Exception:
            structured_seed_title_keys = set()

    title_key = improvement_title_key(title)
    if not title_key:
        return False
    if title_key in EXTERNAL_PROJECT_INTERNAL_TITLE_KEYS:
        return True
    if title_key.startswith("fix repeated failure:"):
        return True
    if title_key.startswith("inventory current decision path for "):
        source_title = title_key.removeprefix("inventory current decision path for ").strip()
        return (
            source_title in EXTERNAL_PROJECT_INTERNAL_TITLE_KEYS
            or source_title.startswith("fix repeated failure:")
            or source_title in structured_seed_title_keys
        )
    return False


def humanize_identifier(value: Any) -> str:
    return normalize_text(str(value or "").replace("_", " ").replace("-", " "))


def extract_dashboard_payload_fields_from_web_readme(text: str) -> list[str]:
    if not text:
        return []
    match = re.search(r"(?ms)^### First Dashboard Incident Payload\s*(.+?)(?=^### |\Z)", text)
    if not match:
        return []
    fields: list[str] = []
    seen: set[str] = set()
    for candidate in re.findall(r"`([A-Za-z0-9_]+)`\s*:", match.group(1)):
        normalized = normalize_text(candidate)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        fields.append(normalized)
    return fields


def external_project_telemetry_playbook_gap_improvements() -> list[dict[str, Any]]:
    if not enforce_workspace_target_validation:
        return []

    telemetry_schema_path = project_workspace / "packages/schema/telemetry-event.schema.json"
    incident_schema_path = project_workspace / "packages/schema/incident.schema.json"
    schema_readme_path = project_workspace / "packages/schema/README.md"
    playbook_path = project_workspace / "packages/playbooks/account_recovery_after_credential_risk.json"

    if not telemetry_schema_path.is_file() or not incident_schema_path.is_file() or not playbook_path.is_file():
        return []

    try:
        telemetry_schema = json.loads(telemetry_schema_path.read_text(encoding="utf-8"))
        incident_schema = json.loads(incident_schema_path.read_text(encoding="utf-8"))
        playbook = json.loads(playbook_path.read_text(encoding="utf-8"))
    except Exception:
        return []

    if not isinstance(telemetry_schema, dict) or not isinstance(incident_schema, dict) or not isinstance(playbook, dict):
        return []

    telemetry_properties = telemetry_schema.get("properties") if isinstance(telemetry_schema.get("properties"), dict) else {}
    telemetry_event_type = telemetry_properties.get("event_type") if isinstance(telemetry_properties.get("event_type"), dict) else {}
    telemetry_event_types = {
        normalize_text(item)
        for item in (telemetry_event_type.get("enum") if isinstance(telemetry_event_type.get("enum"), list) else [])
        if normalize_text(item)
    }
    telemetry_examples = telemetry_schema.get("examples") if isinstance(telemetry_schema.get("examples"), list) else []
    telemetry_example_event_types = {
        normalize_text(example.get("event_type"))
        for example in telemetry_examples
        if isinstance(example, dict) and normalize_text(example.get("event_type"))
    }

    incident_properties = incident_schema.get("properties") if isinstance(incident_schema.get("properties"), dict) else {}
    incident_type_property = incident_properties.get("incident_type") if isinstance(incident_properties.get("incident_type"), dict) else {}
    incident_types = {
        normalize_text(item)
        for item in (incident_type_property.get("enum") if isinstance(incident_type_property.get("enum"), list) else [])
        if normalize_text(item)
    }
    playbook_id_property = incident_properties.get("playbook_id") if isinstance(incident_properties.get("playbook_id"), dict) else {}
    incident_playbook_ids = {
        normalize_text(item)
        for item in (playbook_id_property.get("enum") if isinstance(playbook_id_property.get("enum"), list) else [])
        if normalize_text(item)
    }

    playbook_incident_type = normalize_text(playbook.get("incident_type"))
    playbook_id = normalize_text(playbook.get("id"))
    trigger_event_types = [
        normalize_text(item)
        for item in (playbook.get("trigger_event_types") if isinstance(playbook.get("trigger_event_types"), list) else [])
        if normalize_text(item)
    ]
    missing_trigger_event_types = [
        event_type
        for event_type in trigger_event_types
        if event_type not in telemetry_event_types
    ]

    schema_readme_text = ""
    if schema_readme_path.is_file():
        try:
            schema_readme_text = schema_readme_path.read_text(encoding="utf-8")
        except Exception:
            schema_readme_text = ""

    if (
        not playbook_incident_type
        or not playbook_id
        or playbook_incident_type not in incident_types
        or playbook_id not in incident_playbook_ids
        or not missing_trigger_event_types
        or "every incident must map to at least one event" not in schema_readme_text.lower()
    ):
        return []

    missing_example_event_types = [
        event_type
        for event_type in trigger_event_types
        if event_type not in telemetry_example_event_types
    ]
    missing_examples_clause = ""
    if missing_example_event_types:
        missing_examples_clause = (
            " Extend the root `examples` array with one canonical credential-risk event payload "
            f"using `{missing_example_event_types[0]}` so the new enum has concrete contract coverage."
        )

    missing_trigger_text = ", ".join(f"`{event_type}`" for event_type in missing_trigger_event_types[:2])
    return [{
        "title": "Add credential recovery trigger coverage to telemetry event schema",
        "category": "learning",
        "reason": (
            "Start with `packages/schema/telemetry-event.schema.json` in `properties.event_type.enum` and the root "
            "`examples` array. `packages/playbooks/account_recovery_after_credential_risk.json` expects trigger "
            f"event types {missing_trigger_text}, while the schema package rule says every incident must map "
            "to at least one event and `packages/schema/incident.schema.json` already exposes "
            "`credential_recovery_required` incidents through the matching playbook id. Add the missing credential "
            "recovery trigger event types to the telemetry contract so the first-slice event-to-incident path stays "
            f"internally consistent.{missing_examples_clause}"
        ),
        "priority": "high",
        "target_files": ["packages/schema/telemetry-event.schema.json"],
        "impact": 6,
        "effort": 2,
        "confidence": 0.84,
    }]


def external_project_spec_milestone_improvements() -> list[dict[str, Any]]:
    if not enforce_workspace_target_validation:
        return []

    first_slice_path = project_workspace / "docs/architecture/first-slice.md"
    overview_path = project_workspace / "docs/overview.md"
    cloud_brain_readme_path = project_workspace / "apps/cloud-brain/README.md"
    verify_baseline_path = project_workspace / "scripts/verify-baseline.sh"
    if not project_spec_path.is_file():
        return []

    try:
        spec_text = project_spec_path.read_text(encoding="utf-8")
    except Exception:
        return []

    try:
        spec_ref = project_spec_path.resolve().relative_to(root_dir).as_posix()
    except Exception:
        spec_ref = project_spec_path.name

    parsed_structured_seeds, structured_spec_seeds = parse_spec_milestone_seeds(spec_text)
    if parsed_structured_seeds:
        return external_project_structured_spec_seed_improvements(structured_spec_seeds, spec_ref)

    normalized_spec_text = normalize_text(strip_spec_milestone_seed_block(spec_text)).lower()
    first_slice_text = ""
    if first_slice_path.is_file():
        try:
            first_slice_text = first_slice_path.read_text(encoding="utf-8")
        except Exception:
            first_slice_text = ""
    normalized_first_slice_text = normalize_text(first_slice_text).lower()
    overview_text = ""
    if overview_path.is_file():
        try:
            overview_text = overview_path.read_text(encoding="utf-8")
        except Exception:
            overview_text = ""
    normalized_overview_text = normalize_text(overview_text).lower()
    cloud_brain_readme_text = ""
    if cloud_brain_readme_path.is_file():
        try:
            cloud_brain_readme_text = cloud_brain_readme_path.read_text(encoding="utf-8")
        except Exception:
            cloud_brain_readme_text = ""
    normalized_cloud_brain_readme_text = normalize_text(cloud_brain_readme_text).lower()
    if "confirm mandatory mvp protection cases." in normalized_spec_text:
        if not first_slice_path.is_file():
            return []
        if "mandatory mvp protection cases" not in normalized_first_slice_text:
            playbook_dir = project_workspace / "packages/playbooks"
            if not playbook_dir.is_dir():
                return []

            playbook_paths: list[str] = []
            for path in sorted(playbook_dir.glob("*.json")):
                if not path.is_file():
                    continue
                try:
                    playbook_paths.append(path.resolve().relative_to(project_workspace).as_posix())
                except Exception:
                    continue
            if not playbook_paths:
                return []

            playbook_refs = ", ".join(f"`{path}`" for path in playbook_paths[:4])
            return [{
                "title": "Document mandatory MVP protection cases in first slice",
                "category": "learning",
                "reason": (
                    "Start with `docs/architecture/first-slice.md` after `## Scope`. "
                    f"`{spec_ref}` lists milestone `Confirm mandatory MVP protection cases.`, "
                    "but the first-slice architecture doc does not yet define a dedicated `## Mandatory MVP Protection Cases` "
                    f"section. Add one deterministic section that enumerates the currently supported first-slice protection cases backed by {playbook_refs}."
                ),
                "priority": "medium",
                "target_files": ["docs/architecture/first-slice.md"],
                "impact": 5,
                "effort": 2,
                "confidence": 0.84,
            }]

    if (
        "define the initial learning-center scope tied to incidents." in normalized_spec_text
        and overview_path.is_file()
    ):
        if "incident-linked learning scope" not in normalized_overview_text:
            return [{
                "title": "Define incident-linked learning scope in overview",
                "category": "learning",
                "reason": (
                    "Start with `docs/overview.md` after `## Current Focus`. "
                    f"`{spec_ref}` lists milestone `Define the initial learning-center scope tied to incidents.`, "
                    "but the overview does not yet define a dedicated `## Incident-Linked Learning Scope` section. "
                    "Add one deterministic section that ties the first learning-center scope to the current incident families, "
                    "their matching learning themes, and the narrow v1 boundaries for when learning is attached."
                ),
                "priority": "medium",
                "target_files": ["docs/overview.md"],
                "impact": 4,
                "effort": 2,
                "confidence": 0.82,
            }]

    if (
        "bootstrap the first production-lean code slice in the repo." in normalized_spec_text
        and cloud_brain_readme_path.is_file()
    ):
        if "first production-lean slice" not in normalized_cloud_brain_readme_text:
            return [{
                "title": "Document first production-lean cloud-brain slice",
                "category": "learning",
                "reason": (
                    "Start with `apps/cloud-brain/README.md` after `## Decision Table`. "
                    f"`{spec_ref}` lists milestone `Bootstrap the first production-lean code slice in the repo.`, "
                    "but the cloud-brain blueprint does not yet define a dedicated `## First Production-Lean Slice` section. "
                    "Add one deterministic section that names the minimal first-slice code path and its concrete runtime anchors in "
                    "`apps/cloud-brain/src/incident-flow.mjs`, `apps/cloud-brain/scripts/smoke.mjs`, and the public schema/playbook contracts."
                ),
                "priority": "medium",
                "target_files": ["apps/cloud-brain/README.md"],
                "impact": 5,
                "effort": 2,
                "confidence": 0.83,
            }]

    if (
        "add verification gates for every initial component." in normalized_spec_text
        and verify_baseline_path.is_file()
        and "incident-linked learning scope" in normalized_overview_text
        and "first production-lean slice" in normalized_cloud_brain_readme_text
    ):
        try:
            verify_baseline_text = verify_baseline_path.read_text(encoding="utf-8")
        except Exception:
            verify_baseline_text = ""
        normalized_verify_baseline_text = normalize_text(verify_baseline_text).lower()
        if (
            "incident-linked learning scope" not in normalized_verify_baseline_text
            or "first production-lean slice" not in normalized_verify_baseline_text
        ):
            return [{
                "title": "Extend baseline verification for initial learning and slice markers",
                "category": "stability",
                "reason": (
                    "Start with `scripts/verify-baseline.sh` near the top-level path constants and the existing "
                    "`require_pattern` block after the README checks. "
                    f"`{spec_ref}` lists milestone `Add verification gates for every initial component.`, "
                    "but baseline verification still does not require `docs/overview.md` to keep "
                    "`## Incident-Linked Learning Scope` or `apps/cloud-brain/README.md` to keep "
                    "`## First Production-Lean Slice`. Add the missing deterministic file constant plus "
                    "`require_file`/`require_pattern` checks so the initial component markers stay guarded."
                ),
                "priority": "medium",
                "target_files": ["scripts/verify-baseline.sh"],
                "impact": 5,
                "effort": 2,
                "confidence": 0.84,
            }]

    return []


def external_project_contains_path(candidate: Any) -> bool:
    if not enforce_workspace_target_validation:
        return False
    candidate_text = str(candidate or "").strip()
    if not candidate_text:
        return False
    path = Path(candidate_text)
    resolved = path.resolve() if path.is_absolute() else (project_workspace / path).resolve()
    try:
        resolved.relative_to(project_workspace)
    except Exception:
        return False
    return resolved.is_file()


def external_project_has_history_grounding(title: Any) -> bool:
    if not enforce_workspace_target_validation:
        return False
    title_key = improvement_title_key(title)
    if not title_key:
        return False

    for task in reversed(tasks):
        if not isinstance(task, dict):
            continue
        candidate_title = (
            task.get("title")
            or task.get("execution_task")
            or ((task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else "")
        )
        if improvement_title_key(candidate_title) != title_key:
            continue

        step_artifacts = task.get("step_artifacts") if isinstance(task.get("step_artifacts"), dict) else {}
        for artifact in step_artifacts.values():
            if not isinstance(artifact, dict):
                continue
            if external_project_contains_path(artifact.get("identified_file")):
                return True
            inspected = artifact.get("supporting_files_inspected")
            if isinstance(inspected, list) and any(external_project_contains_path(path) for path in inspected):
                return True

        raw_target_files = task.get("target_files")
        if isinstance(raw_target_files, list) and any(external_project_contains_path(path) for path in raw_target_files):
            return True

        task_intent = task.get("task_intent")
        affected_files = task_intent.get("affected_files") if isinstance(task_intent, dict) else []
        if isinstance(affected_files, list) and any(external_project_contains_path(path) for path in affected_files):
            return True

    return False


def external_project_contract_gap_improvements() -> list[dict[str, Any]]:
    if not enforce_workspace_target_validation:
        return []

    improvements: list[dict[str, Any]] = []
    incident_schema_path = project_workspace / "packages/schema/incident.schema.json"
    web_readme_path = project_workspace / "apps/web/README.md"
    incident_flow_path = project_workspace / "apps/cloud-brain/src/incident-flow.mjs"
    smoke_script_path = project_workspace / "apps/cloud-brain/scripts/smoke.mjs"
    verify_baseline_path = project_workspace / "scripts/verify-baseline.sh"
    if not incident_schema_path.is_file():
        return improvements

    try:
        incident_schema = json.loads(incident_schema_path.read_text(encoding="utf-8"))
    except Exception:
        return improvements

    if not isinstance(incident_schema, dict):
        return improvements

    examples = incident_schema.get("examples") if isinstance(incident_schema.get("examples"), list) else []
    automation_examples = []
    for example in examples:
        if not isinstance(example, dict):
            continue
        summary = normalize_text(example.get("summary"))
        household_id = normalize_text(example.get("household_id"))
        learning_modules = [
            normalize_text(item)
            for item in (example.get("recommended_learning_modules") if isinstance(example.get("recommended_learning_modules"), list) else [])
            if normalize_text(item)
        ]
        if (
            "recent_self_improve_failure_cooldown" in summary
            or "cap pre-step planning budget" in summary
            or household_id.startswith("hh_system_")
            or "bounded_inventory_pattern" in learning_modules
        ):
            automation_examples.append(example)

    if automation_examples:
        improvements.append({
            "title": "Remove automation runtime example from incident schema",
            "category": "learning",
            "reason": (
                "Start with `packages/schema/incident.schema.json` in the root `examples` array. "
                "One example contains control-plane automation markers like "
                "`recent_self_improve_failure_cooldown`, `cap pre-step planning budget`, or "
                "`bounded_inventory_pattern`, which do not belong in the public Superheld incident contract. "
                "Remove that runtime-only example and keep the schema examples product-facing."
            ),
            "priority": "critical",
            "target_files": ["packages/schema/incident.schema.json"],
            "impact": 7,
            "effort": 2,
            "confidence": 0.9,
        })

    properties = incident_schema.get("properties") if isinstance(incident_schema.get("properties"), dict) else {}
    required_fields = {
        normalize_text(item)
        for item in (incident_schema.get("required") if isinstance(incident_schema.get("required"), list) else [])
        if normalize_text(item)
    }
    web_readme_text = ""
    if web_readme_path.is_file():
        try:
            web_readme_text = web_readme_path.read_text(encoding="utf-8")
        except Exception:
            web_readme_text = ""
    dashboard_payload_fields = extract_dashboard_payload_fields_from_web_readme(web_readme_text)
    incident_flow_text = ""
    if incident_flow_path.is_file():
        try:
            incident_flow_text = incident_flow_path.read_text(encoding="utf-8")
        except Exception:
            incident_flow_text = ""
    smoke_text = ""
    if smoke_script_path.is_file():
        try:
            smoke_text = smoke_script_path.read_text(encoding="utf-8")
        except Exception:
            smoke_text = ""
    verify_baseline_text = ""
    if verify_baseline_path.is_file():
        try:
            verify_baseline_text = verify_baseline_path.read_text(encoding="utf-8")
        except Exception:
            verify_baseline_text = ""

    if dashboard_payload_fields and web_readme_text:
        missing_schema_fields = [
            field
            for field in dashboard_payload_fields
            if field not in properties or field not in required_fields
        ]
        if missing_schema_fields:
            field = missing_schema_fields[0]
            if field in incident_flow_text:
                improvements.append({
                    "title": f"Add dashboard {humanize_identifier(field)} field to incident schema",
                    "category": "code",
                    "reason": (
                        "Start with `packages/schema/incident.schema.json` in the root `properties` block, the "
                        "`required` array, and the examples section. "
                        "`apps/web/README.md` documents the first dashboard incident payload field "
                        f"`{field}`, and `apps/cloud-brain/src/incident-flow.mjs` already projects that field in "
                        "the runtime payload, but the public incident schema still omits it. Add the missing "
                        "deterministic schema property, require it in the public contract, and extend each existing "
                        "example object so the dashboard contract matches the runtime handoff everywhere the schema "
                        "already publishes public examples."
                    ),
                    "success_signals": [
                        f"`{field}` is present in the root `required` array",
                        f"`properties.{field}` is a required non-empty string contract",
                        f"every public incident example carries non-empty `{field}` coverage",
                    ],
                    "verification_command": (
                        "jq -e '. as $schema | (($schema.required | index(\""
                        f"{field}"
                        "\")) != null) and ($schema.properties."
                        f"{field}"
                        ".type == \"string\") and ($schema.properties."
                        f"{field}"
                        ".minLength == 1) and (($schema.examples | length) > 0) and ([ $schema.examples[] | (."
                        f"{field}"
                        "? // \"\") | (length > 0) ] | all)' packages/schema/incident.schema.json >/dev/null"
                    ),
                    "priority": "high",
                    "target_files": ["packages/schema/incident.schema.json"],
                    "impact": 6,
                    "effort": 2,
                    "confidence": 0.87,
                })
                return improvements

        if smoke_text:
            smoke_fields_match = re.search(
                r"(?ms)\bconst\s+dashboardIncidentFields\s*=\s*\[(.*?)\]",
                smoke_text,
            )
            smoke_fields = {
                normalize_text(item)
                for item in re.findall(r"\"([A-Za-z0-9_]+)\"", smoke_fields_match.group(1))
            } if smoke_fields_match else set()
            missing_smoke_fields = [
                field
                for field in dashboard_payload_fields
                if field in properties and field in required_fields and field in incident_flow_text and field not in smoke_fields
            ]
            if missing_smoke_fields:
                field = missing_smoke_fields[0]
                improvements.append({
                    "title": f"Verify dashboard {humanize_identifier(field)} field in smoke flow",
                    "category": "stability",
                    "reason": (
                        "Start with `apps/cloud-brain/scripts/smoke.mjs` around `dashboardIncidentFields` and the "
                        "dashboard payload assertions after `credentialRecoveryRun`. "
                        "`apps/web/README.md` and `packages/schema/incident.schema.json` now require the dashboard "
                        f"field `{field}`, and `apps/cloud-brain/src/incident-flow.mjs` already projects it, but "
                        "the smoke flow still does not include that field in the deterministic dashboard payload "
                        "coverage. Add one focused assertion so the smoke run fails when the emitted incident payload "
                        f"drops `{field}`."
                    ),
                    "success_signals": [
                        f"`dashboardIncidentFields` includes `{field}`",
                        f"the smoke flow asserts the emitted payload keeps `{field}`",
                    ],
                    "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing",
                    "priority": "high",
                    "target_files": ["apps/cloud-brain/scripts/smoke.mjs"],
                    "impact": 5,
                    "effort": 2,
                    "confidence": 0.86,
                })
                return improvements

        if verify_baseline_text:
            missing_verify_fields = [
                field
                for field in dashboard_payload_fields
                if field in properties and field in required_fields and field in incident_flow_text and field not in verify_baseline_text
            ]
            if missing_verify_fields:
                field = missing_verify_fields[0]
                improvements.append({
                    "title": f"Guard dashboard {humanize_identifier(field)} field in baseline verification",
                    "category": "stability",
                    "reason": (
                        "Start with `scripts/verify-baseline.sh` in the existing `require_query` block for "
                        "`packages/schema/incident.schema.json`. "
                        "`apps/web/README.md` and the public incident schema now require dashboard field "
                        f"`{field}`, but baseline verification still does not guard that contract field. Add one "
                        "deterministic jq check so the baseline fails immediately if the schema drops or loosens "
                        f"`{field}`."
                    ),
                    "success_signals": [
                        f"`scripts/verify-baseline.sh` rejects missing `{field}` schema coverage",
                    ],
                    "verification_command": "bash scripts/verify-baseline.sh",
                    "priority": "high",
                    "target_files": ["scripts/verify-baseline.sh"],
                    "impact": 5,
                    "effort": 2,
                    "confidence": 0.85,
                })
                return improvements

    incident_type_property = properties.get("incident_type") if isinstance(properties.get("incident_type"), dict) else {}
    incident_type_values = [
        normalize_text(item)
        for item in (incident_type_property.get("enum") if isinstance(incident_type_property.get("enum"), list) else [])
        if normalize_text(item)
    ]
    example_incident_types = {
        normalize_text(example.get("incident_type"))
        for example in examples
        if isinstance(example, dict) and normalize_text(example.get("incident_type"))
    }
    missing_incident_types = [
        incident_type
        for incident_type in incident_type_values
        if incident_type not in example_incident_types
    ]

    if missing_incident_types:
        missing_type = missing_incident_types[0]
        improvements.append({
            "title": f"Add canonical incident example for {humanize_identifier(missing_type)}",
            "category": "learning",
            "reason": (
                "Start with `packages/schema/incident.schema.json` in the root `examples` array after the existing "
                f"incident examples. The schema declares `properties.incident_type` value `{missing_type}` but the "
                "examples do not yet cover it. Add one deterministic, product-facing example that matches the "
                f"existing contract shape and uses `incident_type: \"{missing_type}\"`."
            ),
            "priority": "high",
            "target_files": ["packages/schema/incident.schema.json"],
            "impact": 6,
            "effort": 2,
            "confidence": 0.86,
        })

    improvements.extend(external_project_telemetry_playbook_gap_improvements())

    telemetry_schema_path = project_workspace / "packages/schema/telemetry-event.schema.json"
    account_recovery_playbook_path = project_workspace / "packages/playbooks/account_recovery_after_credential_risk.json"
    incident_flow_path = project_workspace / "apps/cloud-brain/src/incident-flow.mjs"
    smoke_script_path = project_workspace / "apps/cloud-brain/scripts/smoke.mjs"
    telemetry_schema = {}
    telemetry_examples = []
    telemetry_event_types: list[str] = []
    if telemetry_schema_path.is_file():
        try:
            telemetry_schema = json.loads(telemetry_schema_path.read_text(encoding="utf-8"))
        except Exception:
            telemetry_schema = {}
        if isinstance(telemetry_schema, dict):
            telemetry_examples = telemetry_schema.get("examples") if isinstance(telemetry_schema.get("examples"), list) else []
            telemetry_properties = telemetry_schema.get("properties") if isinstance(telemetry_schema.get("properties"), dict) else {}
            event_type_property = telemetry_properties.get("event_type") if isinstance(telemetry_properties.get("event_type"), dict) else {}
            telemetry_event_types = [
                normalize_text(item)
                for item in (event_type_property.get("enum") if isinstance(event_type_property.get("enum"), list) else [])
                if normalize_text(item)
            ]

    if incident_flow_path.is_file() and account_recovery_playbook_path.is_file():
        try:
            incident_flow_text = incident_flow_path.read_text(encoding="utf-8")
        except Exception:
            incident_flow_text = ""

        incident_flow_contains_credential_event = "credential_recovery_trigger" in incident_flow_text
        incident_flow_contains_credential_incident = "credential_recovery_required" in incident_flow_text
        incident_flow_contains_learning_modules = (
            "account_recovery_basics" in incident_flow_text
            and "password_manager_setup" in incident_flow_text
        )
        if (
            "credential_recovery_required" in incident_type_values
            and "credential_recovery_trigger" in telemetry_event_types
            and (
                not incident_flow_contains_credential_event
                or not incident_flow_contains_credential_incident
                or not incident_flow_contains_learning_modules
            )
        ):
            improvements.append({
                "title": "Add credential recovery support to incident flow",
                "category": "learning",
                "reason": (
                    "Start with `apps/cloud-brain/src/incident-flow.mjs` at `INCIDENT_TYPE_BY_EVENT`, "
                    "`LEARNING_MODULES_BY_INCIDENT`, and `buildIncidentSummary`. "
                    "`packages/schema/telemetry-event.schema.json` now includes `credential_recovery_trigger`, "
                    "`packages/schema/incident.schema.json` includes `credential_recovery_required`, and "
                    "`packages/playbooks/account_recovery_after_credential_risk.json` defines the matching playbook, "
                    "but the first cloud-brain incident flow still cannot derive the credential recovery incident path "
                    "and its deterministic learning modules. Extend the production-lean incident flow so the new event "
                    "maps to the credential recovery incident contract and returns the matching summary and learning recommendations."
                ),
                "priority": "high",
                "target_files": ["apps/cloud-brain/src/incident-flow.mjs"],
                "impact": 6,
                "effort": 2,
                "confidence": 0.85,
            })

        smoke_contains_credential_coverage = False
        if smoke_script_path.is_file():
            try:
                smoke_text = smoke_script_path.read_text(encoding="utf-8")
            except Exception:
                smoke_text = ""
            smoke_contains_credential_coverage = (
                "credential_recovery_trigger" in smoke_text
                and "credential_recovery_required" in smoke_text
                and "account_recovery_after_credential_risk" in smoke_text
            )
            telemetry_has_credential_example = any(
                isinstance(example, dict)
                and normalize_text(example.get("event_type")) == "credential_recovery_trigger"
                for example in telemetry_examples
            )
            if (
                incident_flow_contains_credential_event
                and incident_flow_contains_credential_incident
                and incident_flow_contains_learning_modules
                and telemetry_has_credential_example
                and not smoke_contains_credential_coverage
            ):
                improvements.append({
                    "title": "Add credential recovery smoke coverage to cloud-brain",
                    "category": "stability",
                    "reason": (
                        "Start with `apps/cloud-brain/scripts/smoke.mjs` in the `playbooks` list and the "
                        "post-run assertions after the existing example checks. "
                        "`apps/cloud-brain/src/incident-flow.mjs` already supports `credential_recovery_trigger`, "
                        "but the smoke script still only exercises the first three example events and never verifies "
                        "the `account_recovery_after_credential_risk` path. Add one deterministic smoke run using "
                        "the credential recovery example plus assertions for `incident_type: \"credential_recovery_required\"` "
                        "and playbook id `account_recovery_after_credential_risk`."
                    ),
                    "priority": "medium",
                    "target_files": ["apps/cloud-brain/scripts/smoke.mjs"],
                    "impact": 5,
                    "effort": 2,
                    "confidence": 0.83,
                })

    spec_seed_improvements = external_project_spec_milestone_improvements()
    existing_title_keys = {
        improvement_title_key(item.get("title") or "")
        for item in improvements
        if improvement_title_key(item.get("title") or "")
    }
    for item in spec_seed_improvements:
        title_key = improvement_title_key(item.get("title") or "")
        if title_key and title_key in existing_title_keys:
            continue
        improvements.append(item)
        if title_key:
            existing_title_keys.add(title_key)

    return improvements


def self_improve_metric_snapshot(title: Any, metrics: dict[str, Any]) -> dict[str, Any]:
    normalized = improvement_title_key(title)
    if not normalized:
        return {}

    if normalized == "improve retry failure classification coverage":
        coverage = safe_float(metrics.get("retry_classification_coverage"))
        classified = max(safe_int(metrics.get("retry_classified_count")), 0)
        total = max(safe_int(metrics.get("retry_total_count")), 0)
        display = f"{coverage:.0%} ({classified}/{total})" if total > 0 else f"{coverage:.0%}"
        return {
            "metric_name": "retry_classification_coverage",
            "direction": "increase",
            "value": coverage,
            "display": display,
        }

    if normalized == "improve timeout diagnostic coverage":
        coverage = safe_float(metrics.get("diagnostic_coverage"))
        failures_with_diagnostic = max(safe_int(metrics.get("failures_with_diagnostic")), 0)
        total_failure_records = max(safe_int(metrics.get("total_failure_records")), 0)
        display = (
            f"{coverage:.0%} ({failures_with_diagnostic}/{total_failure_records})"
            if total_failure_records > 0
            else f"{coverage:.0%}"
        )
        return {
            "metric_name": "diagnostic_coverage",
            "direction": "increase",
            "value": coverage,
            "display": display,
        }

    if normalized == "cap pre-step planning budget":
        zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
        return {
            "metric_name": "zero_step_timeout_rate",
            "direction": "decrease",
            "value": zero_step_timeout_rate,
            "display": f"{zero_step_timeout_rate:.0%}",
        }

    if normalized == "reduce timeout rate":
        timeout_rate = safe_float(
            metrics.get("timeout_rate")
            if metrics.get("timeout_rate") is not None
            else metrics.get("timeout_failure_rate")
        )
        return {
            "metric_name": "timeout_rate",
            "direction": "decrease",
            "value": timeout_rate,
            "display": f"{timeout_rate:.0%}",
        }

    if normalized == "improve first-pass success rate":
        first_pass_success_rate = safe_float(metrics.get("first_pass_success_rate"))
        return {
            "metric_name": "first_pass_success_rate",
            "direction": "increase",
            "value": first_pass_success_rate,
            "display": f"{first_pass_success_rate:.0%}",
        }

    if normalized == "reduce registry pressure":
        local_registry_bytes = max(
            safe_int(
                metrics.get("local_registry_bytes")
                if metrics.get("local_registry_bytes") is not None
                else metrics.get("registry_bytes"),
                0,
            ),
            0,
        )
        return {
            "metric_name": "local_registry_bytes",
            "direction": "decrease",
            "value": float(local_registry_bytes),
            "display": f"{max(0, local_registry_bytes // 1024)}KB",
        }

    if normalized == "refresh stale external signals":
        fresh_signal_count = max(safe_int(metrics.get("fresh_external_signal_count")), 0)
        signal_status = normalize_text(metrics.get("external_signal_status")).lower()
        display = (
            f"{fresh_signal_count} fresh signal"
            if fresh_signal_count == 1
            else f"{fresh_signal_count} fresh signals"
        )
        if fresh_signal_count <= 0 and signal_status:
            display = signal_status
        return {
            "metric_name": "fresh_external_signal_count",
            "direction": "increase",
            "value": float(fresh_signal_count),
            "display": display,
        }

    if normalized == "drain approval backlog":
        approved_backlog = max(
            safe_int(
                metrics.get("approved_backlog")
                if metrics.get("approved_backlog") is not None
                else metrics.get("approved_tasks"),
                0,
            ),
            0,
        )
        pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
        approval_backlog_total = max(
            approved_backlog,
            max(safe_int(metrics.get("backlog")), 0),
            approved_backlog + pending_approval_tasks,
        )
        return {
            "metric_name": "approval_backlog_total",
            "direction": "decrease",
            "value": float(approval_backlog_total),
            "display": str(approval_backlog_total),
        }

    if normalized == "recover stale pipeline":
        pipeline_stale = metrics.get("pipeline_stale") is True
        return {
            "metric_name": "pipeline_stale",
            "direction": "decrease",
            "value": 1.0 if pipeline_stale else 0.0,
            "display": "stale" if pipeline_stale else "healthy",
        }

    if normalized == "break retry churn":
        retry_churn_detected = metrics.get("retry_churn_detected") is True
        return {
            "metric_name": "retry_churn_detected",
            "direction": "decrease",
            "value": 1.0 if retry_churn_detected else 0.0,
            "display": "detected" if retry_churn_detected else "clear",
        }

    if normalized == "reduce strategy saturation":
        strategy_saturation_detected = metrics.get("strategy_saturation_detected") is True
        return {
            "metric_name": "strategy_saturation_detected",
            "direction": "decrease",
            "value": 1.0 if strategy_saturation_detected else 0.0,
            "display": "detected" if strategy_saturation_detected else "clear",
        }

    return {}


def apply_self_improve_metric_baseline(
    task: dict[str, Any],
    title: Any,
    metrics: dict[str, Any],
) -> tuple[dict[str, Any], bool]:
    if not isinstance(task, dict):
        return task, False
    snapshot = self_improve_metric_snapshot(title, metrics)
    if not snapshot:
        return task, False

    next_task = dict(task)
    changed = False
    if not str(next_task.get("metric_name") or "").strip():
        next_task["metric_name"] = snapshot["metric_name"]
        changed = True
    if not str(next_task.get("metric_direction") or "").strip():
        next_task["metric_direction"] = snapshot["direction"]
        changed = True
    if next_task.get("metric_before") in {None, ""}:
        next_task["metric_before"] = snapshot["value"]
        changed = True
    if not str(next_task.get("metric_before_display") or "").strip():
        next_task["metric_before_display"] = snapshot["display"]
        changed = True
    return next_task, changed


def metric_value_improved(before: float, after: float, direction: str) -> bool:
    normalized_direction = normalize_text(direction).lower()
    if normalized_direction == "increase":
        return after > before
    if normalized_direction == "decrease":
        return after < before
    return False


def project_title_identity_key(project: Any, title: Any) -> str:
    project_key_value = normalize_project_key(project)
    title_key_value = improvement_title_key(title)
    if not project_key_value or not title_key_value:
        return ""
    return f"{project_key_value}::{title_key_value}"


def task_latest_history_action(task: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    history = task.get("history")
    if not isinstance(history, list) or not history:
        return ""
    latest_entry = history[-1]
    if not isinstance(latest_entry, dict):
        return ""
    return normalize_text(latest_entry.get("action"))


def task_is_finalize_only_inventory_failure(task: dict[str, Any]) -> bool:
    if not isinstance(task, dict):
        return False
    if normalize_text(task.get("status")) != "failed":
        return False
    if normalize_text(task.get("strategy_template")) != "bounded_learning_inventory":
        return False

    execution_context = task.get("execution_context")
    if not isinstance(execution_context, dict):
        return False
    if normalize_text(execution_context.get("result")) != "failure":
        return False

    step_count = safe_int(execution_context.get("step_count"))
    completed_steps = safe_int(execution_context.get("completed_steps"))
    if step_count <= 0 or completed_steps < step_count:
        return False

    failed_step_index = safe_int(execution_context.get("failed_step_index"))
    failed_step = normalize_text(execution_context.get("failed_step"))
    if failed_step_index != 0 or failed_step:
        return False

    return True


def task_family_terminal_bucket(task: dict[str, Any]) -> str:
    status = normalize_text(task.get("status"))
    if status in ACTIVE_IMPROVEMENT_STATUSES:
        return "active"
    if status in TERMINAL_SUCCESS_STATUSES:
        return "success"
    if status == "shelved":
        latest_action = task_latest_history_action(task)
        shelved_reason = normalize_text(task.get("shelved_reason"))
        if latest_action == "auto_shelve" or shelved_reason.startswith("auto-shelved:"):
            return "neutral"
        return "failure"
    if status == "failed":
        return "failure"
    return "other"


GENERIC_REPEATED_FAILURE_PLACEHOLDERS = {
    "queue execution failed after exhausting retries.",
    "queue execution failed after exhausting retries",
    "task execution failed after exhausting retries.",
    "task execution failed after exhausting retries",
    "plan: created deterministic fallback plan.",
    "created deterministic fallback plan.",
    "claude print failed",
    "codex exec failed",
}
GENERIC_REPEATED_FAILURE_PREFIXES = (
    "non-retriable failure detected",
)


def is_generic_repeated_failure_placeholder(text: Any, failure_kind: Any = "") -> bool:
    normalized_text = normalize_text(text)
    normalized_failure_kind = normalize_text(failure_kind)
    if not normalized_text:
        return False
    if normalized_text in GENERIC_REPEATED_FAILURE_PLACEHOLDERS:
        return True
    if any(normalized_text.lower().startswith(prefix) for prefix in GENERIC_REPEATED_FAILURE_PREFIXES):
        return True
    if normalized_failure_kind in {"unknown", "unknown_persistent"} and (
        "after exhausting retries" in normalized_text
        or "timed out after exhausting retries" in normalized_text
    ):
        return True
    return False


def safe_int(value: Any, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def safe_float(value: Any, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def parse_iso8601(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def read_json_lines(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records

    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return records

    for raw_line in raw_lines:
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


project_key = normalize_project_key(project_name)

# Build permanent zombie/non-retryable blocklists from tasks.log using the
# same project-local identity as the queue worker guards. Failures in another
# project must not suppress the current project's self-improvement families.
zombie_blocklist: set[str] = set()
zombie_failure_counts: dict[str, int] = {}
non_retryable_blocklist: set[str] = set()
non_retryable_blocklist_reasons: dict[str, str] = {}
try:
    task_log_records = read_json_lines(task_log_path)
    identity_failure_counts: dict[str, int] = {}
    identity_last_failure_kind: dict[str, str] = {}
    for record in task_log_records:
        if normalize_text(record.get("result")) != "failure":
            continue
        identity_key = project_title_identity_key(
            record.get("project") or record.get("target_project"),
            str(record.get("task", "")),
        )
        if not identity_key:
            continue
        identity_failure_counts[identity_key] = identity_failure_counts.get(identity_key, 0) + 1
        failure_kind = normalize_text(record.get("failure_kind")).lower()
        if failure_kind:
            identity_last_failure_kind[identity_key] = failure_kind

    for identity_key, fail_count in identity_failure_counts.items():
        if fail_count >= ZOMBIE_FAILURE_THRESHOLD:
            zombie_blocklist.add(identity_key)
            zombie_failure_counts[identity_key] = fail_count
        last_kind = identity_last_failure_kind.get(identity_key, "")
        if last_kind in NON_RETRYABLE_FAILURE_KINDS and fail_count >= 2:
            non_retryable_blocklist.add(identity_key)
            non_retryable_blocklist_reasons[identity_key] = last_kind
except Exception:
    pass


def record_project_key(record: dict[str, Any]) -> str:
    return normalize_project_key(record.get("project") or record.get("target_project"))


def task_declared_project_key(task: dict[str, Any]) -> str:
    return normalize_project_key(task.get("project") or task.get("target_project"))


def task_project_key(task: dict[str, Any]) -> str:
    declared_key = task_declared_project_key(task)
    if declared_key:
        return declared_key
    if registry_uses_explicit_project_scoping:
        return ""
    return project_key


def dominant_registry_pressure_source(metrics_payload: dict[str, Any]) -> dict[str, Any]:
    sources = metrics_payload.get("task_registry_pressure_sources")
    if not isinstance(sources, list):
        return {}

    best: dict[str, Any] = {}
    best_bytes = -1
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
        if payload_bytes <= 0:
            continue
        project = str(entry.get("project") or "").strip() or "codex-agent-system"
        file_path = str(entry.get("file") or "").strip()
        candidate = {
            "project": project,
            "file": file_path,
            "payload_bytes": payload_bytes,
        }
        if (
            payload_bytes > best_bytes
            or (
                payload_bytes == best_bytes
                and (project, file_path) < (str(best.get("project") or ""), str(best.get("file") or ""))
            )
        ):
            best = candidate
            best_bytes = payload_bytes
    return best


def registry_pressure_source_for_project(metrics_payload: dict[str, Any], project: Any) -> dict[str, Any]:
    sources = metrics_payload.get("task_registry_pressure_sources")
    if not isinstance(sources, list):
        return {}

    target_key = normalize_project_key(project)
    if not target_key:
        return {}

    best: dict[str, Any] = {}
    best_bytes = -1
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        project_key = normalize_project_key(entry.get("project"))
        if project_key != target_key:
            continue
        payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
        candidate = {
            "project": str(entry.get("project") or "").strip(),
            "file": str(entry.get("file") or "").strip(),
            "payload_bytes": payload_bytes,
        }
        if payload_bytes > best_bytes:
            best = candidate
            best_bytes = payload_bytes
    return best


def read_recent_automation_memory_entries(path: Path | None, limit: int = 8) -> list[dict[str, str]]:
    if path is None or not path.is_file():
        return []

    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return []

    entries: list[dict[str, str]] = []
    for raw_line in reversed(raw_lines):
        line = str(raw_line or "").strip()
        if not line.startswith("- "):
            continue
        entry: dict[str, str] = {}
        for key, value in re.findall(
            r"([a-zA-Z_]+)=(.*?)(?=(?:\s+[a-zA-Z_]+=)|(?:\s+\|\s)|$)",
            line[2:],
        ):
            normalized_key = normalize_text(key).lower().replace(" ", "_")
            normalized_value = normalize_text(value)
            if normalized_key:
                entry[normalized_key] = normalized_value
        if entry:
            entries.append(entry)
        if len(entries) >= limit:
            break
    return entries


def normalize_automation_memory_field(value: Any) -> str:
    text = normalize_text(value)
    if not text:
        return ""
    return re.sub(r"^[\s|;:.,`'\"]+|[\s|;:.,`'\"]+$", "", text)


def automation_memory_outcome_bucket(value: Any) -> str:
    normalized = normalize_automation_memory_field(value)
    if normalized.startswith("success"):
        return "success"
    if normalized.startswith("failure"):
        return "failure"
    if normalized.startswith("informational"):
        return "informational"
    return normalized


def automation_memory_preferred_title(
    entries: list[dict[str, str]],
    available_titles: list[str],
) -> dict[str, str]:
    normalized_titles: dict[str, str] = {}
    for title in available_titles:
        normalized_title = normalize_text(title)
        title_key = improvement_title_key(normalized_title)
        if normalized_title and title_key and title_key not in normalized_titles:
            normalized_titles[title_key] = normalized_title

    if not normalized_titles:
        return {}

    superseded_title_keys: set[str] = set()
    for entry in entries:
        outcome_bucket = automation_memory_outcome_bucket(entry.get("outcome"))
        if outcome_bucket == "success":
            next_title = normalize_automation_memory_field(entry.get("next"))
            if next_title and next_title.lower() != "none":
                next_title_key = improvement_title_key(next_title)
                matched_title = normalized_titles.get(next_title_key)
                if matched_title and next_title_key not in superseded_title_keys:
                    return {
                        "title": matched_title,
                        "reason": "recent_success_next",
                    }

        if outcome_bucket not in {"success", "failure"}:
            continue

        for field_name in ("weakness", "improvement"):
            field_value = normalize_automation_memory_field(entry.get(field_name))
            if not field_value or field_value.lower() == "none":
                continue
            field_title_key = improvement_title_key(field_value)
            if field_title_key in normalized_titles:
                superseded_title_keys.add(field_title_key)
    return {}


def prioritize_preferred_title(
    improvements_list: list[dict[str, Any]],
    preferred_title: str,
) -> tuple[list[dict[str, Any]], bool]:
    preferred_key = improvement_title_key(preferred_title)
    if not preferred_key:
        return list(improvements_list), False

    preferred_item: dict[str, Any] | None = None
    highest_ranked_item = improvements_list[0] if improvements_list else None
    highest_ranked_band = improvement_priority_band(
        highest_ranked_item.get("priority") if isinstance(highest_ranked_item, dict) else ""
    )

    for item in improvements_list:
        title_key = improvement_title_key(item.get("title") or "")
        if title_key == preferred_key:
            preferred_item = item
            break

    if preferred_item is None:
        return list(improvements_list), False

    # Automation memory should only steer ordering within the same severity band.
    # It must not override a newly detected higher-priority weakness.
    preferred_band = improvement_priority_band(preferred_item.get("priority"))
    if preferred_band < highest_ranked_band:
        return list(improvements_list), False

    prioritized: list[dict[str, Any]] = []
    remainder: list[dict[str, Any]] = []
    applied = False
    for item in improvements_list:
        title_key = improvement_title_key(item.get("title") or "")
        if title_key == preferred_key:
            prioritized.append(item)
            applied = True
        else:
            remainder.append(item)
    if not applied:
        return list(improvements_list), False
    return prioritized + remainder, True


metrics_registry_total = safe_int(metrics.get("task_registry_total"), -1)
metrics_registry_counts_aligned = metrics_registry_total < 0 or metrics_registry_total == len(tasks)
task_log_records = read_json_lines(task_log_path)
retry_failure_records = read_json_lines(retry_analysis_path)
recent_automation_memory_entries = read_recent_automation_memory_entries(automation_memory_path)
project_tasks = [task for task in tasks if isinstance(task, dict) and task_project_key(task) == project_key]
project_task_log_records = [
    record for record in task_log_records if isinstance(record, dict) and record_project_key(record) == project_key
]
project_retry_failure_records = [
    record for record in retry_failure_records if isinstance(record, dict) and record_project_key(record) == project_key
]

project_success_rate = safe_float(metrics.get("success_rate"))
project_recent_success_rate = safe_float(metrics.get("recent_success_rate"))
project_timeout_rate = safe_float(metrics.get("timeout_failure_rate"))
project_first_pass_success_rate = safe_float(metrics.get("first_pass_success_rate"))
project_retry_classification_coverage = safe_float(metrics.get("retry_classification_coverage"))
project_retry_classified_count = max(safe_int(metrics.get("retry_classified_count")), 0)
project_retry_total_count = max(safe_int(metrics.get("retry_total_count")), 0)
project_zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
project_diagnostic_coverage = (
    safe_float(metrics.get("diagnostic_coverage"))
    if metrics.get("diagnostic_coverage") is not None and str(metrics.get("diagnostic_coverage")).strip() != ""
    else -1.0
)
project_recent_diagnostic_coverage = (
    safe_float(metrics.get("recent_diagnostic_coverage"))
    if metrics.get("recent_diagnostic_coverage") is not None and str(metrics.get("recent_diagnostic_coverage")).strip() != ""
    else -1.0
)
project_failures_with_diagnostic = max(safe_int(metrics.get("failures_with_diagnostic")), 0)
project_total_failure_records = max(safe_int(metrics.get("total_failure_records")), 0)
project_total_tasks = max(safe_int(metrics.get("total_tasks")), 0)
project_retry_churn_detected = metrics.get("retry_churn_detected") is True
project_queue_starvation_detected = metrics.get("queue_starvation_detected") is True
project_pending_approval_blocked_detected = metrics.get("pending_approval_blocked_detected") is True
project_pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
# v23 fix: prefer local approved count over cross-project backlog.
# Previously, approved_backlog included inaccessible cross-project tasks,
# causing a phantom backlog that triggered the overload gate indefinitely.
# Now we count only tasks in the LOCAL project registry as actionable backlog.
_local_approved = sum(
    1 for t in project_tasks
    if normalize_text(t.get("status")).lower() == "approved"
) if project_tasks else 0
_metrics_approved = max(safe_int(metrics.get("approved_tasks")), 0)
# Use registry count when available; fall back to metrics only if no registry
project_approved_tasks = _local_approved if project_tasks else _metrics_approved
project_queued_tasks = max(safe_int(metrics.get("queued_tasks")), 0)
project_running_tasks = max(safe_int(metrics.get("running_tasks")), 0)
persisted_pending_approval_tasks = project_pending_approval_tasks
persisted_approved_tasks = project_approved_tasks
persisted_queued_tasks = project_queued_tasks
persisted_running_tasks = project_running_tasks
persisted_queue_starvation_detected = project_queue_starvation_detected
project_loop_effort_task_count = max(safe_int(metrics.get("loop_effort_task_count")), 0)
project_loop_effort_extra_step_attempts = max(safe_int(metrics.get("loop_effort_extra_step_attempts")), 0)
project_retry_churn_actionable = (
    project_loop_effort_task_count > 0 or project_loop_effort_extra_step_attempts > 0
)
project_strategy_saturation_detected = metrics.get("strategy_saturation_detected") is True
project_saturated_failed_tasks = max(safe_int(metrics.get("saturated_failed_tasks")), 0)
project_pipeline_stale = metrics.get("pipeline_stale") is True
project_pipeline_stale_since = str(metrics.get("pipeline_stale_since") or "").strip() or None

if project_task_log_records:
    project_total_tasks = len(project_task_log_records)
    project_success_rate = round(
        sum(1 for record in project_task_log_records if str(record.get("result") or "").strip() == "SUCCESS")
        / project_total_tasks,
        2,
    )
    project_failure_records = [
        record
        for record in project_task_log_records
        if str(record.get("result") or "").strip() == "FAILURE"
    ]
    project_total_failure_records = len(project_failure_records)
    project_failures_with_diagnostic = sum(
        1 for record in project_failure_records if normalize_text(record.get("failed_step"))
    )
    project_diagnostic_coverage = round(
        project_failures_with_diagnostic / project_total_failure_records,
        2,
    ) if project_total_failure_records else 0
    recent_project_failures = project_failure_records[-50:]
    project_recent_diagnostic_coverage = round(
        sum(1 for record in recent_project_failures if normalize_text(record.get("failed_step")))
        / len(recent_project_failures),
        2,
    ) if recent_project_failures else 0
    if (
        build_task_index_by_id is not None
        and build_latest_success_timestamp_by_identity is not None
        and is_unresolved_timeout_record is not None
    ):
        tasks_by_id = build_task_index_by_id(project_tasks)
        latest_success_by_identity = build_latest_success_timestamp_by_identity(project_task_log_records)
        timeout_failure_records = sum(
            1
            for record in project_task_log_records
            if is_unresolved_timeout_record(record, tasks_by_id, latest_success_by_identity)
        )
    else:
        timeout_failure_records = sum(
            1
            for record in project_task_log_records
            if str(record.get("result") or "").strip() == "FAILURE"
            and str(record.get("failure_kind") or "").strip() == "timeout"
        )
    timeout_failure_events = sum(
        1
        for record in project_task_log_records
        if str(record.get("result") or "").strip() == "FAILURE"
        and str(record.get("failure_kind") or "").strip() == "timeout"
    )
    zero_step_timeouts = sum(
        1
        for record in project_task_log_records
        if str(record.get("result") or "").strip() == "FAILURE"
        and str(record.get("failure_kind") or "").strip() == "timeout"
        and safe_int(record.get("total_step_attempts")) == 0
    )
    project_timeout_rate = round(timeout_failure_records / project_total_tasks, 2) if project_total_tasks else 0
    project_zero_step_timeout_rate = round(zero_step_timeouts / timeout_failure_events, 2) if timeout_failure_events else 0
    recent_project_records = [
        record
        for record in project_task_log_records
        if str(record.get("result") or "").strip() in {"SUCCESS", "FAILURE"}
    ][-50:]
    project_recent_success_rate = round(
        sum(1 for record in recent_project_records if str(record.get("result") or "").strip() == "SUCCESS")
        / len(recent_project_records),
        2,
    ) if recent_project_records else 0
    if _compute_pipeline_staleness is not None:
        pipeline_stale_signal = _compute_pipeline_staleness(project_task_log_records, project_tasks)
        project_pipeline_stale = pipeline_stale_signal.get("pipeline_stale") is True
        project_pipeline_stale_since = (
            str(pipeline_stale_signal.get("pipeline_stale_since") or "").strip() or None
        )

project_pipeline_stale_age_hours = 0.0
if project_pipeline_stale_since:
    project_pipeline_stale_since_dt = parse_iso8601(project_pipeline_stale_since)
    if project_pipeline_stale_since_dt is not None:
        project_pipeline_stale_age_hours = max(
            0.0,
            (datetime.now(timezone.utc) - project_pipeline_stale_since_dt).total_seconds() / 3600.0,
        )

if project_tasks and build_first_pass_success_signal is not None:
    first_pass_signal = build_first_pass_success_signal(project_tasks, project_task_log_records)
    successful_resolutions = max(safe_int(first_pass_signal.get("first_pass_success_count")), 0) + max(
        safe_int(first_pass_signal.get("multi_attempt_resolved_count")),
        0,
    )
    if successful_resolutions > 0:
        project_first_pass_success_rate = safe_float(first_pass_signal.get("first_pass_success_rate"))

if project_tasks:
    project_pending_approval_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")).lower() == "pending_approval"
    )
    project_approved_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")).lower() == "approved"
    )
    project_queued_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")).lower() == "queued"
    )
    project_running_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")).lower() == "running"
    )

project_has_pipeline_recovery_history = any(
    improvement_title_key(task.get("title") or task.get("execution_task") or "") == "recover stale pipeline"
    for task in project_tasks
)

pipeline_recovery_retry_eligible = (
    project_pipeline_stale
    and project_pipeline_stale_since
    and (
        project_zero_step_timeout_rate < ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD
        or project_has_pipeline_recovery_history
    )
)

if project_tasks and build_persisted_board_health_signals is not None:
    board_health_signal = build_persisted_board_health_signals(project_tasks)
    project_retry_churn_detected = board_health_signal.get("retry_churn_detected") is True
    project_queue_starvation_detected = board_health_signal.get("queue_starvation_detected") is True
    project_pending_approval_blocked_detected = (
        board_health_signal.get("pending_approval_blocked_detected") is True
    )

metrics["retry_churn_detected"] = project_retry_churn_detected
metrics["queue_starvation_detected"] = project_queue_starvation_detected
metrics["pending_approval_blocked_detected"] = project_pending_approval_blocked_detected
metrics["pending_approval_tasks"] = project_pending_approval_tasks
metrics["approved_tasks"] = project_approved_tasks
metrics["approved_backlog"] = project_approved_tasks
metrics["queued_tasks"] = project_queued_tasks
metrics["running_tasks"] = project_running_tasks

if project_task_log_records and project_tasks and build_loop_effort_signal is not None:
    loop_effort_signal = build_loop_effort_signal(project_tasks)
    project_loop_effort_task_count = max(safe_int(loop_effort_signal.get("loop_effort_task_count")), 0)
    project_loop_effort_extra_step_attempts = max(
        safe_int(loop_effort_signal.get("loop_effort_extra_step_attempts")),
        0,
    )
    project_retry_churn_actionable = (
        project_loop_effort_task_count > 0 or project_loop_effort_extra_step_attempts > 0
    )

if project_tasks and build_strategy_saturation_signal is not None:
    strategy_saturation_signal = build_strategy_saturation_signal(project_tasks)
    project_strategy_saturation_detected = strategy_saturation_signal.get("detected") is True
    project_saturated_failed_tasks = max(
        safe_int(strategy_saturation_signal.get("saturated_failed_tasks")),
        0,
    )

if (
    project_retry_failure_records
    and build_retry_failure_kind_index is not None
    and effective_retry_classification is not None
):
    retry_failure_kind_index = build_retry_failure_kind_index(project_task_log_records)
    project_retry_total_count = len(project_retry_failure_records)
    project_retry_classified_count = sum(
        1
        for record in project_retry_failure_records
        if effective_retry_classification(record, retry_failure_kind_index) != "unknown"
    )
    project_retry_classification_coverage = round(
        project_retry_classified_count / project_retry_total_count,
        2,
    ) if project_retry_total_count else 0
else:
    retry_failure_kind_index = {}

# Analysis functions
def recent_failures(n: int = 20) -> list[dict]:
    failed = [t for t in tasks if str(t.get("status", "")).lower() == "failed"]
    return sorted(failed, key=lambda t: t.get("updated_at", ""), reverse=True)[:n]

def failure_categories() -> dict[str, int]:
    cats: dict[str, int] = {}
    for t in recent_failures(50):
        cat = str(t.get("category", "general")).lower()
        cats[cat] = cats.get(cat, 0) + 1
    return cats

def merge_target_files(primary: list[str], fallback: list[str], limit: int = 3) -> list[str]:
    merged: list[str] = []
    seen: set[str] = set()
    for raw_path in [*(primary or []), *(fallback or [])]:
        path = str(raw_path or "").strip()
        normalized = normalize_text(path)
        if not path or normalized in seen:
            continue
        merged.append(path)
        seen.add(normalized)
        if len(merged) >= limit:
            break
    return merged

def summarize_unknown_retry_task_context(limit: int = 20) -> dict[str, Any]:
    recent_contexts: list[dict[str, Any]] = []
    for record in project_retry_failure_records:
        if not isinstance(record, dict):
            continue
        if effective_retry_classification is not None:
            classification = effective_retry_classification(record, retry_failure_kind_index)
        else:
            classification = record.get("classification")
        if normalize_text(classification) != "unknown":
            continue
        task_context = record.get("task_context")
        if isinstance(task_context, dict):
            recent_contexts.append(task_context)

    if not recent_contexts:
        return {}

    recent_contexts = recent_contexts[-limit:]
    objective_counts: Counter[str] = Counter()
    context_hint_counts: Counter[str] = Counter()
    affected_file_counts: Counter[str] = Counter()

    for task_context in recent_contexts:
        objective = str(task_context.get("objective") or "").strip()
        context_hint = str(task_context.get("context_hint") or "").strip()
        affected_files = task_context.get("affected_files")

        if objective:
            objective_counts[objective] += 1
        if context_hint:
            context_hint_counts[context_hint] += 1
        if isinstance(affected_files, list):
            for raw_path in affected_files[:5]:
                path = str(raw_path or "").strip()
                if path:
                    affected_file_counts[path] += 1

    summary: dict[str, Any] = {
        "unknown_count": len(recent_contexts),
        "objective": objective_counts.most_common(1)[0][0] if objective_counts else "",
        "context_hint": context_hint_counts.most_common(1)[0][0] if context_hint_counts else "",
        "affected_files": [
            path for path, _count in affected_file_counts.most_common(3)
        ],
    }
    return summary

def timeout_prone_tasks() -> list[str]:
    """Find task patterns that frequently timeout."""
    timeout_keywords: dict[str, int] = {}
    for t in tasks:
        fc = t.get("failure_context") or {}
        if "timeout" in str(fc.get("failure_kind", "")).lower():
            for word in re.findall(r"[a-z]{4,}", str(t.get("title", "")).lower()):
                timeout_keywords[word] = timeout_keywords.get(word, 0) + 1
    return sorted(timeout_keywords, key=timeout_keywords.get, reverse=True)[:5]

def repeated_failure_patterns() -> list[dict]:
    """Find tasks that fail with the same error repeatedly."""
    error_counts: dict[str, list[str]] = {}
    for t in recent_failures(30):
        fc = t.get("failure_context") or {}
        error = str(fc.get("failed_step", "")).strip()[:100]
        normalized_error = normalize_text(error)
        failure_kind = normalize_text(fc.get("failure_kind")).lower()
        if not error:
            continue
        # Skip wrapper-level failures that do not expose a concrete root cause.
        if is_generic_repeated_failure_placeholder(normalized_error, failure_kind):
            continue
        error_counts.setdefault(error, []).append(str(t.get("id", "")))
    return [
        {"error": err, "count": len(ids), "task_ids": ids[:3]}
        for err, ids in error_counts.items()
        if len(ids) >= 2
    ]

def pending_approved_backlog() -> int:
    # v23 fix: only count LOCAL registry tasks as actionable backlog.
    # The previous max(registry, current_metrics, persisted_metrics) approach
    # inflated the backlog with inaccessible cross-project tasks, causing
    # the overload gate deadlock (backlog_overload blocked self-improvement
    # while the actual approved tasks were in an unreachable external registry).
    registry_backlog = sum(
        1 for t in project_tasks if str(t.get("status", "")).lower() in ("approved", "pending_approval")
    )
    # Only use metrics as fallback when we have no registry data
    if not project_tasks:
        current_metrics_backlog = max(project_approved_tasks, 0) + max(project_pending_approval_tasks, 0)
        return max(registry_backlog, current_metrics_backlog)
    return registry_backlog


def approval_backlog_snapshot() -> dict[str, int]:
    # v23 fix: use LOCAL registry counts only (consistent with pending_approved_backlog fix)
    registry_approved = sum(
        1 for t in project_tasks if str(t.get("status", "")).lower() == "approved"
    )
    registry_pending = sum(
        1 for t in project_tasks if str(t.get("status", "")).lower() == "pending_approval"
    )
    approved = registry_approved if project_tasks else max(project_approved_tasks, 0)
    pending = registry_pending if project_tasks else max(project_pending_approval_tasks, 0)
    total = max(pending_approved_backlog(), approved + pending)
    return {
        "approved": approved,
        "pending_approval": pending,
        "total": total,
    }


def backlog_queue_idle_without_self_improve() -> bool:
    if project_tasks:
        return not any(
            normalize_text(task.get("status")).lower() in {"queued", "running"}
            and not task_has_self_improve_backlog_signature(task)
            for task in project_tasks
        )
    return (
        project_queued_tasks == 0
        and project_running_tasks == 0
        and persisted_queued_tasks == 0
        and persisted_running_tasks == 0
    )


def pending_approval_pipeline_blocker_active() -> bool:
    approval_backlog = approval_backlog_snapshot()
    return (
        approval_backlog["pending_approval"] > 0
        and project_pipeline_stale
        and backlog_queue_idle_without_self_improve()
        and (
            project_pending_approval_blocked_detected
            or approval_backlog["approved"] == 0
        )
    )


def pending_approval_pipeline_blocker_active_from_metrics(metrics: dict[str, Any]) -> bool:
    approved_only_count = max(
        safe_int(
            metrics.get("approved_tasks")
            if metrics.get("approved_tasks") is not None
            else metrics.get("approved_backlog"),
            0,
        ),
        0,
    )
    pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
    queued_tasks = max(safe_int(metrics.get("queued_tasks")), 0)
    running_tasks = max(safe_int(metrics.get("running_tasks")), 0)
    return (
        pending_approval_tasks > 0
        and metrics.get("pipeline_stale") is True
        and queued_tasks == 0
        and running_tasks == 0
        and (
            metrics.get("pending_approval_blocked_detected") is True
            or approved_only_count == 0
        )
    )


def task_has_self_improve_backlog_signature(task: dict[str, Any]) -> bool:
    if not isinstance(task, dict):
        return False
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    source = normalize_text(task_intent.get("source") or task.get("source_task_id")).lower()
    if source == "self-improve":
        return True
    if normalize_text(task.get("strategy_template")).lower() == "self_improvement":
        return True
    for key in ("execution_task", "task", "title"):
        value = normalize_text(task.get(key)).lower()
        if value.startswith("[self-improve:"):
            return True
    return False


def is_active_self_improve_project_task(task: dict[str, Any]) -> bool:
    if not isinstance(task, dict):
        return False
    if normalize_text(task.get("status")).lower() not in ACTIVE_IMPROVEMENT_STATUSES:
        return False
    return task_has_self_improve_backlog_signature(task)


def approved_backlog_starvation_active() -> bool:
    approved_backlog = pending_approved_backlog()
    if approved_backlog <= BACKLOG_DRAIN_SIGNAL_THRESHOLD:
        return False
    if project_tasks:
        live_queue_empty = backlog_queue_idle_without_self_improve()
        persisted_queue_empty = live_queue_empty
    else:
        live_queue_empty = project_queued_tasks == 0 and project_running_tasks == 0
        persisted_queue_empty = persisted_queued_tasks == 0 and persisted_running_tasks == 0
    return (
        (project_queue_starvation_detected and live_queue_empty)
        or (persisted_queue_starvation_detected and persisted_queue_empty)
        or (approved_backlog > 0 and live_queue_empty and persisted_queue_empty)
    )


def ordered_unique_titles(values: list[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for value in values:
        title = str(value or "").strip()
        if not title or title in seen:
            continue
        ordered.append(title)
        seen.add(title)
    return ordered


def overload_candidate_static_priority(title: str) -> int:
    normalized = improvement_title_key(title)
    priorities = {
        "recover stale pipeline": 70,
        "improve timeout diagnostic coverage": 60,
        "cap pre-step planning budget": 55,
        "reduce timeout rate": 50,
        "break retry churn": 40,
        "improve retry failure classification coverage": 35,
        "improve retry success rate": 25,
        "improve first-pass success rate": 20,
        "drain approval backlog": 10,
    }
    return priorities.get(normalized, 0)


def overload_candidate_signal_priority(title: str) -> int:
    normalized = improvement_title_key(title)
    if normalized == "recover stale pipeline":
        if not project_pipeline_stale:
            return 0
        return min(35, 18 + int(project_pipeline_stale_age_hours // 3))
    if normalized == "improve timeout diagnostic coverage":
        if diagnostic_coverage < 0 or total_failure_records < DIAGNOSTIC_COVERAGE_MIN_SAMPLE_SIZE:
            return 0
        coverage_gap_points = max(
            0,
            int(round((DIAGNOSTIC_COVERAGE_THRESHOLD - diagnostic_coverage) * 100)),
        )
        zero_step_points = 0
        if zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_ALERT_THRESHOLD:
            zero_step_points = max(5, min(20, int(round(zero_step_timeout_rate * 20))))
        sample_points = min(10, total_failure_records // 25)
        critical_bonus = 0
        if (
            zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD
            and diagnostic_coverage < DIAGNOSTIC_COVERAGE_CRITICAL_THRESHOLD
        ):
            critical_bonus = 10
        return min(45, coverage_gap_points + zero_step_points + sample_points + critical_bonus)
    if normalized == "cap pre-step planning budget":
        if zero_step_timeout_rate < ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD:
            return 0
        zero_step_points = max(15, min(25, int(round(zero_step_timeout_rate * 25))))
        timeout_points = min(15, max(0, int(round(timeout_rate * 100)) // 2))
        return min(45, zero_step_points + timeout_points)
    if normalized == "reduce timeout rate":
        base_signal = min(20, max(0, int(round(timeout_rate * 100))))
        zero_step_bonus = 0
        if zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_ALERT_THRESHOLD:
            zero_step_bonus = max(5, min(20, int(round(zero_step_timeout_rate * 20))))
        return min(40, base_signal + zero_step_bonus)
    if normalized == "break retry churn":
        loop_tasks = project_loop_effort_task_count
        extra_attempts = project_loop_effort_extra_step_attempts
        return min(15, (loop_tasks // 12) + (extra_attempts // 35))
    if normalized == "improve retry failure classification coverage":
        coverage_gap_points = max(
            0,
            int(round((RETRY_CLASSIFICATION_COVERAGE_THRESHOLD - retry_classification_coverage) * 100)),
        )
        base_signal = min(15, (retry_total_count // 20) + (coverage_gap_points // 5))
        # When retry classification falls below half the target coverage with a large
        # enough sample, prioritize restoring learning visibility before broader retry tuning.
        if (
            retry_total_count >= RETRY_CLASSIFICATION_CRITICAL_MIN_SAMPLE_SIZE
            and retry_classification_coverage < RETRY_CLASSIFICATION_CRITICAL_COVERAGE_THRESHOLD
        ):
            critical_gap_points = max(
                0,
                int(round((RETRY_CLASSIFICATION_CRITICAL_COVERAGE_THRESHOLD - retry_classification_coverage) * 100)),
            )
            critical_sample_points = min(10, retry_total_count // 10)
            return max(base_signal, min(40, 30 + critical_gap_points + critical_sample_points))
        return base_signal
    if normalized == "improve retry success rate":
        retry_gap_points = max(0, int(round((first_pass - success_rate) * 100)))
        return min(10, retry_gap_points // 6)
    if normalized == "improve first-pass success rate":
        first_pass_gap_points = max(0, int(round((0.50 - first_pass) * 100)))
        return min(10, first_pass_gap_points // 4)
    if normalized == "drain approval backlog":
        if pending_approval_pipeline_blocker_active():
            return 140
        if approved_backlog_starvation_active() or (
            backlog > BACKLOG_DRAIN_SIGNAL_THRESHOLD
            and project_pending_approval_blocked_detected
        ):
            return 120
        return min(10, max(0, backlog - BACKLOG_OVERLOAD_THRESHOLD))
    return 0


def improvement_priority_points(priority: Any) -> int:
    band = improvement_priority_band(priority)
    if band >= 3:
        return 15
    if band == 2:
        return 10
    if band == 1:
        return 5
    return 0


def improvement_priority_band(priority: Any) -> int:
    normalized = normalize_text(priority)
    if normalized == "critical":
        return 3
    if normalized == "high":
        return 2
    if normalized == "medium":
        return 1
    return 0


def improvement_outcome_penalty(title: str) -> int:
    title_key = improvement_title_key(title)
    if not title_key:
        return 0
    family_state = family_outcomes.get(title_key, {})
    recent_failures = max(safe_int(family_state.get("recent_failures_since_latest_success")), 0)
    recent_self_improve_failures = max(safe_int(family_state.get("recent_self_improve_failures")), 0)
    if recent_failures <= 0 and recent_self_improve_failures <= 0:
        return 0
    return (recent_failures * 25) + (recent_self_improve_failures * 10)


def rank_improvements(improvements_list: list[dict[str, Any]]) -> list[dict[str, Any]]:
    def sort_key(item: dict[str, Any]) -> tuple[int, int, int, int, int, str]:
        title = str(item.get("title") or "").strip()
        static_priority = overload_candidate_static_priority(title)
        signal_priority = overload_candidate_signal_priority(title)
        priority_points = improvement_priority_points(item.get("priority"))
        outcome_penalty = improvement_outcome_penalty(title)
        total_score = static_priority + signal_priority + priority_points - outcome_penalty
        return (
            -total_score,
            outcome_penalty,
            -signal_priority,
            -static_priority,
            -priority_points,
            title,
        )

    return sorted(improvements_list, key=sort_key)


def inventory_slug(value: Any) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", normalize_text(value).lower()).strip("-")
    return slug[:64] or "current-decision-path"


def build_title_family_cooldown_inventory_fallback(
    source_item: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if not isinstance(source_item, dict):
        return None

    source_title = normalize_text(source_item.get("title") or "")
    if not source_title:
        return None

    artifact_path = f"codex-memory/self-improve-inventory-{inventory_slug(source_title)}.md"
    target_files = [
        str(path).strip()
        for path in (source_item.get("target_files") if isinstance(source_item.get("target_files"), list) else [])
        if str(path).strip()
    ][:3]
    primary_target_file = target_files[0] if target_files else ""
    narrowed_target_files = [primary_target_file] if primary_target_file else []
    blocked_reason = blocked_title_family_reasons.get(improvement_title_key(source_title), "title_family_cooldown")
    source_priority = normalize_text(source_item.get("priority")).lower() or "medium"
    scope_hint = (
        f"starting with {primary_target_file}"
        if primary_target_file
        else "starting with the strongest verified decision path in the repository"
    )

    return {
        "title": f"Inventory current decision path for {source_title}",
        "category": "learning",
        "priority": source_priority,
        "reason": (
            f"Direct retries for {source_title} are currently paused by {blocked_reason} while the live weakness "
            "signal is still active. Reuse the bounded inventory pattern to capture the exact files, functions, "
            "and decision points before another implementation retry."
        ),
        "target_files": narrowed_target_files,
        "strategy_template": "bounded_learning_inventory",
        "impact": max(5, safe_int(source_item.get("impact"), 6) - 1),
        "effort": 2,
        "confidence": 0.82,
        "hypothesis": (
            "If the next run verifies one primary edit site behind the blocked improvement, the later retry can "
            "target one concrete change instead of repeating another broad multi-file inspection during cooldown."
        ),
        "experiment": (
            f"Inspect the current code path most directly related to {source_title}, {scope_hint}, then write one "
            f"compact inventory artifact at {artifact_path}. Expected: identify one existing file and one concrete "
            "edit location before making changes. Record secondary files, functions, metrics, or gates only when "
            "they directly feed that primary edit site. Do not implement code changes in the same run."
        ),
        "success_criteria": [
            f"A single artifact at {artifact_path} captures the current decision path behind {source_title}.",
            "The inventory names one primary existing file and one concrete edit location before listing any secondary dependencies.",
            "The run does not change runtime behavior, queue semantics, or unrelated source files beyond the inventory artifact and lifecycle metadata.",
        ],
        "rollback": f"Delete {artifact_path} and return to the current direct-retry-only cooldown behavior.",
    }


def blocked_improvement_reason(source_item: dict[str, Any] | None) -> str:
    if not isinstance(source_item, dict):
        return ""

    source_title = normalize_text(source_item.get("title") or "")
    title_key = improvement_title_key(source_title)
    identity_key = project_title_identity_key(project_name, source_title)
    if not title_key or not identity_key:
        return ""

    if identity_key in zombie_blocklist:
        return "zombie_guard"
    if identity_key in non_retryable_blocklist:
        return "non_retryable_guard"
    if title_key in blocked_title_families:
        return blocked_title_family_reasons.get(title_key, "title_family_cooldown")
    return ""


def build_viable_inventory_fallback(
    source_item: dict[str, Any] | None,
) -> dict[str, Any] | None:
    fallback = build_title_family_cooldown_inventory_fallback(source_item)
    if not isinstance(fallback, dict):
        return None

    fallback_title = normalize_text(fallback.get("title") or "")
    fallback_title_key = improvement_title_key(fallback_title)
    fallback_identity_key = project_title_identity_key(project_name, fallback_title)
    if not fallback_title_key or not fallback_identity_key:
        return None
    if fallback_identity_key in zombie_blocklist:
        return None
    if fallback_identity_key in non_retryable_blocklist:
        return None
    if fallback_title_key in blocked_title_families:
        return None
    return fallback


def select_inventory_fallback_source(
    ranked_items: list[dict[str, Any]],
) -> dict[str, Any] | None:
    blocked_ranked_items = [
        item
        for item in ranked_items
        if blocked_improvement_reason(item) and build_viable_inventory_fallback(item) is not None
    ]
    if not blocked_ranked_items:
        return None

    preferred_title_keys: list[str] = []
    if project_pipeline_stale:
        preferred_title_keys.append("recover stale pipeline")
    if critical_zero_step_timeout_detected:
        preferred_title_keys.extend(["cap pre-step planning budget", "reduce timeout rate"])
    if project_retry_churn_detected:
        preferred_title_keys.append("break retry churn")
    if success_rate < 0.25:
        if first_pass > 0.5:
            preferred_title_keys.extend([
                "improve retry failure classification coverage",
                "improve retry success rate",
            ])
        else:
            preferred_title_keys.append("improve first-pass success rate")
    if registry_pressure_detected:
        preferred_title_keys.append("reduce registry pressure")
    if backlog > BACKLOG_DRAIN_SIGNAL_THRESHOLD and approval_backlog_signal_active:
        preferred_title_keys.append("drain approval backlog")

    for preferred_key in preferred_title_keys:
        for item in blocked_ranked_items:
            if improvement_title_key(item.get("title") or "") == preferred_key:
                return item

    return blocked_ranked_items[0]


def select_external_project_seed_fallback() -> dict[str, Any] | None:
    if not enforce_workspace_target_validation:
        return None

    seed_candidates = rank_improvements(external_project_spec_milestone_improvements())
    for item in seed_candidates:
        source_title = normalize_text(item.get("title") or "")
        title_key = improvement_title_key(source_title)
        identity_key = project_title_identity_key(project_name, source_title)
        if not title_key or not identity_key:
            continue
        if identity_key in zombie_blocklist:
            continue
        if identity_key in non_retryable_blocklist:
            continue
        if title_key in blocked_title_families:
            continue
        return item

    return None

# Generate improvement suggestions
improvements: list[dict[str, Any]] = []
suppressed_detected_count = 0
suppressed_analysis_reasons: list[str] = []
now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# 1. Success rate improvement
success_rate = project_success_rate
first_pass = project_first_pass_success_rate
retry_classification_coverage = project_retry_classification_coverage
retry_classified_count = project_retry_classified_count
retry_total_count = project_retry_total_count
diagnostic_coverage = project_diagnostic_coverage
recent_diagnostic_coverage = project_recent_diagnostic_coverage
failures_with_diagnostic = project_failures_with_diagnostic
total_failure_records = project_total_failure_records
retry_classification_gap_detected = (
    retry_total_count >= RETRY_CLASSIFICATION_MIN_SAMPLE_SIZE
    and retry_classification_coverage < RETRY_CLASSIFICATION_COVERAGE_THRESHOLD
)
retry_unknown_context_summary = summarize_unknown_retry_task_context()
if success_rate < 0.25:
    if first_pass > 0.5:
        if retry_classification_gap_detected:
            retry_classification_reason = (
                f"Only {retry_classification_coverage:.0%} of retry failures are classified "
                f"({retry_classified_count}/{retry_total_count}); broaden deterministic failure capture "
                "before tuning broader retry behavior by enriching reviewer/evaluator context in orchestrator.sh "
                "and extending classify_failure patterns."
            )
            retry_classification_target_files = merge_target_files(
                retry_unknown_context_summary.get("affected_files") or [],
                ["agents/orchestrator.sh", "scripts/lib.sh"],
            )
            retry_context_parts: list[str] = []
            retry_context_objective = str(retry_unknown_context_summary.get("objective") or "").strip()
            retry_context_hint = str(retry_unknown_context_summary.get("context_hint") or "").strip()
            if retry_context_objective:
                retry_context_parts.append(
                    f"Recent unknown retries cluster around {retry_context_objective}."
                )
            elif retry_context_hint:
                retry_context_parts.append(
                    f"Recent unknown retries cluster around {retry_context_hint}."
                )
            if retry_unknown_context_summary.get("affected_files"):
                retry_context_parts.append(
                    "Start with the current task-context files: "
                    + ", ".join(retry_classification_target_files)
                    + "."
                )
            if retry_context_parts:
                retry_classification_reason += " " + " ".join(retry_context_parts)
            improvements.append({
                "title": "Improve retry failure classification coverage",
                "category": "learning",
                "reason": retry_classification_reason,
                "priority": "high",
                "target_files": retry_classification_target_files,
            })
        else:
            # First-pass is OK but retries fail → fix retry logic
            improvements.append({
                "title": "Improve retry success rate",
                "category": "stability",
                "reason": f"Retry attempts are failing {1-success_rate/max(first_pass,0.01):.0%} of the time "
                          f"({success_rate:.0%} overall vs {first_pass:.0%} first-pass). "
                          "Analyze recent retry failures and improve the failure context enrichment in orchestrator.sh.",
                "priority": "high",
                "target_files": ["agents/orchestrator.sh", "scripts/lib.sh"],
            })
    else:
        # First-pass is also bad → fix planning/context
        improvements.append({
            "title": "Improve first-pass success rate",
            "category": "stability",
            "reason": f"Tasks fail even on first attempt ({first_pass:.0%} first-pass success). Improve planner context quality, "
                      "reduce prompt size, and ensure task descriptions are specific enough.",
            "priority": "critical",
            "target_files": ["agents/planner.sh", "agents/coder.sh"],
        })

# 2. Timeout reduction
timeout_rate = project_timeout_rate
zero_step_timeout_rate = project_zero_step_timeout_rate
critical_zero_step_timeout_detected = zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_ALERT_THRESHOLD
timeout_remediation_superseded = False
timeout_diagnostic_gap_detected = (
    critical_zero_step_timeout_detected
    and diagnostic_coverage >= 0
    and total_failure_records >= DIAGNOSTIC_COVERAGE_MIN_SAMPLE_SIZE
    and diagnostic_coverage < DIAGNOSTIC_COVERAGE_THRESHOLD
)
if timeout_rate > 0.08:
    if timeout_diagnostic_gap_detected:
        diagnostic_reason = (
            f"Only {diagnostic_coverage:.0%} of failure records carry diagnostic context "
            f"({failures_with_diagnostic}/{total_failure_records}) while {zero_step_timeout_rate:.0%} "
            "of timeout failures ended before any step executed. Tighten deterministic failure capture in the "
            "orchestrator and queue worker before another generic timeout fix so the next timeout remediation "
            "uses concrete failed-step evidence."
        )
        if recent_diagnostic_coverage >= 0:
            diagnostic_reason += f" Recent diagnostic coverage is {recent_diagnostic_coverage:.0%}."
        improvements.append({
            "title": "Improve timeout diagnostic coverage",
            "category": "learning",
            "reason": diagnostic_reason,
            "priority": (
                "critical"
                if zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD
                and diagnostic_coverage < DIAGNOSTIC_COVERAGE_CRITICAL_THRESHOLD
                else "high"
            ),
            "target_files": ["agents/orchestrator.sh", "scripts/lib.sh", "scripts/queue-worker.sh"],
        })
    timeout_patterns = timeout_prone_tasks()
    timeout_reason = (
        f"Tasks are timing out at {timeout_rate:.0%}; target under 5%. "
        f"Common timeout keywords: {', '.join(timeout_patterns[:3])}. "
        "Consider: reducing context size, increasing timeout for complex tasks, "
        "or breaking large tasks into smaller steps."
    )
    timeout_target_files = ["scripts/lib.sh", "scripts/queue-worker.sh"]
    if critical_zero_step_timeout_detected:
        timeout_reason += (
            f" {zero_step_timeout_rate:.0%} of timeout failures ended before any step executed, "
            "which points to planning/setup consuming the budget. Prioritize the known 60s planning cap "
            "and fail-fast orchestration before spending more retries."
        )
        timeout_target_files = ["agents/planner.sh", "agents/orchestrator.sh", "scripts/queue-worker.sh"]
    improvements.append({
        "title": "Reduce timeout rate",
        "category": "performance",
        "reason": timeout_reason,
        "priority": "high",
        "target_files": timeout_target_files,
    })

# 3. Registry pressure
local_registry_bytes = 0
registry_pressure_scope = "none"
dominant_registry_source: dict[str, Any] = {}
local_registry_pressure_source: dict[str, Any] = {}
registry_bytes = max(
    safe_int(
        metrics.get("task_registry_payload_bytes")
        if metrics.get("task_registry_payload_bytes") is not None
        else metrics.get("task_registry_pressure_bytes"),
        0,
    ),
    0,
)
registry_pressure_detected = (
    metrics.get("task_registry_pressure_detected") is True
    or registry_bytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
)
registry_pressure_family_override_active = False
if registry_pressure_detected:
    dominant_registry_source = dominant_registry_pressure_source(metrics)
    local_registry_source = registry_pressure_source_for_project(metrics, project_name)
    local_registry_pressure_source = dict(local_registry_source) if isinstance(local_registry_source, dict) else {}
    project_key = normalize_project_key(project_name)
    local_registry_bytes = max(safe_int(local_registry_source.get("payload_bytes")), 0)
    if local_registry_bytes <= 0:
        try:
            local_registry_bytes = max(int(registry_path.stat().st_size), 0)
        except OSError:
            local_registry_bytes = 0
    registry_reason = (
        f"Task registry exceeds shared pressure threshold ({registry_bytes // 1024}KB >= "
        f"{TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD // 1024}KB). "
        if registry_bytes > 0
        else "Shared metrics mark task-registry pressure as detected. "
    )
    if dominant_registry_source:
        dominant_project = str(dominant_registry_source.get("project") or "codex-agent-system").strip() or "codex-agent-system"
        dominant_file = str(dominant_registry_source.get("file") or "").strip()
        dominant_bytes = max(safe_int(dominant_registry_source.get("payload_bytes")), 0)
        registry_reason += (
            f"Dominant source: {dominant_project} registry ({dominant_bytes // 1024}KB"
            + (f" at {dominant_file}" if dominant_file else "")
            + "). "
        )
        dominant_project_key = normalize_project_key(dominant_project)
    else:
        dominant_project_key = ""

    external_registry_pressure = (
        dominant_project_key
        and dominant_project_key != project_key
        and local_registry_bytes < TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
    )
    if external_registry_pressure:
        registry_pressure_scope = "cross_project"
    else:
        registry_pressure_scope = "local"
    emergency_registry_bytes = local_registry_bytes
    if not dominant_project_key:
        emergency_registry_bytes = max(emergency_registry_bytes, registry_bytes)
    elif dominant_project_key == project_key:
        emergency_registry_bytes = max(emergency_registry_bytes, registry_bytes)
    registry_pressure_family_override_active = (
        not external_registry_pressure
        and emergency_registry_bytes >= EXTREME_TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
    )
    if external_registry_pressure:
        suppressed_detected_count += 1
        suppressed_analysis_reasons.append("cross_project_registry_pressure")
    else:
        improvements.append({
            "title": "Reduce registry pressure",
            "category": "performance",
            "reason": registry_reason
                      + "Run compact-registry.sh more aggressively, archive old tasks, "
                      "and consider lazy-loading in dashboard reads.",
            "priority": "medium",
            "target_files": ["scripts/compact-registry.sh", "codex-dashboard/server.js"],
        })

# 4. Retry churn
if project_retry_churn_detected and project_retry_churn_actionable:
    loop_tasks = project_loop_effort_task_count
    extra_attempts = project_loop_effort_extra_step_attempts
    improvements.append({
        "title": "Break retry churn",
        "category": "stability",
        "reason": f"{loop_tasks} tasks consumed {extra_attempts} extra step attempts without resolution. "
                  "Implement exponential backoff on retries and skip tasks that fail with identical errors.",
        "priority": "high",
        "target_files": ["agents/orchestrator.sh"],
    })

# 5. Strategy saturation
if project_strategy_saturation_detected:
    sat_tasks = project_saturated_failed_tasks
    improvements.append({
        "title": "Reduce strategy saturation",
        "category": "stability",
        "reason": f"Strategy engine has {sat_tasks} saturated failed tasks and is generating work faster than it completes it. "
                  "Increase ENTERPRISE_ACTIONABLE_TARGET, add generation cooldown, "
                  "and prune duplicate/similar task proposals.",
        "priority": "medium",
        "target_files": ["agents/strategy.sh", "scripts/strategy-loop.sh"],
    })

pending_approval_pipeline_blocked = pending_approval_pipeline_blocker_active()

# 6. Pipeline recovery
if pipeline_recovery_retry_eligible and not pending_approval_pipeline_blocked:
    pipeline_reason = (
        "Project-local task execution appears stalled with no fresh completions for over 6 hours. "
    )
    if project_pipeline_stale_since:
        pipeline_reason += f"Latest completion signal was {project_pipeline_stale_since}. "
    pipeline_reason += (
        "Generate one bounded recovery task that refreshes queue/worker health and clears any blocking "
        "gates before seeding more work."
    )
    improvements.append({
        "title": "Recover stale pipeline",
        "category": "stability",
        "reason": pipeline_reason,
        "priority": "critical",
        "target_files": ["scripts/multi-queue.sh", "scripts/queue-worker.sh", "agents/strategy.sh"],
    })

# 7. Repeated failure patterns
repeated = repeated_failure_patterns()
for pattern in repeated[:2]:
    improvements.append({
        "title": f"Fix repeated failure: {pattern['error'][:60]}",
        "category": "code_quality",
        "reason": f"Error occurred {pattern['count']} times across tasks {', '.join(pattern['task_ids'])}. "
                  "This is a systematic issue that should be fixed at the root cause.",
        "priority": "medium",
        "target_files": [],
    })

# 8. Approved backlog
backlog = pending_approved_backlog()
approval_backlog_signal_active = (
    approved_backlog_starvation_active()
    or project_pending_approval_blocked_detected
)
if (
    (backlog > BACKLOG_DRAIN_SIGNAL_THRESHOLD and approval_backlog_signal_active)
    or pending_approval_pipeline_blocked
):
    approval_backlog = approval_backlog_snapshot()
    approval_backlog_parts = []
    if approval_backlog["approved"] > 0:
        approval_backlog_parts.append(f"{approval_backlog['approved']} approved")
    if approval_backlog["pending_approval"] > 0:
        approval_backlog_parts.append(f"{approval_backlog['pending_approval']} pending approval")
    approval_backlog_detail = ", ".join(approval_backlog_parts) or f"{approval_backlog['total']} active approvals"
    approval_backlog_reason = (
        f"{approval_backlog['total']} active approvals are waiting ({approval_backlog_detail}). "
        "Review pending approvals, pause strategy generation if needed, and increase queue throughput once items are approved."
    )
    if pending_approval_pipeline_blocked and backlog <= BACKLOG_DRAIN_SIGNAL_THRESHOLD:
        approval_backlog_reason = (
            f"{approval_backlog['total']} active approvals are waiting ({approval_backlog_detail}). "
            "Project-local pipeline is stale and pending approvals are blocking execution while the queue is idle. "
            "Review pending approvals before seeding more work."
        )
    improvements.append({
        "title": APPROVAL_BACKLOG_IMPROVEMENT_TITLE,
        "category": "performance",
        "reason": approval_backlog_reason,
        "priority": "low",
        "target_files": ["scripts/multi-queue.sh"],
    })

# 9. External signal staleness
signal_status = metrics.get("external_signal_status", "unknown")
if signal_status != "fresh":
    improvements.append({
        "title": "Refresh stale external signals",
        "category": "learning",
        "reason": "External signals are stale. Refresh to incorporate latest releases and research.",
        "priority": "low",
        "target_files": ["codex-learning/external-signal-sources.json"],
    })

external_project_gap_improvements: list[dict[str, Any]] = []
if enforce_workspace_target_validation:
    external_project_gap_improvements = external_project_contract_gap_improvements()
    improvements.extend(external_project_gap_improvements)

external_internal_filtered_count = 0
if enforce_workspace_target_validation:
    filtered_external_improvements: list[dict[str, Any]] = []
    for item in improvements:
        if (
            external_project_internal_improvement_title(item.get("title") or "")
            and (
                external_project_gap_improvements
                or not external_project_has_history_grounding(item.get("title") or "")
            )
        ):
            external_internal_filtered_count += 1
            continue
        filtered_external_improvements.append(item)
    improvements = filtered_external_improvements
    if external_internal_filtered_count > 0:
        suppressed_detected_count += external_internal_filtered_count
        suppressed_analysis_reasons.append("external_control_plane_task")

# Deduplicate against active title families, but let older terminal attempts resurface
# after a bounded cooldown so persistent weaknesses can be revisited deliberately.
# If a family already failed repeatedly without a newer success, treat it as saturated
# and keep it out of circulation longer so future task selection reflects the weak outcome.
now_dt = datetime.now(timezone.utc)
family_events: dict[str, list[dict[str, Any]]] = {}
for task_index, task in enumerate(tasks):
    title_key = improvement_title_key(task.get("title") or task.get("execution_task") or "")
    if not title_key:
        continue

    task_status = normalize_text(task.get("status"))
    candidate_updated_text = str(task.get("updated_at") or task.get("created_at") or "").strip()
    family_events.setdefault(title_key, []).append(
        {
            "status": task_status,
            "terminal_bucket": task_family_terminal_bucket(task),
            "updated_at": parse_iso8601(candidate_updated_text),
            "position": task_index,
            "finalize_only_inventory_failure": task_is_finalize_only_inventory_failure(task),
            "source": normalize_text(
                (task.get("task_intent") or {}).get("source")
                if isinstance(task.get("task_intent"), dict)
                else task.get("source_task_id")
            ),
        }
    )

blocked_title_families: set[str] = set()
blocked_title_family_reasons: dict[str, str] = {}
family_outcomes: dict[str, dict[str, Any]] = {}
for title_key, events in family_events.items():
    sorted_events = sorted(
        events,
        key=lambda event: (
            event.get("updated_at") is None,
            event.get("updated_at") or datetime.min.replace(tzinfo=timezone.utc),
            int(event.get("position") or 0),
        ),
    )
    title_state = sorted_events[-1]
    status = str(title_state.get("status") or "")
    terminal_bucket = str(title_state.get("terminal_bucket") or "other")
    recent_failures_since_latest_success = 0
    recent_self_improve_failures = 0
    recent_failure_seen = False
    for event in reversed(sorted_events):
        event_bucket = str(event.get("terminal_bucket") or "other")
        event_updated_at = event.get("updated_at")
        if event_bucket in {"success", "neutral"}:
            break
        if event_bucket != "failure" or event_updated_at is None:
            continue
        elapsed_seconds = (now_dt - event_updated_at).total_seconds()
        if elapsed_seconds > OVERLOAD_FAMILY_OUTCOME_LOOKBACK_SECONDS:
            continue
        recent_failures_since_latest_success += 1
        if str(event.get("source") or "") == "self-improve":
            recent_self_improve_failures += 1
        recent_failure_seen = True

    updated_at = title_state.get("updated_at")
    family_outcomes[title_key] = {
        "recent_failures_since_latest_success": recent_failures_since_latest_success,
        "recent_self_improve_failures": recent_self_improve_failures,
        "recent_failure_seen": recent_failure_seen,
        "latest_updated_at": updated_at,
    }
    if terminal_bucket == "active":
        blocked_title_families.add(title_key)
        blocked_title_family_reasons[title_key] = "active_family"
        continue
    if terminal_bucket == "neutral":
        continue

    if updated_at is None:
        blocked_title_families.add(title_key)
        blocked_title_family_reasons[title_key] = "missing_timestamp"
        continue

    cooldown_seconds = TITLE_FAMILY_RETRY_COOLDOWN_SECONDS
    cooldown_reason = "recent_terminal_cooldown"
    if terminal_bucket == "failure":
        if bool(title_state.get("finalize_only_inventory_failure")):
            # A bounded inventory task that already finished all planned steps
            # but failed only during finalize/commit should not hold its own
            # title family in cooldown after the runtime helper is repaired.
            continue
        terminal_failure_streak = 0
        for event in sorted_events:
            event_bucket = str(event.get("terminal_bucket") or "other")
            if event_bucket in {"success", "neutral"}:
                terminal_failure_streak = 0
            elif event_bucket == "failure":
                terminal_failure_streak += 1

        latest_source = str(title_state.get("source") or "")
        if latest_source == "self-improve":
            cooldown_seconds = SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS
            cooldown_reason = "recent_self_improve_failure_cooldown"
        if status == "shelved" or terminal_failure_streak >= TITLE_FAMILY_FAILURE_STREAK_THRESHOLD:
            cooldown_seconds = TITLE_FAMILY_SATURATION_COOLDOWN_SECONDS
            cooldown_reason = "saturated_family_cooldown"
    elif terminal_bucket == "success":
        cooldown_reason = "recent_success_cooldown"
    else:
        continue

    elapsed_seconds = (now_dt - updated_at).total_seconds()
    if elapsed_seconds < cooldown_seconds:
        blocked_title_families.add(title_key)
        blocked_title_family_reasons[title_key] = cooldown_reason

if registry_pressure_family_override_active:
    registry_pressure_title_key = improvement_title_key("Reduce registry pressure")
    override_reason = blocked_title_family_reasons.get(registry_pressure_title_key, "")
    if override_reason in {
        "recent_terminal_cooldown",
        "recent_self_improve_failure_cooldown",
        "saturated_family_cooldown",
    }:
        blocked_title_families.discard(registry_pressure_title_key)
        blocked_title_family_reasons.pop(registry_pressure_title_key, None)

if pipeline_recovery_retry_eligible:
    pipeline_title_key = improvement_title_key("Recover stale pipeline")
    pipeline_override_reason = blocked_title_family_reasons.get(pipeline_title_key, "")
    pipeline_updated_at = family_outcomes.get(pipeline_title_key, {}).get("latest_updated_at")
    if (
        pipeline_override_reason in {
            "recent_terminal_cooldown",
            "recent_self_improve_failure_cooldown",
            "saturated_family_cooldown",
        }
        and pipeline_updated_at is not None
        and (now_dt - pipeline_updated_at).total_seconds() >= PIPELINE_STALE_RETRY_SECONDS
    ):
        # Persistent pipeline stalls can recover as queue/runtime state changes.
        # Keep the bounded recovery task eligible after its shorter retry window
        # even when another emergency, such as zero-step timeout pressure, is active.
        blocked_title_families.discard(pipeline_title_key)
        blocked_title_family_reasons.pop(pipeline_title_key, None)

timeout_family_pre_override_reason = ""
timeout_identity_pre_override_reason = ""
if zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD:
    timeout_title_key = improvement_title_key("Reduce timeout rate")
    timeout_identity_key = project_title_identity_key(project_name, "Reduce timeout rate")
    planning_budget_title = "Cap pre-step planning budget"
    planning_budget_title_key = improvement_title_key("Cap pre-step planning budget")
    planning_budget_identity_key = project_title_identity_key(project_name, planning_budget_title)
    planning_budget_override_reason = blocked_title_family_reasons.get(planning_budget_title_key, "")
    planning_budget_updated_at = family_outcomes.get(planning_budget_title_key, {}).get("latest_updated_at")
    planning_budget_elapsed_seconds = (
        (now_dt - planning_budget_updated_at).total_seconds()
        if planning_budget_updated_at is not None
        else None
    )
    planning_budget_family_saturated = (
        planning_budget_override_reason == "saturated_family_cooldown"
    )
    planning_budget_identity_pre_override_reason = non_retryable_blocklist_reasons.get(
        planning_budget_identity_key, ""
    )
    timeout_family_pre_override_reason = blocked_title_family_reasons.get(timeout_title_key, "")
    timeout_identity_pre_override_reason = non_retryable_blocklist_reasons.get(timeout_identity_key, "")
    override_reason = blocked_title_family_reasons.get(timeout_title_key, "")
    if override_reason in {
        "recent_terminal_cooldown",
        "recent_self_improve_failure_cooldown",
        "saturated_family_cooldown",
    }:
        blocked_title_families.discard(timeout_title_key)
        blocked_title_family_reasons.pop(timeout_title_key, None)
    if (
        planning_budget_override_reason in {
            "recent_terminal_cooldown",
            "recent_self_improve_failure_cooldown",
        }
        and planning_budget_updated_at is not None
        and planning_budget_elapsed_seconds is not None
        and planning_budget_elapsed_seconds >= PLANNING_BUDGET_RETRY_SECONDS
    ):
        blocked_title_families.discard(planning_budget_title_key)
        blocked_title_family_reasons.pop(planning_budget_title_key, None)
    if (
        planning_budget_identity_pre_override_reason == "timeout"
        and not planning_budget_family_saturated
        and planning_budget_elapsed_seconds is not None
        and planning_budget_elapsed_seconds >= PLANNING_BUDGET_RETRY_SECONDS
    ):
        non_retryable_blocklist.discard(planning_budget_identity_key)
        non_retryable_blocklist_reasons.pop(planning_budget_identity_key, None)
    # Preserve timeout remediation during planning-budget emergencies even if
    # the same family previously failed with timeout; otherwise the emergency
    # overload ranking can select the timeout fix and the final filter drops it.
    if non_retryable_blocklist_reasons.get(timeout_identity_key) == "timeout":
        non_retryable_blocklist.discard(timeout_identity_key)
        non_retryable_blocklist_reasons.pop(timeout_identity_key, None)
    # When the generic timeout remediation is already awaiting approval, keep the
    # emergency moving with a narrower successor based on the learned 60s planning cap.
    if (
        timeout_rate > 0.08
        and blocked_title_family_reasons.get(timeout_title_key) == "active_family"
        and not planning_budget_family_saturated
    ):
        planning_budget_title = "Cap pre-step planning budget"
        planning_budget_key = improvement_title_key(planning_budget_title)
        if all(
            improvement_title_key(item.get("title") or "") != planning_budget_key
            for item in improvements
        ):
            improvements.append({
                "title": planning_budget_title,
                "category": "stability",
                "reason": (
                    f"{zero_step_timeout_rate:.0%} of timeout failures ended before any step executed, "
                    "and the generic timeout remediation is already active. Apply the known 60s planning cap "
                    "and fail-fast handoff in the planner/orchestrator path so the emergency can progress with "
                    "a bounded successor instead of stalling behind the active family."
                ),
                "priority": "critical",
                "target_files": ["agents/planner.sh", "agents/orchestrator.sh", "scripts/queue-worker.sh"],
            })
            timeout_remediation_superseded = True
    elif (
        timeout_rate > 0.08
        and (
            timeout_family_pre_override_reason in {
                "recent_terminal_cooldown",
                "recent_self_improve_failure_cooldown",
                "saturated_family_cooldown",
            }
            or timeout_identity_pre_override_reason == "timeout"
        )
        and not planning_budget_family_saturated
    ):
        planning_budget_title = "Cap pre-step planning budget"
        planning_budget_key = improvement_title_key(planning_budget_title)
        if all(
            improvement_title_key(item.get("title") or "") != planning_budget_key
            for item in improvements
        ):
            improvements.append({
                "title": planning_budget_title,
                "category": "stability",
                "reason": (
                    f"{zero_step_timeout_rate:.0%} of timeout failures ended before any step executed, "
                    "and prior timeout-family outcomes already blocked or exhausted the generic timeout remediation. "
                    "Promote the learned 60s planning cap and fail-fast handoff as the narrower successor so "
                    "future retries spend budget on execution instead of another planning-only timeout."
                ),
                "priority": "critical",
                "target_files": ["agents/planner.sh", "agents/orchestrator.sh", "scripts/queue-worker.sh"],
            })
            timeout_remediation_superseded = True
    # Once the narrower planning-budget remediation is already active, or it
    # just completed successfully, do not regenerate the broader timeout task
    # until the family cooldown expires and metrics have a chance to refresh.
    if blocked_title_family_reasons.get(planning_budget_title_key) in {
        "active_family",
        "recent_success_cooldown",
    }:
        timeout_remediation_superseded = True

if timeout_remediation_superseded:
    generic_timeout_title_key = improvement_title_key("Reduce timeout rate")
    improvements = [
        item
        for item in improvements
        if improvement_title_key(item.get("title") or "") != generic_timeout_title_key
    ]

detected_improvements = list(improvements)

backlog_gate_active = (
    backlog >= BACKLOG_OVERLOAD_THRESHOLD
    and (
        registry_pressure_detected
        or metrics.get("strategy_saturation_detected") is True
        or success_rate < BACKLOG_OVERLOAD_SUCCESS_RATE_THRESHOLD
    )
)
approved_backlog_starvation = approved_backlog_starvation_active()
backlog_filtered_count = 0
overload_gate_summary: dict[str, Any] = {
    "active": False,
    "preserved_title": "",
    "preserved_reason": "inactive",
    "candidate_count": 0,
    "blocked_candidate_count": 0,
    "candidates": [],
}
if backlog_gate_active:
    overload_candidate_titles = []
    if project_pipeline_stale:
        overload_candidate_titles.append("Recover stale pipeline")
    if timeout_diagnostic_gap_detected:
        overload_candidate_titles.append("Improve timeout diagnostic coverage")
    if critical_zero_step_timeout_detected:
        overload_candidate_titles.append("Cap pre-step planning budget")
    if timeout_rate > 0.08:
        overload_candidate_titles.append("Reduce timeout rate")
    if metrics.get("retry_churn_detected"):
        overload_candidate_titles.append("Break retry churn")
    if success_rate < 0.25:
        if first_pass > 0.5:
            if retry_classification_gap_detected:
                overload_candidate_titles.append("Improve retry failure classification coverage")
            else:
                overload_candidate_titles.append("Improve retry success rate")
        else:
            overload_candidate_titles.append("Improve first-pass success rate")
    overload_candidate_titles.append(APPROVAL_BACKLOG_IMPROVEMENT_TITLE)
    overload_candidate_titles = ordered_unique_titles(overload_candidate_titles)

    available_titles = {
        str(imp.get("title") or "").strip()
        for imp in improvements
        if str(imp.get("title") or "").strip()
    }
    pre_backlog_gate_count = len(improvements)
    preserved_title = ""
    preserved_reason = "fallback_backlog_drain"
    candidate_rankings: list[dict[str, Any]] = []
    for candidate_title in overload_candidate_titles:
        if candidate_title not in available_titles:
            continue
        title_key = improvement_title_key(candidate_title)
        family_state = family_outcomes.get(title_key, {})
        recent_failures = max(safe_int(family_state.get("recent_failures_since_latest_success")), 0)
        recent_self_improve_failures = max(safe_int(family_state.get("recent_self_improve_failures")), 0)
        signal_priority = overload_candidate_signal_priority(candidate_title)
        score = (
            overload_candidate_static_priority(candidate_title)
            + signal_priority
            - (recent_failures * 15)
            - (recent_self_improve_failures * 5)
        )
        blocked = title_key in blocked_title_families
        candidate_rankings.append(
            {
                "title": candidate_title,
                "blocked": blocked,
                "blocked_reason": blocked_title_family_reasons.get(title_key, "none") if blocked else "none",
                "score": score,
                "recent_failures_since_latest_success": recent_failures,
                "recent_self_improve_failures": recent_self_improve_failures,
                "static_priority": overload_candidate_static_priority(candidate_title),
                "signal_priority": signal_priority,
            }
        )

    if approved_backlog_starvation and APPROVAL_BACKLOG_IMPROVEMENT_TITLE in available_titles:
        preserved_title = APPROVAL_BACKLOG_IMPROVEMENT_TITLE
        preserved_reason = "approved_backlog_starvation"
    elif candidate_rankings:
        candidate_rankings.sort(
            key=lambda item: (
                1 if item.get("blocked") is not True else 0,
                safe_int(item.get("score")),
                -safe_int(item.get("recent_failures_since_latest_success")),
                -safe_int(item.get("recent_self_improve_failures")),
                safe_int(item.get("static_priority")),
                str(item.get("title") or ""),
            ),
            reverse=True,
        )
        preserved_title = str(candidate_rankings[0].get("title") or "")
        preserved_reason = (
            "highest_scored_candidate_blocked"
            if candidate_rankings[0].get("blocked") is True
            else "highest_unblocked_score"
        )
    if not preserved_title:
        preserved_title = APPROVAL_BACKLOG_IMPROVEMENT_TITLE
    for index, candidate in enumerate(candidate_rankings, start=1):
        candidate["rank"] = index
        candidate["selected"] = str(candidate.get("title") or "") == preserved_title
    overload_gate_summary = {
        "active": True,
        "preserved_title": preserved_title,
        "preserved_reason": preserved_reason,
        "candidate_count": len(candidate_rankings),
        "blocked_candidate_count": sum(1 for item in candidate_rankings if item.get("blocked") is True),
        "candidates": candidate_rankings,
    }
    improvements = [imp for imp in improvements if imp.get("title") == preserved_title]
    backlog_filtered_count = max(0, pre_backlog_gate_count - len(improvements))
filtered = []
zombie_filtered_count = 0
non_retryable_filtered_count = 0
title_family_filtered_count = 0
for imp in improvements:
    title_key = improvement_title_key(imp["title"])
    title_identity_key = project_title_identity_key(project_name, imp["title"])
    # Permanent zombie blocklist — never regenerate tasks that failed 5+ times
    if title_identity_key in zombie_blocklist:
        zombie_filtered_count += 1
        continue
    # Non-retryable failure blocklist — never retry timeout/missing_env tasks
    if title_identity_key in non_retryable_blocklist:
        non_retryable_filtered_count += 1
        continue
    if title_key in blocked_title_families:
        title_family_filtered_count += 1
        continue
    filtered.append(imp)

filtered = rank_improvements(filtered)

automation_memory_preference = automation_memory_preferred_title(
    recent_automation_memory_entries,
    [str(item.get("title") or "") for item in filtered],
)
automation_memory_preference_applied = False
if automation_memory_preference:
    filtered, automation_memory_preference_applied = prioritize_preferred_title(
        filtered,
        str(automation_memory_preference.get("title") or ""),
    )
project_active_self_improve_count = sum(
    1 for task in project_tasks if is_active_self_improve_project_task(task)
)
inventory_fallback_reason = ""

if (
    not filtered
    and project_active_self_improve_count == 0
    and enforce_workspace_target_validation
):
    external_seed_fallback = select_external_project_seed_fallback()
    if external_seed_fallback is not None:
        filtered = [external_seed_fallback]

if (
    not filtered
    and project_active_self_improve_count == 0
):
    blocked_inventory_source = select_inventory_fallback_source(rank_improvements(list(improvements)))
    blocked_inventory_fallback = build_viable_inventory_fallback(blocked_inventory_source)
    if blocked_inventory_fallback is not None:
        inventory_fallback_reason = blocked_improvement_reason(blocked_inventory_source)
        if inventory_fallback_reason not in {"zombie_guard", "non_retryable_guard"}:
            inventory_fallback_reason = "title_family_cooldown"
        filtered = [blocked_inventory_fallback]

dominant_gating_reason = "none"
detected_count = len(detected_improvements) + suppressed_detected_count
blocked_analysis_count = max(0, detected_count - len(filtered))
if not detected_improvements and suppressed_analysis_reasons:
    dominant_gating_reason = suppressed_analysis_reasons[0]
elif not detected_improvements:
    dominant_gating_reason = "no_detected_weakness"
elif backlog_filtered_count > 0:
    dominant_gating_reason = "backlog_overload"
elif inventory_fallback_reason:
    dominant_gating_reason = inventory_fallback_reason
elif not filtered and zombie_filtered_count > 0 and zombie_filtered_count >= max(
    title_family_filtered_count,
    non_retryable_filtered_count,
):
    dominant_gating_reason = "zombie_guard"
elif not filtered and non_retryable_filtered_count > 0 and non_retryable_filtered_count >= title_family_filtered_count:
    dominant_gating_reason = "non_retryable_guard"
elif title_family_filtered_count > 0:
    dominant_gating_reason = "title_family_cooldown"

# Output as JSON
result = {
    "status": "success",
    "message": f"Generated {len(filtered)} improvement suggestions",
    "data": {
        "improvements": filtered,
        "analysis": {
            "detected_count": detected_count,
            "generated_count": len(filtered),
            "blocked_analysis_count": blocked_analysis_count,
            "backlog_filtered_count": backlog_filtered_count,
            "title_family_filtered_count": title_family_filtered_count,
            "zombie_filtered_count": zombie_filtered_count,
            "non_retryable_filtered_count": non_retryable_filtered_count,
            "dominant_gating_reason": dominant_gating_reason,
            "suppressed_analysis_reasons": suppressed_analysis_reasons,
            "automation_memory_preference": {
                "title": str(automation_memory_preference.get("title") or ""),
                "reason": str(automation_memory_preference.get("reason") or "none"),
                "applied": automation_memory_preference_applied,
            },
            "overload_gate": overload_gate_summary,
        },
        "metrics_snapshot": {
            "success_rate": success_rate,
            "first_pass_success_rate": first_pass,
            "timeout_rate": timeout_rate,
            "retry_classification_coverage": retry_classification_coverage,
            "retry_classified_count": retry_classified_count,
            "retry_total_count": retry_total_count,
            "zero_step_timeout_rate": zero_step_timeout_rate,
            "diagnostic_coverage": diagnostic_coverage,
            "recent_diagnostic_coverage": recent_diagnostic_coverage,
            "failures_with_diagnostic": failures_with_diagnostic,
            "total_failure_records": total_failure_records,
            "pipeline_stale": project_pipeline_stale,
            "pipeline_stale_since": project_pipeline_stale_since,
            "registry_bytes": registry_bytes,
            "shared_registry_bytes": registry_bytes,
            "local_registry_bytes": local_registry_bytes,
            "registry_pressure_scope": registry_pressure_scope,
            "registry_pressure_dominant_source": dominant_registry_source,
            "registry_pressure_local_source": local_registry_pressure_source,
            "approved_tasks": project_approved_tasks,
            "pending_approval_tasks": project_pending_approval_tasks,
            "approved_backlog": backlog,
            "queue_starvation_detected": (
                approved_backlog_starvation
                or metrics.get("queue_starvation_detected", False) is True
            ),
            "queued_tasks": 0 if approved_backlog_starvation else max(safe_int(metrics.get("queued_tasks")), 0),
            "running_tasks": 0 if approved_backlog_starvation else max(safe_int(metrics.get("running_tasks")), 0),
            "backlog": backlog,
            "backlog_gate_active": backlog_gate_active,
            "total_tasks": project_total_tasks,
            "recent_success_rate": project_recent_success_rate,
            "improvement_detected": metrics.get("improvement_detected", False),
            "regression_detected": metrics.get("regression_detected", False),
            "external_signal_status": signal_status,
            "fresh_external_signal_count": max(safe_int(metrics.get("fresh_external_signal_count")), 0),
            "latest_external_signal_source": str(metrics.get("latest_external_signal_source") or ""),
        },
        "generated_at": now_iso,
    },
}

print(json.dumps(result, indent=2))
PYIMPROVE
}

write_self_improve_run_artifact() {
  local improvements_json="$1"
  local submit_result_json="${2:-}"
  local status_override="${3:-success}"
  local automation_id=""
  local automation_memory_file=""
  local automation_memory_source="none"
  local automation_memory_external_hydrated="false"
  local automation_memory_external_sync_pending="true"
  local metrics_input_status="${SELF_IMPROVE_METRICS_INPUT_STATUS:-unknown}"
  local metrics_input_reason="${SELF_IMPROVE_METRICS_INPUT_REASON:-not_checked}"
  local metrics_input_refresh_performed="${SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED:-false}"
  local metrics_input_missing_keys_json="${SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON:-[]}"

  local tmp_improvements
  local tmp_submit
  tmp_improvements="$(mktemp)"
  tmp_submit="$(mktemp)"
  printf '%s' "$improvements_json" > "$tmp_improvements"
  printf '%s' "$submit_result_json" > "$tmp_submit"

  ensure_project_state "$PROJECT_NAME" >/dev/null 2>&1 || true
  if [ -f "$SELF_IMPROVE_AUTOMATION_CONTEXT_FILE" ]; then
    local automation_context
    automation_context="$(python3 - "$SELF_IMPROVE_AUTOMATION_CONTEXT_FILE" <<'PY'
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    payload = {}

print(
    "\t".join(
        [
            str(payload.get("automation_id") or "").strip(),
            str(payload.get("memory_file") or "").strip(),
            str(payload.get("source") or "none").strip(),
            "true" if payload.get("external_hydrated") is True else "false",
            "true" if payload.get("external_sync_pending") is True else "false",
        ]
    )
)
PY
)" || true
    automation_id="$(printf '%s' "$automation_context" | awk -F '\t' '{print $1}')"
    automation_memory_file="$(printf '%s' "$automation_context" | awk -F '\t' '{print $2}')"
    automation_memory_source="$(printf '%s' "$automation_context" | awk -F '\t' '{print $3}')"
    automation_memory_external_hydrated="$(printf '%s' "$automation_context" | awk -F '\t' '{print $4}')"
    automation_memory_external_sync_pending="$(printf '%s' "$automation_context" | awk -F '\t' '{print $5}')"
  fi

  if [ -z "$automation_id" ]; then
    automation_id="$(project_automation_id "$PROJECT_NAME" 2>/dev/null || true)"
  fi
  if [ -n "$automation_id" ] && [ -z "$automation_memory_file" ] && resolve_automation_memory_read_file "$PROJECT_NAME" "$automation_id" >/dev/null 2>&1; then
    automation_memory_file="${AUTOMATION_MEMORY_RESOLVED_FILE:-}"
    automation_memory_source="${AUTOMATION_MEMORY_RESOLVED_SOURCE:-none}"
    automation_memory_external_hydrated="${AUTOMATION_MEMORY_EXTERNAL_HYDRATED:-false}"
    automation_memory_external_sync_pending="${AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING:-true}"
  fi

  python3 - "$SELF_IMPROVE_RUN_FILE" "$PROJECT_NAME" "$status_override" "$tmp_improvements" "$tmp_submit" "$automation_id" "$automation_memory_file" "$automation_memory_source" "$automation_memory_external_hydrated" "$automation_memory_external_sync_pending" "$metrics_input_status" "$metrics_input_reason" "$metrics_input_refresh_performed" "$metrics_input_missing_keys_json" <<'PY'
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

run_file = Path(sys.argv[1])
project_name = sys.argv[2]
status_override = sys.argv[3]
improvements_path = Path(sys.argv[4])
submit_path = Path(sys.argv[5])
automation_id = str(sys.argv[6] or "").strip()
automation_memory_file = str(sys.argv[7] or "").strip()
automation_memory_source = str(sys.argv[8] or "").strip() or "none"
automation_memory_external_hydrated = str(sys.argv[9] or "").strip().lower() == "true"
automation_memory_external_sync_pending = str(sys.argv[10] or "").strip().lower() == "true"
metrics_input_status = str(sys.argv[11] or "").strip() or "unknown"
metrics_input_reason = str(sys.argv[12] or "").strip() or "not_checked"
metrics_input_refresh_performed = str(sys.argv[13] or "").strip().lower() == "true"
metrics_input_missing_keys_raw = str(sys.argv[14] or "").strip()

try:
    improvements_json = json.loads(improvements_path.read_text(encoding="utf-8") or "{}")
except Exception:
    improvements_json = {}

try:
    submit_json = json.loads(submit_path.read_text(encoding="utf-8") or "{}")
except Exception:
    submit_json = {}

try:
    metrics_input_missing_keys = json.loads(metrics_input_missing_keys_raw or "[]")
except Exception:
    metrics_input_missing_keys = []
if not isinstance(metrics_input_missing_keys, list):
    metrics_input_missing_keys = []

analysis = improvements_json.get("data", {}).get("analysis", {})
metrics_snapshot = improvements_json.get("data", {}).get("metrics_snapshot", {})
generated_at = improvements_json.get("data", {}).get("generated_at")
generated_count = int(analysis.get("generated_count", submit_json.get("total", 0)) or 0)
submitted_count = int(submit_json.get("submitted", 0) or 0)
skipped_count = int(submit_json.get("skipped", max(0, generated_count - submitted_count)) or 0)
analysis_reason = str(analysis.get("dominant_gating_reason", "none") or "none")
submission_reason = str(submit_json.get("submission_limit_reason", "none") or "none")
dominant_reason = analysis_reason
if str(submit_json.get("dominant_gating_reason", "none") or "none") != "none":
    dominant_reason = str(submit_json.get("dominant_gating_reason") or "submission_limit")


def safe_int(value, fallback=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def normalize_text(value):
    return " ".join(str(value or "").split())


def normalize_pause_payload(payload):
    if not isinstance(payload, dict):
        payload = {}
    remediation = payload.get("remediation") if isinstance(payload.get("remediation"), dict) else {}
    escalation = payload.get("escalation") if isinstance(payload.get("escalation"), dict) else {}
    active = payload.get("active") is True
    reason = normalize_text(payload.get("reason")) or ("paused_by_file" if active else "none")
    return {
        "active": active,
        "reason": reason,
        "file": normalize_text(payload.get("file")),
        "detected_at": normalize_text(payload.get("detected_at")),
        "age_seconds": max(safe_int(payload.get("age_seconds"), 0), 0),
        "escalation": {
            "active": escalation.get("active") is True,
            "kind": normalize_text(escalation.get("kind")) or "none",
            "severity": normalize_text(escalation.get("severity")) or "none",
            "threshold_seconds": max(safe_int(escalation.get("threshold_seconds"), 0), 0),
            "title": normalize_text(escalation.get("title")),
            "summary": normalize_text(escalation.get("summary")),
        },
        "remediation": {
            "active": remediation.get("active") is True,
            "kind": normalize_text(remediation.get("kind")) or ("none" if not active else "inspect_pause_file"),
            "title": normalize_text(remediation.get("title")),
            "summary": normalize_text(remediation.get("summary")),
            "command": normalize_text(remediation.get("command")),
        },
    }


def build_automation_memory_payload():
    readable = bool(automation_memory_file and os.path.isfile(automation_memory_file))
    exists = bool(automation_memory_file)
    continuity_status = "missing"
    if readable:
        if automation_memory_source == "mirror" or automation_memory_external_sync_pending:
            continuity_status = "mirror_only"
        elif automation_memory_external_hydrated:
            continuity_status = "hydrated_external"
        else:
            continuity_status = "external"
    return {
        "automation_id": automation_id,
        "exists": exists,
        "memory_file": automation_memory_file,
        "source": automation_memory_source,
        "external_hydrated": automation_memory_external_hydrated,
        "external_sync_pending": automation_memory_external_sync_pending,
        "readable": readable,
        "continuity_status": continuity_status,
    }


def normalize_overload_gate(payload):
    if not isinstance(payload, dict):
        payload = {}
    raw_candidates = payload.get("candidates")
    candidates = []
    if isinstance(raw_candidates, list):
        for item in raw_candidates[:8]:
            if not isinstance(item, dict):
                continue
            candidates.append(
                {
                    "title": normalize_text(item.get("title")),
                    "rank": max(safe_int(item.get("rank"), 0), 0),
                    "selected": item.get("selected") is True,
                    "blocked": item.get("blocked") is True,
                    "blocked_reason": normalize_text(item.get("blocked_reason")) or "none",
                    "score": safe_int(item.get("score"), 0),
                    "static_priority": safe_int(item.get("static_priority"), 0),
                    "signal_priority": safe_int(item.get("signal_priority"), 0),
                    "recent_failures_since_latest_success": safe_int(
                        item.get("recent_failures_since_latest_success"), 0
                    ),
                    "recent_self_improve_failures": safe_int(item.get("recent_self_improve_failures"), 0),
                }
            )
    active = payload.get("active") is True
    return {
        "active": active,
        "preserved_title": normalize_text(payload.get("preserved_title")),
        "preserved_reason": normalize_text(payload.get("preserved_reason")) or ("inactive" if not active else "unknown"),
        "candidate_count": max(safe_int(payload.get("candidate_count"), len(candidates)), len(candidates)),
        "blocked_candidate_count": max(safe_int(payload.get("blocked_candidate_count"), 0), 0),
        "candidates": candidates,
    }


def normalize_title_list(values, limit=8):
    normalized = []
    if not isinstance(values, list):
        return normalized
    for value in values:
        title = normalize_text(value)
        if title and title not in normalized:
            normalized.append(title)
        if len(normalized) >= limit:
            break
    return normalized


def build_selection_payload(ranked_titles, submit_payload, overload_payload):
    ranked = normalize_title_list(ranked_titles, 8)
    submitted = normalize_title_list(submit_payload.get("submitted_titles"), 8)
    preserved_title = normalize_text(overload_payload.get("preserved_title"))

    if submitted:
        selected_title = submitted[0]
        state = "submitted"
    elif preserved_title:
        selected_title = preserved_title
        state = "preserved"
    elif ranked:
        selected_title = ranked[0]
        state = "ranked_only"
    else:
        selected_title = ""
        state = "none"

    next_title = ""
    for title in ranked:
        if title in submitted:
            continue
        if selected_title and title == selected_title:
            continue
        next_title = title
        break

    return {
        "selected_title": selected_title,
        "state": state,
        "submitted_titles": submitted,
        "ranked_titles": ranked,
        "next_title": next_title,
    }


improvements = improvements_json.get("data", {}).get("improvements", [])
if not isinstance(improvements, list):
    improvements = []
ranked_titles = normalize_title_list(
    [
        item.get("title")
        for item in improvements
        if isinstance(item, dict)
    ],
    8,
)
normalized_overload = normalize_overload_gate(analysis.get("overload_gate"))
selection_payload = build_selection_payload(ranked_titles, submit_json, normalized_overload)
pause_payload = normalize_pause_payload(improvements_json.get("data", {}).get("pause"))

payload = {
    "status": status_override,
    "project": project_name,
    "generated_at": generated_at,
    "selected_improvement": selection_payload.get("selected_title") or "",
    "selection": selection_payload,
    "counts": {
        "detected": int(analysis.get("detected_count", generated_count) or 0),
        "generated": generated_count,
        "submitted": submitted_count,
        "skipped": skipped_count,
        "blocked_analysis": int(analysis.get("blocked_analysis_count", 0) or 0),
    },
    "gating": {
        "dominant_reason": dominant_reason,
        "analysis_reason": analysis_reason,
        "submission_reason": submission_reason,
        "title_family_filtered_count": max(safe_int(analysis.get("title_family_filtered_count"), 0), 0),
        "zombie_filtered_count": max(safe_int(analysis.get("zombie_filtered_count"), 0), 0),
        "non_retryable_filtered_count": max(safe_int(analysis.get("non_retryable_filtered_count"), 0), 0),
        "active_self_improve_count": max(safe_int(submit_json.get("active_self_improve_count"), 0), 0),
        "resulting_active_self_improve_count": max(
            safe_int(
                submit_json.get(
                    "resulting_active_self_improve_count",
                    submit_json.get("active_self_improve_count"),
                ),
                0,
            ),
            0,
        ),
        "active_self_improve_cap": max(safe_int(submit_json.get("active_self_improve_cap"), 0), 0),
        "backlog_bypass_active": submit_json.get("backlog_bypass_active") is True,
        "retired_resolved_pending_tasks": max(
            safe_int(submit_json.get("retired_resolved_pending_tasks"), 0),
            0,
        ),
        "retired_obsolete_pending_tasks": max(
            safe_int(submit_json.get("retired_obsolete_pending_tasks"), 0),
            0,
        ),
        "retired_no_gain_completed_tasks": max(
            safe_int(submit_json.get("retired_no_gain_completed_tasks"), 0),
            0,
        ),
        "kept_metric_improved_completed_tasks": max(
            safe_int(submit_json.get("kept_metric_improved_completed_tasks"), 0),
            0,
        ),
        "deduped_zombie_shelved_tasks": max(
            safe_int(submit_json.get("deduped_zombie_shelved_tasks"), 0),
            0,
        ),
        "backlog_gate_active": bool(metrics_snapshot.get("backlog_gate_active")),
        "overload": normalized_overload,
    },
    "pause": pause_payload,
    "automation_memory": build_automation_memory_payload(),
    "metrics_input": {
        "status": normalize_text(metrics_input_status) or "unknown",
        "refresh_performed": metrics_input_refresh_performed,
        "reason": normalize_text(metrics_input_reason) or "not_checked",
        "missing_keys": [
            normalize_text(item)
            for item in metrics_input_missing_keys
            if normalize_text(item)
        ],
    },
    "metrics_snapshot": metrics_snapshot,
}

run_file.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile("w", delete=False, dir=run_file.parent, encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
    temp_path = handle.name
os.replace(temp_path, str(run_file))
PY

  local alerts_metrics_json=""
  alerts_metrics_json="$(python3 - "$METRICS_FILE" "$tmp_improvements" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
improvements_path = Path(sys.argv[2])


def safe_int(value: object) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


try:
    metrics_payload = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    metrics_payload = {}
if not isinstance(metrics_payload, dict):
    metrics_payload = {}

try:
    improvements_payload = json.loads(improvements_path.read_text(encoding="utf-8"))
except Exception:
    improvements_payload = {}
if not isinstance(improvements_payload, dict):
    improvements_payload = {}

pause_payload = improvements_payload.get("data", {}).get("pause", {})
if not isinstance(pause_payload, dict):
    pause_payload = {}
pause_escalation = pause_payload.get("escalation") if isinstance(pause_payload.get("escalation"), dict) else {}
pause_remediation = pause_payload.get("remediation") if isinstance(pause_payload.get("remediation"), dict) else {}

pause_active = pause_payload.get("active") is True
metrics_payload["self_improve_paused"] = pause_active
metrics_payload["self_improve_pause_reason"] = str(
    pause_payload.get("reason") or ("paused_by_file" if pause_active else "inactive")
).strip()
metrics_payload["self_improve_pause_file"] = str(pause_payload.get("file") or "").strip()
metrics_payload["self_improve_pause_detected_at"] = str(pause_payload.get("detected_at") or "").strip()
metrics_payload["self_improve_pause_age_seconds"] = max(safe_int(pause_payload.get("age_seconds")), 0)
metrics_payload["self_improve_pause_escalated"] = pause_escalation.get("active") is True
metrics_payload["self_improve_pause_remediation_kind"] = str(pause_remediation.get("kind") or "").strip()
metrics_payload["self_improve_pause_remediation_title"] = str(pause_remediation.get("title") or "").strip()
metrics_payload["self_improve_pause_remediation_summary"] = str(pause_remediation.get("summary") or "").strip()
metrics_payload["self_improve_pause_remediation_command"] = str(pause_remediation.get("command") or "").strip()

print(json.dumps(metrics_payload))
PY
)"
  write_alerts_payload "$PROJECT_NAME" "$alerts_metrics_json" || true
  rm -f "$tmp_improvements" "$tmp_submit" 2>/dev/null || true
}

append_self_improve_memory_summary() {
  local improvements_json="${1:-}"
  local submit_result_json="${2:-}"
  local run_status="${3:-success}"
  local automation_id=""
  local existing_summary_signature=""
  local existing_summary_source=""
  local memory_file=""
  local recent_summary_match="false"
  local summary_line=""
  local summary_is_noop="false"
  local summary_signature=""
  local duration_seconds=0

  automation_id="$(project_automation_id "$PROJECT_NAME" 2>/dev/null || true)"
  [ -n "$automation_id" ] || return 0

  if [ -n "${SELF_IMPROVE_START_EPOCH:-}" ]; then
    duration_seconds=$(( $(date +%s) - SELF_IMPROVE_START_EPOCH ))
    [ "$duration_seconds" -ge 0 ] || duration_seconds=0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  summary_line="$(python3 - "$improvements_json" "$submit_result_json" "$run_status" "$duration_seconds" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone

improvements_raw = sys.argv[1] if len(sys.argv) > 1 else ""
submit_raw = sys.argv[2] if len(sys.argv) > 2 else ""
run_status = str(sys.argv[3] if len(sys.argv) > 3 else "").strip() or "success"
try:
    duration_seconds = max(int(sys.argv[4]), 0)
except (TypeError, ValueError):
    duration_seconds = 0

try:
    improvements_payload = json.loads(improvements_raw or "{}")
except Exception:
    improvements_payload = {}

try:
    submit_payload = json.loads(submit_raw or "{}")
except Exception:
    submit_payload = {}


def normalize_text(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_field(value: object, fallback: str) -> str:
    text = normalize_text(value).replace("|", "/")
    return text or fallback


def safe_int(value: object, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


improvements = improvements_payload.get("data", {}).get("improvements", [])
if not isinstance(improvements, list):
    improvements = []

pause_payload = improvements_payload.get("data", {}).get("pause", {})
if not isinstance(pause_payload, dict):
    pause_payload = {}
pause_escalation = pause_payload.get("escalation") if isinstance(pause_payload.get("escalation"), dict) else {}
pause_remediation = pause_payload.get("remediation") if isinstance(pause_payload.get("remediation"), dict) else {}
pause_active = pause_payload.get("active") is True
pause_title = normalize_text(pause_escalation.get("title")) if pause_active else ""
pause_remediation_title = normalize_text(pause_remediation.get("title")) if pause_active else ""

titles: list[str] = []
for item in improvements:
    if not isinstance(item, dict):
        continue
    title = normalize_text(item.get("title"))
    if title:
        titles.append(title)

analysis = improvements_payload.get("data", {}).get("analysis", {})
if not isinstance(analysis, dict):
    analysis = {}

detected_count = max(safe_int(analysis.get("detected_count"), len(titles)), 0)
generated_count = len(titles)
submitted_count = max(safe_int(submit_payload.get("submitted"), 0), 0)
if titles:
    weakness = titles[0]
    improvement = titles[0]
elif pause_active:
    weakness = pause_title or "Self-improve paused by file"
    improvement = "none"
else:
    weakness = normalize_text(analysis.get("dominant_gating_reason")) or run_status
    improvement = "none"

if pause_active and not titles:
    next_title = pause_remediation_title or "none"
elif submitted_count < generated_count and generated_count > 1:
    next_title = titles[submitted_count]
elif generated_count > 1:
    next_title = titles[1]
else:
    next_title = "none"

timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
summary = (
    f"- {timestamp} | weakness={normalize_field(weakness, 'none')} | "
    f"improvement={normalize_field(improvement, 'none')} | "
    f"outcome={normalize_field(run_status, 'unknown')} submitted={submitted_count}/{generated_count} "
    f"detected={detected_count} duration_s={duration_seconds} | "
    f"next={normalize_field(next_title, 'none')}"
)
print(summary)
PY
)" || true

  [ -n "$(trim_text "$summary_line")" ] || return 0
  summary_signature="$(python3 - "$summary_line" <<'PY'
from __future__ import annotations

import re
import sys

line = str(sys.argv[1] if len(sys.argv) > 1 else "").strip()
line = re.sub(r"^-\s+\d{4}-\d{2}-\d{2}T[^|]+\|\s*", "", line)
line = re.sub(r"\bduration_s=\d+\b", "duration_s=*", line)
line = re.sub(r"\s*\|\s*external_sync_pending=(?:true|false)\s*$", "", line)
print(line.strip())
PY
)" || true
  [ -n "$(trim_text "$summary_signature")" ] || summary_signature=""
  summary_is_noop="$(python3 - "$summary_line" <<'PY'
from __future__ import annotations

import sys

line = str(sys.argv[1] if len(sys.argv) > 1 else "")
print("true" if " | improvement=none | " in line else "false")
PY
)" || true
  case "$summary_is_noop" in
    true) ;;
    *) summary_is_noop="false" ;;
  esac

  if resolve_automation_memory_read_file "$PROJECT_NAME" "$automation_id" >/dev/null 2>&1; then
    memory_file="${AUTOMATION_MEMORY_RESOLVED_FILE:-}"
    existing_summary_source="${AUTOMATION_MEMORY_RESOLVED_SOURCE:-none}"
  else
    memory_file="$(project_automation_memory_file "$PROJECT_NAME" "$automation_id" 2>/dev/null || true)"
    existing_summary_source="mirror"
  fi

  if [ -f "$memory_file" ]; then
    local existing_summary_info=""
    existing_summary_info="$(python3 - "$memory_file" "$summary_signature" "$summary_is_noop" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

path = Path(sys.argv[1]) if len(sys.argv) > 1 else None
target_signature = str(sys.argv[2] if len(sys.argv) > 2 else "").strip()
summary_is_noop = str(sys.argv[3] if len(sys.argv) > 3 else "").strip().lower() == "true"
recent_entry_limit = 32


def normalize_summary_signature(line: str) -> str:
    line = re.sub(r"^-\s+\d{4}-\d{2}-\d{2}T[^|]+\|\s*", "", line)
    line = re.sub(r"\bduration_s=\d+\b", "duration_s=*", line)
    line = re.sub(r"\s*\|\s*external_sync_pending=(?:true|false)\s*$", "", line)
    return line.strip()


if path is None or not path.is_file():
    raise SystemExit(0)

latest_signature = ""
recent_signatures: list[str] = []
for raw_line in reversed(path.read_text(encoding="utf-8").splitlines()):
    line = str(raw_line or "").strip()
    if not line.startswith("- "):
        continue
    signature = normalize_summary_signature(line)
    if not signature:
        continue
    if not latest_signature:
        latest_signature = signature
    if len(recent_signatures) < recent_entry_limit:
        recent_signatures.append(signature)
    if latest_signature and len(recent_signatures) >= recent_entry_limit:
        break

recent_match = summary_is_noop and bool(target_signature) and target_signature in recent_signatures
print(f"{latest_signature}\t{'true' if recent_match else 'false'}")
PY
)" || true
    existing_summary_signature="$(printf '%s' "$existing_summary_info" | awk -F '\t' '{print $1}')"
    recent_summary_match="$(printf '%s' "$existing_summary_info" | awk -F '\t' '{print $2}')"
  fi

  if [ -n "$summary_signature" ] && [ "$summary_signature" = "$existing_summary_signature" ]; then
    log_msg DEBUG self-improve "Skipped duplicate automation memory summary from ${existing_summary_source:-none}"
    return 0
  fi
  if [ "$summary_is_noop" = "true" ] && [ "$recent_summary_match" = "true" ]; then
    log_msg DEBUG self-improve "Skipped repeated no-op automation memory summary from ${existing_summary_source:-none}"
    return 0
  fi

  append_automation_memory_entry "$PROJECT_NAME" "$automation_id" "$summary_line" >/dev/null 2>&1 || true
}

submit_improvement_tasks() {
  local improvements_json="$1"

  # Register tasks directly in the task registry (tasks.json) as pending_approval.
  # The reconcile loop will pick them up and enqueue them once approved.
  # This avoids the stale-queue-entry problem where queue-only entries get removed.
  # Write improvements JSON to a temp file so the Python heredoc can read it
  local tmp_improvements
  tmp_improvements="$(mktemp)"
  printf '%s' "$improvements_json" > "$tmp_improvements"

  local result
  local project_workspace
  project_workspace="$(resolve_project_workspace "$PROJECT_NAME" 2>/dev/null || printf '%s' "$ROOT_DIR")"
  result="$(python3 - \
    "$REGISTRY_FILE" "$PROJECT_NAME" "$TASK_LOG" "$IMPROVEMENT_LOG" "${MAX_AGENT_RETRIES:-2}" "$tmp_improvements" "$LEARNING_DIR/provider-routing.json" "$LEARNING_DIR/provider-stats.json" "$ROOT_DIR" "$project_workspace" <<'PYSUBMIT'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

registry_path = Path(sys.argv[1])
project_name = sys.argv[2]
task_log_path = Path(sys.argv[3])
improvement_log_path = Path(sys.argv[4])
default_max_retries = max(1, int(sys.argv[5] or "2"))
improvements_input_path = Path(sys.argv[6])
routing_path = Path(sys.argv[7])
stats_path = Path(sys.argv[8])
root_dir = Path(sys.argv[9]).resolve()
project_workspace = Path(sys.argv[10]).resolve()
enforce_workspace_target_validation = project_workspace != root_dir
improvements_json = json.loads(improvements_input_path.read_text(encoding="utf-8"))
improvements = improvements_json.get("data", {}).get("improvements", [])
# The generator path already tracks shelved families for cooldown/dedup purposes.
# Submission-time "active" checks are only for work that still occupies the live
# backlog, so shelved tasks must not consume the active self-improve cap.
ACTIVE_SELF_IMPROVE_STATUSES = {"pending_approval", "approved", "queued", "running"}
ACTIVE_SELF_IMPROVE_CAP = max(1, int(os.environ.get("SELF_IMPROVE_ACTIVE_TASK_CAP", "3") or "3"))
if enforce_workspace_target_validation:
    ACTIVE_SELF_IMPROVE_CAP = max(
        1,
        int(os.environ.get("SELF_IMPROVE_EXTERNAL_ACTIVE_TASK_CAP", "1") or "1"),
    )
BACKLOG_DRAIN_SIGNAL_THRESHOLD = 8
TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000
EXTREME_TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD * 2
RETRY_CLASSIFICATION_COVERAGE_THRESHOLD = 0.50
DIAGNOSTIC_COVERAGE_THRESHOLD = 0.35
ZERO_STEP_TIMEOUT_ALERT_THRESHOLD = min(
    1.0,
    max(
        0.0,
        float(os.environ.get("SELF_IMPROVE_ZERO_STEP_TIMEOUT_ALERT_THRESHOLD", "0.5") or "0.5"),
    ),
)
ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD = min(
    1.0,
    max(
        0.0,
        float(os.environ.get("SELF_IMPROVE_ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD", "0.75") or "0.75"),
    ),
)
SELF_IMPROVE_METRIC_OUTCOME_GRACE_SECONDS = max(
    0,
    int(os.environ.get("SELF_IMPROVE_METRIC_OUTCOME_GRACE_SECONDS", "300") or "300"),
)

# Adaptive submission limit: when success rate is very low, submit fewer tasks
# to avoid flooding the queue with experiments while the system is struggling
metrics_snap = improvements_json.get("data", {}).get("metrics_snapshot", {})
current_success_rate = float(metrics_snap.get("success_rate", 0))
recent_success_rate = float(metrics_snap.get("recent_success_rate", 0) or 0)
improvement_detected = bool(metrics_snap.get("improvement_detected"))
regression_detected = bool(metrics_snap.get("regression_detected"))
registry_changed = False
if current_success_rate < 0.15:
    MAX_SUBMIT = 1  # System is struggling — only 1 improvement at a time
    submission_limit_reason = "critical_low_success_rate"
elif current_success_rate < 0.30:
    MAX_SUBMIT = 2  # Below target — limit improvements
    submission_limit_reason = "low_success_rate"
else:
    MAX_SUBMIT = 3  # Healthy — normal rate
    submission_limit_reason = "default_limit"

# Let short-term learning steer the same throttle. Strong recent recovery can
# cautiously widen the experiment window, while a recent regression tightens it.
if regression_detected or (
    recent_success_rate > 0
    and current_success_rate >= 0.30
    and recent_success_rate + 0.15 < current_success_rate
):
    MAX_SUBMIT = min(MAX_SUBMIT, 1)
    submission_limit_reason = "regression_detected"
elif (
    improvement_detected
    and current_success_rate < 0.30
    and recent_success_rate >= current_success_rate + 0.20
):
    MAX_SUBMIT = min(2, MAX_SUBMIT + 1)
    if submission_limit_reason != "critical_low_success_rate":
        submission_limit_reason = "recent_recovery_boost"

try:
    registry_payload = json.loads(registry_path.read_text(encoding="utf-8"))
    tasks = registry_payload.get("tasks", [])
    if not isinstance(tasks, list):
        tasks = []
except Exception:
    tasks = []

def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def next_task_id(tasks_list: list[dict], title: str) -> str:
    max_num = 0
    for t in tasks_list:
        m = re.match(r"^task-(\d+)-", str(t.get("id", "")))
        if m:
            max_num = max(max_num, int(m.group(1)))
    slug = re.sub(r"[^a-z0-9]+", "-", title.strip().lower()).strip("-")[:40] or "task"
    return f"task-{max_num + 1:03d}-{slug}"

def normalize_project(val: str) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", val.strip().lower()))


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_improvement_title(value: Any) -> str:
    text = normalize_text(value)
    if text.startswith("[self-improve:") and "]" in text:
        text = text.split("]", 1)[1].strip()
    if " (files:" in text:
        text = text.split(" (files:", 1)[0].strip()
    if " -- " in text:
        text = text.split(" -- ", 1)[0].strip()
    return text


def normalize_target_files_for_project(target_files: Any) -> tuple[list[str], list[str]]:
    normalized: list[str] = []
    invalid: list[str] = []
    seen: set[str] = set()
    values = target_files if isinstance(target_files, list) else []

    for raw_value in values:
        raw_path = str(raw_value or "").strip()
        if not raw_path:
            continue

        candidate = raw_path
        if enforce_workspace_target_validation:
            path = Path(raw_path)
            try:
                resolved = path.resolve() if path.is_absolute() else (project_workspace / path).resolve()
                relative = resolved.relative_to(project_workspace)
            except Exception:
                invalid.append(raw_path)
                continue
            if not resolved.is_file():
                invalid.append(raw_path)
                continue
            candidate = str(relative).replace(os.sep, "/")

        key = normalize_text(candidate).lower()
        if not key or key in seen:
            continue
        seen.add(key)
        normalized.append(candidate)
        if len(normalized) >= 3:
            break

    return normalized, invalid


def read_project_spec_path(project: str) -> Path | None:
    metadata_path = root_dir / "projects" / project / "project.json"
    default_path = root_dir / "projects" / project / "spec.md"
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception:
        payload = {}
    if isinstance(payload, dict):
        spec_file = str(payload.get("spec_file") or "").strip()
        if spec_file:
            try:
                candidate = Path(spec_file)
                if not candidate.is_absolute():
                    candidate = (root_dir / candidate).resolve()
                else:
                    candidate = candidate.resolve()
                return candidate
            except Exception:
                pass
    return default_path if default_path.is_file() else None


def extract_spec_milestone_seed_block(spec_text: str) -> str | None:
    match = re.search(
        r"(?ms)^## Milestone Seeds\s*\n```json\s*\n(.*?)\n```\s*(?=^## |\Z)",
        spec_text,
    )
    if not match:
        return None
    payload = str(match.group(1) or "").strip()
    return payload or None


def parse_project_spec_milestone_seeds(project: str) -> list[dict[str, Any]]:
    spec_path = read_project_spec_path(project)
    if spec_path is None or not spec_path.is_file():
        return []
    try:
        payload = extract_spec_milestone_seed_block(spec_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not payload:
        return []
    try:
        decoded = json.loads(payload)
    except Exception:
        return []
    if isinstance(decoded, dict):
        decoded = decoded.get("seeds")
    if not isinstance(decoded, list):
        return []
    return [item for item in decoded if isinstance(item, dict)]


def seed_string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item or "").strip()]
    text = str(value or "").strip()
    return [text] if text else []


def resolve_workspace_seed_file(candidate: Any) -> Path | None:
    relative_path = str(candidate or "").strip()
    if not relative_path:
        return None
    path = Path(relative_path)
    resolved = path.resolve() if path.is_absolute() else (project_workspace / path).resolve()
    try:
        resolved.relative_to(project_workspace)
    except Exception:
        return None
    return resolved if resolved.is_file() else None


EXTERNAL_PROJECT_META_FILE_PREFIXES = (
    ".codex-agent/",
    ".git/",
    "agents/",
    "codex-dashboard/",
    "codex-learning/",
    "scripts/",
)
EXTERNAL_PROJECT_PRODUCT_FILE_PREFIXES = (
    "README.md",
    "app/",
    "apps/",
    "backend/",
    "client/",
    "clients/",
    "docs/architecture/",
    "docs/overview",
    "docs/product/",
    "frontend/",
    "mobile/",
    "packages/",
    "server/",
    "shared/",
    "src/",
    "web/",
)
EXTERNAL_PROJECT_SKIP_SCAN_DIRS = {
    ".codex-agent",
    ".git",
    ".next",
    ".turbo",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "tmp",
}
_external_workspace_files_cache: list[str] | None = None


def normalized_project_relative_path(value: Any) -> str:
    return normalize_text(value).replace(os.sep, "/").lstrip("./")


def path_matches_prefix(path: str, prefix: str) -> bool:
    if not path or not prefix:
        return False
    normalized_path = normalized_project_relative_path(path)
    normalized_prefix = normalized_project_relative_path(prefix)
    if normalized_prefix.endswith("/"):
        return normalized_path.startswith(normalized_prefix)
    return normalized_path == normalized_prefix or normalized_path.startswith(f"{normalized_prefix}/")


def is_external_project_meta_file(path: Any) -> bool:
    normalized_path = normalized_project_relative_path(path)
    if not normalized_path:
        return False
    return any(path_matches_prefix(normalized_path, prefix) for prefix in EXTERNAL_PROJECT_META_FILE_PREFIXES)


def is_external_project_product_file(path: Any) -> bool:
    normalized_path = normalized_project_relative_path(path)
    if not normalized_path or is_external_project_meta_file(normalized_path):
        return False
    return any(path_matches_prefix(normalized_path, prefix) for prefix in EXTERNAL_PROJECT_PRODUCT_FILE_PREFIXES)


def external_project_file_priority(path: Any) -> int:
    normalized_path = normalized_project_relative_path(path)
    if not normalized_path:
        return 0
    if normalized_path.startswith(
        ("app/", "apps/", "backend/", "client/", "clients/", "frontend/", "mobile/", "server/", "shared/", "src/", "web/")
    ):
        if re.search(r"\.(cjs|cpp|cs|go|java|js|jsx|kt|kts|mjs|py|rb|rs|swift|ts|tsx)$", normalized_path):
            return 5
        if "/scripts/" in normalized_path:
            return 4
        return 4
    if normalized_path.startswith("packages/schema/"):
        return 4
    if normalized_path.startswith("packages/playbooks/"):
        return 3
    if normalized_path.startswith("docs/architecture/"):
        return 3
    if normalized_path.startswith("docs/"):
        return 2
    if normalized_path == "README.md" or normalized_path.endswith("/README.md"):
        return 1
    return 0


def external_project_workspace_files() -> list[str]:
    global _external_workspace_files_cache
    if _external_workspace_files_cache is not None:
        return _external_workspace_files_cache
    if not enforce_workspace_target_validation:
        _external_workspace_files_cache = []
        return _external_workspace_files_cache

    discovered: list[str] = []
    try:
        for current_root, dirnames, filenames in os.walk(project_workspace):
            dirnames[:] = [name for name in dirnames if name not in EXTERNAL_PROJECT_SKIP_SCAN_DIRS]
            try:
                relative_root = Path(current_root).resolve().relative_to(project_workspace)
            except Exception:
                continue
            for filename in filenames:
                relative_path = (
                    Path(filename)
                    if str(relative_root) == "."
                    else relative_root / filename
                )
                normalized_path = normalized_project_relative_path(relative_path)
                if normalized_path:
                    discovered.append(normalized_path)
    except Exception:
        discovered = []

    _external_workspace_files_cache = sorted(dict.fromkeys(discovered))
    return _external_workspace_files_cache


def external_project_product_files() -> list[str]:
    return [
        path
        for path in external_project_workspace_files()
        if is_external_project_product_file(path)
    ]


def external_project_category_affinity(path: Any, category: Any) -> int:
    normalized_path = normalized_project_relative_path(path)
    normalized_category = normalize_text(category).lower()
    if not normalized_path:
        return 0
    if normalized_category in {"stability", "performance", "code_quality", "general"}:
        if normalized_path.startswith(
            ("app/", "apps/", "backend/", "client/", "clients/", "frontend/", "mobile/", "server/", "shared/", "src/", "web/")
        ):
            return 4
        if normalized_path.startswith(("packages/", "docs/architecture/")):
            return 2
    if normalized_category == "learning":
        if normalized_path.startswith(("packages/playbooks/", "packages/schema/", "docs/architecture/", "docs/overview")):
            return 4
        if normalized_path.startswith(("docs/", "README.md")):
            return 2
    if normalized_category == "testing":
        if normalized_path.endswith((".spec.js", ".spec.ts", ".test.js", ".test.ts")):
            return 4
        if normalized_path.endswith("smoke.mjs") or "/scripts/" in normalized_path:
            return 3
        if normalized_path.startswith(("packages/schema/", "packages/playbooks/")):
            return 2
    return 0


def humanize_identifier(value: Any) -> str:
    return normalize_text(str(value or "").replace("_", " ").replace("-", " "))


def external_project_contract_gap_improvements() -> list[dict[str, Any]]:
    if not enforce_workspace_target_validation:
        return []

    improvements: list[dict[str, Any]] = []
    incident_schema_path = project_workspace / "packages/schema/incident.schema.json"
    if not incident_schema_path.is_file():
        return improvements

    try:
        incident_schema = json.loads(incident_schema_path.read_text(encoding="utf-8"))
    except Exception:
        return improvements

    if not isinstance(incident_schema, dict):
        return improvements

    examples = incident_schema.get("examples") if isinstance(incident_schema.get("examples"), list) else []
    automation_examples = []
    for example in examples:
        if not isinstance(example, dict):
            continue
        summary = normalize_text(example.get("summary")).lower()
        household_id = normalize_text(example.get("household_id")).lower()
        learning_modules = [
            normalize_text(item).lower()
            for item in (example.get("recommended_learning_modules") if isinstance(example.get("recommended_learning_modules"), list) else [])
            if normalize_text(item)
        ]
        if (
            "recent_self_improve_failure_cooldown" in summary
            or "cap pre-step planning budget" in summary
            or household_id.startswith("hh_system_")
            or "bounded_inventory_pattern" in learning_modules
        ):
            automation_examples.append(example)

    if automation_examples:
        improvements.append({
            "title": "Remove automation runtime example from incident schema",
            "category": "learning",
            "reason": (
                "Start with `packages/schema/incident.schema.json` in the root `examples` array. "
                "One example contains control-plane automation markers like "
                "`recent_self_improve_failure_cooldown`, `cap pre-step planning budget`, or "
                "`bounded_inventory_pattern`, which do not belong in the public Superheld incident contract. "
                "Remove that runtime-only example and keep the schema examples product-facing."
            ),
            "priority": "critical",
            "target_files": ["packages/schema/incident.schema.json"],
            "impact": 7,
            "effort": 2,
            "confidence": 0.9,
        })

    properties = incident_schema.get("properties") if isinstance(incident_schema.get("properties"), dict) else {}
    incident_type_property = properties.get("incident_type") if isinstance(properties.get("incident_type"), dict) else {}
    incident_type_values = [
        normalize_text(item)
        for item in (incident_type_property.get("enum") if isinstance(incident_type_property.get("enum"), list) else [])
        if normalize_text(item)
    ]
    example_incident_types = {
        normalize_text(example.get("incident_type"))
        for example in examples
        if isinstance(example, dict) and normalize_text(example.get("incident_type"))
    }
    missing_incident_types = [
        incident_type
        for incident_type in incident_type_values
        if incident_type not in example_incident_types
    ]

    if missing_incident_types:
        missing_type = missing_incident_types[0]
        improvements.append({
            "title": f"Add canonical incident example for {humanize_identifier(missing_type)}",
            "category": "learning",
            "reason": (
                "Start with `packages/schema/incident.schema.json` in the root `examples` array after the existing "
                f"incident examples. The schema declares `properties.incident_type` value `{missing_type}` but the "
                "examples do not yet cover it. Add one deterministic, product-facing example that matches the "
                f"existing contract shape and uses `incident_type: \"{missing_type}\"`."
            ),
            "priority": "high",
            "target_files": ["packages/schema/incident.schema.json"],
            "impact": 6,
            "effort": 2,
            "confidence": 0.86,
        })

    return improvements


def is_comment_or_doc_only(text: str) -> bool:
    if not text:
        return False
    if re.search(r"\b(test|tests|regression|spec|smoke)\b", text):
        return False
    patterns = (
        r"\badd\b[^.]{0,80}\bcomment\b",
        r"\bupdate\b[^.]{0,80}\bcomment\b",
        r"\bdocument\b[^.]{0,80}\bcomment\b",
        r"\bclarify\b[^.]{0,80}\bcomment\b",
        r"\bcomment[- ]only\b",
        r"\bdocumentation\b",
        r"\breadme\b",
        r"\bdocstring\b",
        r"\btypo\b",
        r"\bwhitespace\b",
    )
    return any(re.search(pattern, text) for pattern in patterns)


def degraded_submission_state(metrics: dict[str, Any]) -> bool:
    return (
        recent_success_rate <= 0.10
        or current_success_rate <= 0.15
        or metrics.get("pipeline_stale") is True
        or metrics.get("self_improve_paused") is True
    )


def low_signal_self_improve_candidate(title: str, reason: str) -> bool:
    combined = normalize_text(" ".join(value for value in (title, reason) if value)).lower()
    return degraded_submission_state(metrics_snap) and is_comment_or_doc_only(combined)


def improvement_title_key(value: Any) -> str:
    text = normalize_text(value)
    if text.startswith("[self-improve:") and "]" in text:
        text = text.split("]", 1)[1].strip()
    if " (files:" in text:
        text = text.split(" (files:", 1)[0].strip()
    if " -- " in text:
        text = text.split(" -- ", 1)[0].strip()
    text = text.lower()
    if not text:
        return ""
    if "drain approved task backlog" in text or "drain approval backlog" in text:
        return "drain approval backlog"
    if text.startswith("inventory current decision path for "):
        return text
    stable_prefixes = (
        "recover stale pipeline",
        "improve timeout diagnostic coverage",
        "cap pre-step planning budget",
        "improve retry failure classification coverage",
        "improve retry success rate",
        "improve first-pass success rate",
        "reduce timeout rate",
        "reduce registry pressure",
        "break retry churn",
        "reduce strategy saturation",
        "drain approval backlog",
        "refresh stale external signals",
    )
    for prefix in stable_prefixes:
        if prefix in text:
            return prefix
    if text.startswith("fix repeated failure:"):
        return text
    return text


SELF_IMPROVE_PLAYBOOKS = {
    "retry-classification": "playbooks/retry-classification.md",
    "zero-step-timeouts": "playbooks/zero-step-timeouts.md",
    "stale-pipeline": "playbooks/stale-pipeline.md",
}


def select_self_improve_playbook_metadata(title: Any, reason: Any = "", target_files: Any = None) -> dict[str, str]:
    title_key = improvement_title_key(title)
    normalized_reason = normalize_text(reason).lower()
    normalized_files = " ".join(
        normalize_text(path).lower()
        for path in (target_files if isinstance(target_files, list) else [])
        if normalize_text(path)
    )

    family = ""
    if (
        title_key == "improve retry failure classification coverage"
        or ("retry" in title_key and "classif" in title_key)
        or ("retry" in normalized_reason and "classif" in normalized_reason)
    ):
        family = "retry-classification"
    elif (
        title_key in {
            "cap pre-step planning budget",
            "reduce timeout rate",
            "improve timeout diagnostic coverage",
        }
        or "zero-step" in normalized_reason
        or ("timeout" in title_key and "planning" in normalized_reason)
        or ("timeout" in title_key and "planner" in normalized_files)
    ):
        family = "zero-step-timeouts"
    elif "stale pipeline" in title_key or "stale pipeline" in normalized_reason:
        family = "stale-pipeline"

    playbook = SELF_IMPROVE_PLAYBOOKS.get(family, "")
    if not family or not playbook:
        return {}
    return {"family": family, "playbook": playbook}


def self_improve_metric_snapshot(title: Any, metrics: dict[str, Any]) -> dict[str, Any]:
    normalized = improvement_title_key(title)
    if not normalized:
        return {}

    if normalized == "improve retry failure classification coverage":
        coverage = safe_float(metrics.get("retry_classification_coverage"))
        classified = max(safe_int(metrics.get("retry_classified_count")), 0)
        total = max(safe_int(metrics.get("retry_total_count")), 0)
        display = f"{coverage:.0%} ({classified}/{total})" if total > 0 else f"{coverage:.0%}"
        return {
            "metric_name": "retry_classification_coverage",
            "direction": "increase",
            "value": coverage,
            "display": display,
        }

    if normalized == "improve timeout diagnostic coverage":
        coverage = safe_float(metrics.get("diagnostic_coverage"))
        failures_with_diagnostic = max(safe_int(metrics.get("failures_with_diagnostic")), 0)
        total_failure_records = max(safe_int(metrics.get("total_failure_records")), 0)
        display = (
            f"{coverage:.0%} ({failures_with_diagnostic}/{total_failure_records})"
            if total_failure_records > 0
            else f"{coverage:.0%}"
        )
        return {
            "metric_name": "diagnostic_coverage",
            "direction": "increase",
            "value": coverage,
            "display": display,
        }

    if normalized == "cap pre-step planning budget":
        zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
        return {
            "metric_name": "zero_step_timeout_rate",
            "direction": "decrease",
            "value": zero_step_timeout_rate,
            "display": f"{zero_step_timeout_rate:.0%}",
        }

    if normalized == "reduce timeout rate":
        timeout_rate = safe_float(
            metrics.get("timeout_rate")
            if metrics.get("timeout_rate") is not None
            else metrics.get("timeout_failure_rate")
        )
        return {
            "metric_name": "timeout_rate",
            "direction": "decrease",
            "value": timeout_rate,
            "display": f"{timeout_rate:.0%}",
        }

    if normalized == "improve first-pass success rate":
        first_pass_success_rate = safe_float(metrics.get("first_pass_success_rate"))
        return {
            "metric_name": "first_pass_success_rate",
            "direction": "increase",
            "value": first_pass_success_rate,
            "display": f"{first_pass_success_rate:.0%}",
        }

    if normalized == "reduce registry pressure":
        local_registry_bytes = max(
            safe_int(
                metrics.get("local_registry_bytes")
                if metrics.get("local_registry_bytes") is not None
                else metrics.get("registry_bytes"),
                0,
            ),
            0,
        )
        return {
            "metric_name": "local_registry_bytes",
            "direction": "decrease",
            "value": float(local_registry_bytes),
            "display": f"{max(0, local_registry_bytes // 1024)}KB",
        }

    if normalized == "refresh stale external signals":
        fresh_signal_count = max(safe_int(metrics.get("fresh_external_signal_count")), 0)
        signal_status = normalize_text(metrics.get("external_signal_status")).lower()
        display = (
            f"{fresh_signal_count} fresh signal"
            if fresh_signal_count == 1
            else f"{fresh_signal_count} fresh signals"
        )
        if fresh_signal_count <= 0 and signal_status:
            display = signal_status
        return {
            "metric_name": "fresh_external_signal_count",
            "direction": "increase",
            "value": float(fresh_signal_count),
            "display": display,
        }

    if normalized == "drain approval backlog":
        approved_backlog = max(
            safe_int(
                metrics.get("approved_backlog")
                if metrics.get("approved_backlog") is not None
                else metrics.get("approved_tasks"),
                0,
            ),
            0,
        )
        pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
        approval_backlog_total = max(
            approved_backlog,
            max(safe_int(metrics.get("backlog")), 0),
            approved_backlog + pending_approval_tasks,
        )
        return {
            "metric_name": "approval_backlog_total",
            "direction": "decrease",
            "value": float(approval_backlog_total),
            "display": str(approval_backlog_total),
        }

    if normalized == "recover stale pipeline":
        pipeline_stale = metrics.get("pipeline_stale") is True
        return {
            "metric_name": "pipeline_stale",
            "direction": "decrease",
            "value": 1.0 if pipeline_stale else 0.0,
            "display": "stale" if pipeline_stale else "healthy",
        }

    if normalized == "break retry churn":
        retry_churn_detected = metrics.get("retry_churn_detected") is True
        return {
            "metric_name": "retry_churn_detected",
            "direction": "decrease",
            "value": 1.0 if retry_churn_detected else 0.0,
            "display": "detected" if retry_churn_detected else "clear",
        }

    if normalized == "reduce strategy saturation":
        strategy_saturation_detected = metrics.get("strategy_saturation_detected") is True
        return {
            "metric_name": "strategy_saturation_detected",
            "direction": "decrease",
            "value": 1.0 if strategy_saturation_detected else 0.0,
            "display": "detected" if strategy_saturation_detected else "clear",
        }

    return {}


def apply_self_improve_metric_baseline(
    task: dict[str, Any],
    title: Any,
    metrics: dict[str, Any],
) -> tuple[dict[str, Any], bool]:
    if not isinstance(task, dict):
        return task, False
    snapshot = self_improve_metric_snapshot(title, metrics)
    if not snapshot:
        return task, False

    next_task = dict(task)
    changed = False
    if not str(next_task.get("metric_name") or "").strip():
        next_task["metric_name"] = snapshot["metric_name"]
        changed = True
    if not str(next_task.get("metric_direction") or "").strip():
        next_task["metric_direction"] = snapshot["direction"]
        changed = True
    if next_task.get("metric_before") in {None, ""}:
        next_task["metric_before"] = snapshot["value"]
        changed = True
    if not str(next_task.get("metric_before_display") or "").strip():
        next_task["metric_before_display"] = snapshot["display"]
        changed = True
    return next_task, changed


def metric_value_improved(before: float, after: float, direction: str) -> bool:
    normalized_direction = normalize_text(direction).lower()
    if normalized_direction == "increase":
        return after > before
    if normalized_direction == "decrease":
        return after < before
    return False


def parse_iso8601(value: Any) -> datetime | None:
    text = normalize_text(value)
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def project_title_identity_key(project: Any, title: Any) -> str:
    project_key_value = normalize_project(str(project or ""))
    title_key_value = improvement_title_key(title)
    if not project_key_value or not title_key_value:
        return ""
    return f"{project_key_value}::{title_key_value}"


def read_json_lines(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return records
    for raw_line in raw_lines:
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


ZOMBIE_FAILURE_THRESHOLD = 5
zombie_blocklist: set[str] = set()
zombie_failure_counts: dict[str, int] = {}
identity_failure_counts: dict[str, int] = {}
for record in read_json_lines(task_log_path):
    if normalize_text(record.get("result")).lower() != "failure":
        continue
    identity_key = project_title_identity_key(
        record.get("project") or record.get("target_project"),
        str(record.get("task") or ""),
    )
    if not identity_key:
        continue
    identity_failure_counts[identity_key] = identity_failure_counts.get(identity_key, 0) + 1
for identity_key, fail_count in identity_failure_counts.items():
    if fail_count >= ZOMBIE_FAILURE_THRESHOLD:
        zombie_blocklist.add(identity_key)
        zombie_failure_counts[identity_key] = fail_count


explicit_registry_project_keys = {
    normalize_project(task.get("project") or task.get("target_project") or "")
    for task in tasks
    if isinstance(task, dict) and str(task.get("project") or task.get("target_project") or "").strip()
}
registry_uses_explicit_project_scoping = bool(explicit_registry_project_keys)


GENERIC_REPEATED_FAILURE_PLACEHOLDERS = {
    "queue execution failed after exhausting retries.",
    "queue execution failed after exhausting retries",
    "task execution failed after exhausting retries.",
    "task execution failed after exhausting retries",
    "plan: created deterministic fallback plan.",
    "created deterministic fallback plan.",
    "claude print failed",
    "codex exec failed",
}
GENERIC_REPEATED_FAILURE_PREFIXES = (
    "non-retriable failure detected",
)

INSPECT_ONLY_REPEATED_FAILURE_PREFIXES = (
    "inspect the current project files and choose the smallest safe implementation for:",
    "inspect the current code path and runtime signals behind ",
)


def is_generic_repeated_failure_placeholder(text: Any, failure_kind: Any = "") -> bool:
    normalized_text = normalize_text(text).lower()
    normalized_failure_kind = normalize_text(failure_kind).lower()
    if not normalized_text:
        return False
    if normalized_text in GENERIC_REPEATED_FAILURE_PLACEHOLDERS:
        return True
    if any(
        normalized_text.startswith(prefix)
        for prefix in GENERIC_REPEATED_FAILURE_PREFIXES
    ):
        return True
    if any(
        normalized_text.startswith(prefix)
        for prefix in INSPECT_ONLY_REPEATED_FAILURE_PREFIXES
    ):
        return True
    if normalized_failure_kind in {"unknown", "unknown_persistent"} and (
        "after exhausting retries" in normalized_text
        or "timed out after exhausting retries" in normalized_text
    ):
        return True
    return False


def contains_generic_repeated_failure_placeholder(text: Any) -> bool:
    normalized_text = normalize_text(text).lower()
    if not normalized_text:
        return False
    return (
        any(fragment in normalized_text for fragment in GENERIC_REPEATED_FAILURE_PLACEHOLDERS)
        or any(prefix in normalized_text for prefix in GENERIC_REPEATED_FAILURE_PREFIXES)
        or any(prefix in normalized_text for prefix in INSPECT_ONLY_REPEATED_FAILURE_PREFIXES)
    )


def safe_int(value: Any, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def safe_float(value: Any, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def pending_approval_pipeline_blocker_active_from_metrics(metrics: dict[str, Any]) -> bool:
    approved_only_count = max(
        safe_int(
            metrics.get("approved_tasks")
            if metrics.get("approved_tasks") is not None
            else metrics.get("approved_backlog"),
            0,
        ),
        0,
    )
    pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
    queued_tasks = max(safe_int(metrics.get("queued_tasks")), 0)
    running_tasks = max(safe_int(metrics.get("running_tasks")), 0)
    return (
        pending_approval_tasks > 0
        and metrics.get("pipeline_stale") is True
        and queued_tasks == 0
        and running_tasks == 0
        and (
            metrics.get("pending_approval_blocked_detected") is True
            or approved_only_count == 0
        )
    )


def normalize_provider(value: Any) -> str:
    candidate = str(value or "").strip().lower()
    return candidate if candidate in {"codex", "claude"} else ""


def append_history_entry(task: dict[str, Any], entry: dict[str, Any]) -> list[dict[str, Any]]:
    history = task.get("history") if isinstance(task.get("history"), list) else []
    history.append(entry)
    return history


def task_project_key(task: dict[str, Any]) -> str:
    declared_project = normalize_project(task.get("project") or task.get("target_project") or "")
    if declared_project:
        return declared_project
    if registry_uses_explicit_project_scoping:
        return ""
    return project_name


def task_text_candidates(task: dict[str, Any]) -> list[str]:
    candidates: list[str] = []
    for key in ("execution_task", "task", "title"):
        value = str(task.get(key) or "").strip()
        if value and value not in candidates:
            candidates.append(value)
    return candidates


def parse_self_improve_execution_text(value: Any) -> tuple[str, str]:
    text = str(value or "").strip()
    if not text:
        return "", ""
    body = text
    if text.lower().startswith("[self-improve:") and "]" in text:
        body = text.split("]", 1)[1].strip()
    if " -- " in body:
        title, reason = body.split(" -- ", 1)
    else:
        title, reason = body, ""
    title = title.strip()
    reason = reason.strip()
    if " (files:" in reason:
        reason = reason.split(" (files:", 1)[0].strip()
    return title, reason


def task_has_self_improve_signature(task: dict[str, Any]) -> bool:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    source = normalize_text(task_intent.get("source") or task.get("source_task_id")).lower()
    if source == "self-improve":
        return True
    if normalize_text(task.get("strategy_template")).lower() == "self_improvement":
        return True
    return any(candidate.lower().startswith("[self-improve:") for candidate in task_text_candidates(task))


def repair_active_self_improve_metadata(task: dict[str, Any], metrics: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    if not isinstance(task, dict):
        return task, False
    if normalize_text(task.get("status")).lower() not in ACTIVE_SELF_IMPROVE_STATUSES:
        return task, False
    if not task_has_self_improve_signature(task):
        return task, False

    next_task = dict(task)
    changed = False
    queue_text = str(next_task.get("execution_task") or next_task.get("task") or "").strip()
    inferred_title, inferred_reason = parse_self_improve_execution_text(queue_text)

    title = str(next_task.get("title") or inferred_title).strip()
    if title and str(next_task.get("title") or "").strip() != title:
        next_task["title"] = title
        changed = True

    if queue_text:
        if str(next_task.get("execution_task") or "").strip() != queue_text:
            next_task["execution_task"] = queue_text
            changed = True
        if str(next_task.get("task") or "").strip() != queue_text:
            next_task["task"] = queue_text
            changed = True

    if not str(next_task.get("source_task_id") or "").strip():
        next_task["source_task_id"] = "self-improve"
        changed = True
    if not str(next_task.get("root_source_task_id") or "").strip():
        next_task["root_source_task_id"] = "self-improve"
        changed = True
    related_ids = next_task.get("related_source_task_ids")
    if not isinstance(related_ids, list) or "self-improve" not in related_ids:
        next_task["related_source_task_ids"] = ["self-improve"]
        changed = True
    current_strategy_template = normalize_text(next_task.get("strategy_template")).lower()
    desired_strategy_template = (
        "bounded_learning_inventory"
        if current_strategy_template == "bounded_learning_inventory"
        else "self_improvement"
    )
    if current_strategy_template != desired_strategy_template:
        next_task["strategy_template"] = desired_strategy_template
        changed = True

    task_intent = next_task.get("task_intent") if isinstance(next_task.get("task_intent"), dict) else {}
    repaired_task_intent = dict(task_intent)
    desired_context_hint = str(
        task_intent.get("context_hint")
        or next_task.get("reason")
        or inferred_reason
        or ""
    ).strip()
    raw_target_files = next_task.get("target_files") if isinstance(next_task.get("target_files"), list) else []
    target_files, _invalid_target_files = normalize_target_files_for_project(raw_target_files)
    if raw_target_files != target_files:
        if target_files:
            next_task["target_files"] = target_files
        else:
            next_task.pop("target_files", None)
        changed = True
    desired_affected_files, _invalid_affected_files = normalize_target_files_for_project(
        task_intent.get("affected_files")
        if isinstance(task_intent.get("affected_files"), list)
        else target_files
    )
    desired_category = str(task_intent.get("category") or next_task.get("category") or "stability").strip()
    desired_objective = str(task_intent.get("objective") or title or inferred_title or "").strip()
    desired_project = str(task_intent.get("project") or task_project_key(next_task) or project_name).strip()
    desired_values = {
        "source": "self-improve",
        "objective": desired_objective,
        "project": desired_project,
        "category": desired_category,
        "context_hint": desired_context_hint[:200] if desired_context_hint else "",
        "affected_files": desired_affected_files,
    }
    for key, value in desired_values.items():
        if repaired_task_intent.get(key) != value:
            repaired_task_intent[key] = value
            changed = True
    if next_task.get("task_intent") != repaired_task_intent:
        next_task["task_intent"] = repaired_task_intent
        changed = True

    next_task, metric_changed = apply_self_improve_metric_baseline(
        next_task,
        title or inferred_title,
        metrics,
    )
    if metric_changed:
        changed = True

    playbook_metadata = select_self_improve_playbook_metadata(
        title or inferred_title,
        desired_context_hint,
        desired_affected_files,
    )
    if playbook_metadata:
        desired_family = playbook_metadata["family"]
        desired_playbook = playbook_metadata["playbook"]
        if str(next_task.get("task_family") or "").strip() != desired_family:
            next_task["task_family"] = desired_family
            changed = True
        if str(next_task.get("strategy_playbook") or "").strip() != desired_playbook:
            next_task["strategy_playbook"] = desired_playbook
            changed = True
        repaired_task_shape = (
            dict(next_task.get("task_shape"))
            if isinstance(next_task.get("task_shape"), dict)
            else {}
        )
        if str(repaired_task_shape.get("family") or "").strip() != desired_family:
            repaired_task_shape["family"] = desired_family
            changed = True
        if str(repaired_task_shape.get("playbook") or "").strip() != desired_playbook:
            repaired_task_shape["playbook"] = desired_playbook
            changed = True
        if next_task.get("task_shape") != repaired_task_shape:
            next_task["task_shape"] = repaired_task_shape
            changed = True

    if changed:
        transition_at = now_utc()
        next_task["updated_at"] = transition_at
        next_task["history"] = append_history_entry(
            next_task,
            {
                "at": transition_at,
                "action": "metadata_repair",
                "from_status": normalize_text(task.get("status")).lower(),
                "to_status": normalize_text(task.get("status")).lower(),
                "project": desired_project or project_name,
                "queue_task": str(next_task.get("execution_task") or next_task.get("title") or "").strip(),
                "note": "Repaired missing self-improve execution metadata on an active task so backlog caps and follow-up selection stay accurate.",
            },
        )
    return next_task, changed


def completed_self_improve_metric_outcome(
    task: dict[str, Any],
    metrics: dict[str, Any],
) -> tuple[dict[str, Any], bool, str]:
    if not isinstance(task, dict):
        return task, False, "none"
    if normalize_text(task.get("status")).lower() != "completed":
        return task, False, "none"
    if not task_has_self_improve_signature(task):
        return task, False, "none"
    if normalize_text(task.get("keep_decision")).lower() in {"kept", "discarded"}:
        return task, False, "none"

    completed_at_text = str(
        task.get("completed_at")
        or task.get("updated_at")
        or task.get("created_at")
        or ""
    ).strip()
    completed_at = parse_iso8601(completed_at_text)
    if completed_at is not None:
        elapsed_seconds = (datetime.now(timezone.utc) - completed_at).total_seconds()
        if elapsed_seconds < SELF_IMPROVE_METRIC_OUTCOME_GRACE_SECONDS:
            return task, False, "none"

    metric_name = str(task.get("metric_name") or "").strip()
    metric_direction = str(task.get("metric_direction") or "").strip()
    metric_before_raw = task.get("metric_before")
    if not metric_name or not metric_direction or metric_before_raw in {None, ""}:
        return task, False, "none"

    snapshot = self_improve_metric_snapshot(task.get("title") or task.get("execution_task"), metrics)
    if not snapshot:
        return task, False, "none"
    if str(snapshot.get("metric_name") or "").strip() != metric_name:
        return task, False, "none"

    before = safe_float(metric_before_raw)
    after = safe_float(snapshot.get("value"))
    before_display = str(task.get("metric_before_display") or "").strip() or str(snapshot.get("display") or "").strip()
    after_display = str(snapshot.get("display") or "").strip()

    next_task = dict(task)
    next_task["metric_after"] = after
    next_task["metric_after_display"] = after_display

    if metric_value_improved(before, after, metric_direction):
        next_task["keep_decision"] = "kept"
        return next_task, next_task != task, "kept"

    transition_at = now_utc()
    next_task["keep_decision"] = "discarded"
    next_task["status"] = "shelved"
    next_task["updated_at"] = transition_at
    next_task["shelved_reason"] = (
        f"auto-shelved: no metric gain on {metric_name} ({before_display} -> {after_display})"
    )
    next_task["history"] = append_history_entry(
        next_task,
        {
            "at": transition_at,
            "action": "auto_shelve",
            "from_status": "completed",
            "to_status": "shelved",
            "project": task_project_key(next_task) or project_name,
            "queue_task": str(next_task.get("execution_task") or next_task.get("title") or "").strip(),
            "note": (
                "Task was automatically retired because the target metric did not improve "
                f"after completion: {metric_name} stayed at {before_display} -> {after_display}."
            ),
        },
    )
    return next_task, True, "discarded"


def is_active_self_improve_task(task: dict[str, Any]) -> bool:
    if not isinstance(task, dict):
        return False
    if normalize_text(task.get("status")).lower() not in ACTIVE_SELF_IMPROVE_STATUSES:
        return False
    return task_has_self_improve_signature(task)


def has_active_self_improve_title(title: str, exclude_task_id: str = "") -> bool:
    normalized_title = normalize_text(title).lower()
    excluded_id = normalize_text(exclude_task_id)
    if not normalized_title:
        return False

    for existing_task in tasks:
        if not isinstance(existing_task, dict):
            continue
        if task_project_key(existing_task) != project:
            continue
        if excluded_id and normalize_text(existing_task.get("id")) == excluded_id:
            continue
        if not is_active_self_improve_task(existing_task):
            continue
        existing_title = normalize_text(
            existing_task.get("title") or existing_task.get("execution_task")
        ).lower()
        if existing_title == normalized_title:
            return True
    return False


def has_recent_successful_self_improve_title(title: str, exclude_task_id: str = "") -> bool:
    normalized_title = improvement_title_key(title)
    excluded_id = normalize_text(exclude_task_id)
    if not normalized_title:
        return False
    now_timestamp = datetime.now(timezone.utc)
    cooldown_seconds = max(
        0,
        int(os.environ.get("SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS", "7200") or "7200"),
    )

    for existing_task in tasks:
        if not isinstance(existing_task, dict):
            continue
        if task_project_key(existing_task) != project:
            continue
        if excluded_id and normalize_text(existing_task.get("id")) == excluded_id:
            continue
        if not task_has_self_improve_signature(existing_task):
            continue
        existing_title = improvement_title_key(existing_task.get("title") or existing_task.get("execution_task"))
        if existing_title != normalized_title:
            continue
        if normalize_text(existing_task.get("status")).lower() != "completed":
            continue
        updated_at_text = str(
            existing_task.get("updated_at")
            or existing_task.get("completed_at")
            or existing_task.get("created_at")
            or ""
        ).strip()
        if not updated_at_text:
            continue
        try:
            updated_at = datetime.fromisoformat(updated_at_text.replace("Z", "+00:00"))
        except ValueError:
            continue
        elapsed_seconds = (now_timestamp - updated_at).total_seconds()
        if elapsed_seconds < cooldown_seconds:
            return True
    return False


def improvement_has_backlog_bypass(item: dict[str, Any], metrics: dict[str, Any]) -> bool:
    if not isinstance(item, dict):
        return False
    title = normalize_text(item.get("title")).lower()
    if not title:
        return False

    zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
    if (
        zero_step_timeout_rate >= ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD
        and title in {
            "recover stale pipeline",
            "reduce timeout rate",
            "improve timeout diagnostic coverage",
            "cap pre-step planning budget",
        }
    ):
        return True

    if title == "recover stale pipeline" and metrics.get("pipeline_stale") is True:
        return True

    approved_backlog = max(
        safe_int(
            metrics.get("approved_backlog")
            if metrics.get("approved_backlog") is not None
            else metrics.get("approved_tasks"),
            0,
        ),
        0,
    )
    pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
    approved_backlog = max(
        approved_backlog,
        max(safe_int(metrics.get("backlog")), 0),
        approved_backlog + pending_approval_tasks,
    )
    queued_tasks = max(safe_int(metrics.get("queued_tasks")), 0)
    running_tasks = max(safe_int(metrics.get("running_tasks")), 0)
    pending_only_queue_blocked = (
        pending_approval_tasks > 0
        and queued_tasks == 0
        and running_tasks == 0
        and max(
            safe_int(
                metrics.get("approved_tasks")
                if metrics.get("approved_tasks") is not None
                else metrics.get("approved_backlog"),
                0,
            ),
            0,
        ) == 0
    )
    if (
        improvement_title_key(title) == "drain approval backlog"
        and (
            pending_only_queue_blocked
            or
            pending_approval_pipeline_blocker_active_from_metrics(metrics)
            or (
                approved_backlog > BACKLOG_DRAIN_SIGNAL_THRESHOLD
                and (
                    metrics.get("queue_starvation_detected") is True
                    or (approved_backlog > 0 and queued_tasks == 0 and running_tasks == 0)
                )
            )
        )
    ):
        return True

    registry_scope = normalize_text(metrics.get("registry_pressure_scope")).lower()
    local_registry_bytes = max(
        safe_int(
            metrics.get("local_registry_bytes")
            if metrics.get("local_registry_bytes") is not None
            else metrics.get("registry_bytes"),
            0,
        ),
        0,
    )
    return (
        title == "reduce registry pressure"
        and registry_scope != "cross_project"
        and local_registry_bytes >= EXTREME_TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
    )


def resolved_pending_self_improve_reason(task: dict[str, Any], metrics: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    if normalize_text(task.get("status")).lower() != "pending_approval":
        return ""
    if not is_active_self_improve_task(task):
        return ""

    if enforce_workspace_target_validation:
        title_key = normalize_improvement_title(task.get("title") or task_execution_text(task))
        if title_key:
            for seed in parse_project_spec_milestone_seeds(project):
                seed_title_key = normalize_improvement_title(seed.get("title") or "")
                inventory_title_key = f"inventory current decision path for {seed_title_key}" if seed_title_key else ""
                if seed_title_key not in {title_key, normalize_improvement_title(title_key)} and inventory_title_key != title_key:
                    continue
                done_markers = seed_string_list(seed.get("done_markers"))
                target_path = resolve_workspace_seed_file(seed.get("target_file"))
                if target_path is None or not done_markers:
                    continue
                try:
                    target_text = target_path.read_text(encoding="utf-8")
                except Exception:
                    continue
                normalized_target_text = normalize_text(target_text).lower()
                if all(normalize_text(marker).lower() in normalized_target_text for marker in done_markers):
                    resolved_path = target_path.relative_to(project_workspace).as_posix()
                    if inventory_title_key == title_key:
                        return (
                            "structured spec seed markers already present in "
                            f"{resolved_path}; bounded inventory fallback is obsolete"
                        )
                    return f"structured spec seed markers already present in {resolved_path}"

    title = normalize_text(task.get("title") or task.get("execution_task")).lower()

    if "improve retry failure classification coverage" in title:
        retry_classification_coverage = safe_float(metrics.get("retry_classification_coverage"))
        retry_classified_count = max(safe_int(metrics.get("retry_classified_count")), 0)
        retry_total_count = max(safe_int(metrics.get("retry_total_count")), 0)
        if retry_classification_coverage < RETRY_CLASSIFICATION_COVERAGE_THRESHOLD:
            return ""

        return (
            "retry classification coverage recovered to "
            f"{retry_classification_coverage:.0%} ({retry_classified_count}/{retry_total_count})"
        )

    if "improve timeout diagnostic coverage" in title:
        diagnostic_coverage = safe_float(metrics.get("diagnostic_coverage"))
        failures_with_diagnostic = max(safe_int(metrics.get("failures_with_diagnostic")), 0)
        total_failure_records = max(safe_int(metrics.get("total_failure_records")), 0)
        if diagnostic_coverage >= DIAGNOSTIC_COVERAGE_THRESHOLD:
            if total_failure_records > 0:
                return (
                    "timeout diagnostic coverage recovered to "
                    f"{diagnostic_coverage:.0%} ({failures_with_diagnostic}/{total_failure_records})"
                )
            return f"timeout diagnostic coverage recovered to {diagnostic_coverage:.0%}"

        zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
        if zero_step_timeout_rate < ZERO_STEP_TIMEOUT_ALERT_THRESHOLD:
            return f"zero-step timeout rate recovered to {zero_step_timeout_rate:.0%}"

        return ""

    if "reduce registry pressure" in title:
        registry_scope = normalize_text(metrics.get("registry_pressure_scope")).lower()
        local_registry_bytes = max(
            safe_int(
                metrics.get("local_registry_bytes")
                if metrics.get("local_registry_bytes") is not None
                else metrics.get("registry_bytes"),
                0,
            ),
            0,
        )
        shared_registry_bytes = max(
            safe_int(
                metrics.get("shared_registry_bytes")
                if metrics.get("shared_registry_bytes") is not None
                else metrics.get("registry_bytes"),
                0,
            ),
            0,
        )
        local_registry_kb = max(0, local_registry_bytes // 1024)
        threshold_kb = TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD // 1024

        if (
            registry_scope == "cross_project"
            and local_registry_bytes < TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
        ):
            return (
                "registry pressure is now cross-project only; "
                f"local registry is {local_registry_kb}KB (<{threshold_kb}KB)"
            )

        if (
            local_registry_bytes < TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
            and shared_registry_bytes < TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
        ):
            return (
                "local registry pressure recovered to "
                f"{local_registry_kb}KB (<{threshold_kb}KB)"
            )

        return ""

    if "refresh stale external signals" in title:
        signal_status = normalize_text(metrics.get("external_signal_status")).lower()
        fresh_signal_count = max(safe_int(metrics.get("fresh_external_signal_count")), 0)
        latest_signal_source = str(metrics.get("latest_external_signal_source") or "").strip()

        if signal_status == "fresh" or fresh_signal_count > 0:
            if fresh_signal_count > 0:
                signal_label = "signal" if fresh_signal_count == 1 else "signals"
                source_suffix = f" from {latest_signal_source}" if latest_signal_source else ""
                return (
                    f"external signals refreshed; {fresh_signal_count} fresh {signal_label}{source_suffix}"
                )
            return "external signals are fresh again"

        return ""

    if "improve first-pass success rate" in title:
        first_pass_success_rate = safe_float(metrics.get("first_pass_success_rate"))
        if first_pass_success_rate >= 0.50:
            return f"first-pass success rate recovered to {first_pass_success_rate:.0%}"
        return ""

    if improvement_title_key(title) == "drain approval backlog":
        approved_backlog = max(
            safe_int(
                metrics.get("approved_backlog")
                if metrics.get("approved_backlog") is not None
                else metrics.get("backlog"),
                0,
            ),
            0,
        )
        pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
        approval_backlog_total = max(
            approved_backlog,
            max(safe_int(metrics.get("backlog")), 0),
            approved_backlog + pending_approval_tasks,
        )
        queued_tasks = max(safe_int(metrics.get("queued_tasks")), 0)
        running_tasks = max(safe_int(metrics.get("running_tasks")), 0)
        pending_only_queue_blocked = (
            pending_approval_tasks > 0
            and queued_tasks == 0
            and running_tasks == 0
            and max(
                safe_int(
                    metrics.get("approved_tasks")
                    if metrics.get("approved_tasks") is not None
                    else metrics.get("approved_backlog"),
                    0,
                ),
                0,
            ) == 0
        )
        if pending_approval_pipeline_blocker_active_from_metrics(metrics) or pending_only_queue_blocked:
            return ""
        if approval_backlog_total <= BACKLOG_DRAIN_SIGNAL_THRESHOLD:
            backlog_label = "approval backlog" if pending_approval_tasks > 0 else "approved backlog"
            return (
                f"{backlog_label} recovered to "
                f"{approval_backlog_total} active approvals (<= {BACKLOG_DRAIN_SIGNAL_THRESHOLD})"
            )
        return ""

    if "recover stale pipeline" in title:
        if metrics.get("pipeline_stale") is not True:
            return "project-local pipeline activity resumed"
        return ""

    return ""


def obsolete_pending_self_improve_reason(task: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    if normalize_text(task.get("status")).lower() != "pending_approval":
        return ""
    if not is_active_self_improve_task(task):
        return ""

    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    candidate_texts = (
        task.get("title"),
        task.get("execution_task"),
        task_intent.get("objective"),
        task.get("reason"),
        task_intent.get("context_hint"),
    )
    if not any(contains_generic_repeated_failure_placeholder(value) for value in candidate_texts):
        return ""

    normalized_title = normalize_text(task.get("title") or task.get("execution_task")).lower()
    if "fix repeated failure:" not in normalized_title:
        return ""

    return "repeated-failure placeholder is a known non-actionable wrapper failure"


def invalid_external_pending_self_improve_reason(task: dict[str, Any]) -> str:
    if not enforce_workspace_target_validation:
        return ""
    if not isinstance(task, dict):
        return ""
    if normalize_text(task.get("status")).lower() != "pending_approval":
        return ""
    if not is_active_self_improve_task(task):
        return ""

    internal_title_keys = {
        "recover stale pipeline",
        "improve timeout diagnostic coverage",
        "cap pre-step planning budget",
        "improve retry failure classification coverage",
        "improve retry success rate",
        "improve first-pass success rate",
        "reduce timeout rate",
        "reduce registry pressure",
        "break retry churn",
        "reduce strategy saturation",
        "drain approval backlog",
        "refresh stale external signals",
    }
    title_key = improvement_title_key(task.get("title") or task.get("execution_task"))
    if not title_key:
        return ""
    if title_key.startswith("inventory current decision path for "):
        title_key = title_key.removeprefix("inventory current decision path for ").strip()

    if title_key not in internal_title_keys and not title_key.startswith("fix repeated failure:"):
        return ""

    return "external projects must not map control-plane self-improve weaknesses onto product work"


def zombie_pending_self_improve_reason(task: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    if normalize_text(task.get("status")).lower() != "pending_approval":
        return ""
    if not is_active_self_improve_task(task):
        return ""

    identity_key = project_title_identity_key(
        task.get("project") or task.get("target_project"),
        task.get("execution_task") or task.get("title"),
    )
    if identity_key not in zombie_blocklist:
        return ""

    failure_count = max(safe_int(zombie_failure_counts.get(identity_key)), ZOMBIE_FAILURE_THRESHOLD)
    return f"task family already failed {failure_count} times and is permanently blocked"


def task_sort_timestamp(task: dict[str, Any]) -> float:
    if not isinstance(task, dict):
        return float("-inf")
    for key in ("updated_at", "completed_at", "created_at"):
        raw_value = str(task.get(key) or "").strip()
        if not raw_value:
            continue
        try:
            return datetime.fromisoformat(raw_value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
    return float("-inf")


def zombie_shelved_self_improve_key(task: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    if normalize_text(task.get("status")).lower() != "shelved":
        return ""
    if not task_has_self_improve_signature(task):
        return ""

    title_key = improvement_title_key(task.get("title") or task.get("execution_task"))
    project_key = task_project_key(task)
    if not title_key or not project_key:
        return ""

    history = task.get("history") if isinstance(task.get("history"), list) else []
    latest_history_note = ""
    if history and isinstance(history[-1], dict):
        latest_history_note = normalize_text(history[-1].get("note")).lower()

    combined_reason = " ".join(
        value
        for value in (
            normalize_text(task.get("shelved_reason")).lower(),
            latest_history_note,
        )
        if value
    )
    if not any(
        marker in combined_reason
        for marker in (
            "zombie_guard",
            "zombie threshold",
            "already failed",
            "prior failures exceed threshold",
        )
    ):
        return ""
    return f"{project_key}::{title_key}"


def dedupe_zombie_shelved_self_improve_tasks(tasks_list: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int]:
    survivor_by_key: dict[str, tuple[int, dict[str, Any]]] = {}

    for index, task in enumerate(tasks_list):
        if not isinstance(task, dict):
            continue
        dedupe_key = zombie_shelved_self_improve_key(task)
        if not dedupe_key:
            continue
        current = survivor_by_key.get(dedupe_key)
        if current is None:
            survivor_by_key[dedupe_key] = (index, task)
            continue
        current_index, current_task = current
        candidate_rank = (task_sort_timestamp(task), index)
        current_rank = (task_sort_timestamp(current_task), current_index)
        if candidate_rank >= current_rank:
            survivor_by_key[dedupe_key] = (index, task)

    survivor_indices = {index for index, _task in survivor_by_key.values()}
    deduped_tasks: list[dict[str, Any]] = []
    removed_count = 0
    for index, task in enumerate(tasks_list):
        if not isinstance(task, dict):
            deduped_tasks.append(task)
            continue
        dedupe_key = zombie_shelved_self_improve_key(task)
        if dedupe_key and index not in survivor_indices:
            removed_count += 1
            continue
        deduped_tasks.append(task)
    return deduped_tasks, removed_count


def extract_self_improve_history_grounding(task: dict[str, Any]) -> tuple[list[str], str]:
    if not isinstance(task, dict):
        return [], ""

    supporting_files: list[str] = []
    anchor_hint = ""
    step_artifacts = task.get("step_artifacts") if isinstance(task.get("step_artifacts"), dict) else {}
    if isinstance(step_artifacts, dict):
        for artifact_key in sorted(step_artifacts):
            artifact = step_artifacts.get(artifact_key)
            if not isinstance(artifact, dict):
                continue
            identified_file, _ = normalize_target_files_for_project([artifact.get("identified_file")])
            if identified_file:
                if not anchor_hint:
                    anchor_hint = str(
                        artifact.get("edit_anchor")
                        or (artifact.get("location") if isinstance(artifact.get("location"), dict) else {}).get("context")
                        or artifact.get("reason")
                        or ""
                    ).strip()
                return identified_file[:1], anchor_hint

            if not anchor_hint:
                anchor_hint = str(
                    artifact.get("edit_anchor")
                    or (artifact.get("location") if isinstance(artifact.get("location"), dict) else {}).get("context")
                    or artifact.get("reason")
                    or ""
                ).strip()

            inspected = artifact.get("supporting_files_inspected")
            if isinstance(inspected, list):
                supporting_files.extend(str(item or "").strip() for item in inspected if str(item or "").strip())

    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    fallback_sources = [
        task.get("target_files") if isinstance(task.get("target_files"), list) else [],
        task_intent.get("affected_files") if isinstance(task_intent.get("affected_files"), list) else [],
        supporting_files,
    ]
    for source in fallback_sources:
        grounded_files, _ = normalize_target_files_for_project(source)
        if grounded_files:
            return grounded_files[:1], anchor_hint

    return [], anchor_hint


def infer_external_project_grounding(
    title: str,
    category: str,
    reason: str,
    raw_target_files: Any,
) -> tuple[list[str], str]:
    if not enforce_workspace_target_validation:
        return [], ""

    grounding_stopwords = {
        "and",
        "are",
        "after",
        "before",
        "from",
        "have",
        "into",
        "latest",
        "recent",
        "that",
        "the",
        "their",
        "them",
        "these",
        "this",
        "those",
        "through",
        "using",
        "with",
        "within",
    }

    def grounding_tokens(value: Any) -> set[str]:
        return {
            token
            for token in re.findall(r"[a-z0-9_/-]+", normalize_text(value).lower())
            if len(token) >= 3
            and token not in grounding_stopwords
        }

    def build_grounding_prefix(grounded_files: list[str], anchor_hint: str) -> str:
        if not grounded_files:
            return ""
        file_hint = grounded_files[0]
        if anchor_hint:
            return f"Start with `{file_hint}` at {anchor_hint}."
        return f"Start with `{file_hint}`."

    raw_target_context = " ".join(
        str(item or "").strip()
        for item in (raw_target_files if isinstance(raw_target_files, list) else [])
        if str(item or "").strip()
    )
    query_tokens = grounding_tokens("\n".join([title, reason, raw_target_context]))
    target_title_key = improvement_title_key(title)
    normalized_category = normalize_text(category).lower()
    terminal_status_rank = {"failed": 3, "rejected": 2, "completed": 1, "shelved": 0}
    product_surface_files = external_project_product_files()
    workspace_has_product_surfaces = bool(product_surface_files)
    best_candidate: dict[str, Any] | None = None

    def select_product_fallback() -> tuple[list[str], str]:
        if not workspace_has_product_surfaces:
            return [], ""

        best_history_candidate: dict[str, Any] | None = None
        for task in tasks:
            if not isinstance(task, dict):
                continue
            if task_project_key(task) != project:
                continue

            status = normalize_text(task.get("status")).lower()
            if status not in {"completed", "failed", "rejected", "shelved"}:
                continue

            grounded_files, anchor_hint = extract_self_improve_history_grounding(task)
            if not grounded_files:
                continue
            file_hint = grounded_files[0]
            if not is_external_project_product_file(file_hint):
                continue

            corpus = "\n".join(
                value
                for value in (
                    *task_text_candidates(task),
                    str(task.get("reason") or ""),
                    str((task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else ""),
                    anchor_hint,
                    file_hint,
                )
                if value
            )
            overlap = len(query_tokens & grounding_tokens(corpus))
            ranking = (
                1 if not task_has_self_improve_signature(task) else 0,
                1 if status == "completed" else 0,
                overlap,
                external_project_category_affinity(file_hint, normalized_category),
                external_project_file_priority(file_hint),
                task_sort_timestamp(task),
                str(task.get("id") or ""),
            )
            if best_history_candidate is None or ranking > best_history_candidate["ranking"]:
                best_history_candidate = {
                    "ranking": ranking,
                    "files": grounded_files[:1],
                    "anchor_hint": anchor_hint,
                }

        if best_history_candidate is not None:
            grounded_files = best_history_candidate["files"]
            return grounded_files, build_grounding_prefix(grounded_files, best_history_candidate["anchor_hint"])

        best_workspace_candidate: dict[str, Any] | None = None
        for file_hint in product_surface_files:
            ranking = (
                len(query_tokens & grounding_tokens(file_hint)),
                external_project_category_affinity(file_hint, normalized_category),
                external_project_file_priority(file_hint),
                file_hint,
            )
            if best_workspace_candidate is None or ranking > best_workspace_candidate["ranking"]:
                best_workspace_candidate = {
                    "ranking": ranking,
                    "files": [file_hint],
                }

        if best_workspace_candidate is None:
            return [], ""

        grounded_files = best_workspace_candidate["files"]
        return grounded_files, build_grounding_prefix(grounded_files, "")

    for task in tasks:
        if not isinstance(task, dict):
            continue
        if task_project_key(task) != project:
            continue

        status = normalize_text(task.get("status")).lower()
        if status not in terminal_status_rank:
            continue

        grounded_files, anchor_hint = extract_self_improve_history_grounding(task)
        if not grounded_files:
            continue
        file_hint = grounded_files[0]
        candidate_is_product = 1 if is_external_project_product_file(file_hint) else 0

        candidate_title_key = improvement_title_key(task.get("title") or task.get("execution_task") or "")
        same_title = 1 if target_title_key and candidate_title_key == target_title_key else 0
        same_category = 1 if normalized_category and normalize_text(task.get("category")).lower() == normalized_category else 0
        corpus = "\n".join(
            value
            for value in (
                *task_text_candidates(task),
                str(task.get("reason") or ""),
                str((task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else ""),
                anchor_hint,
                file_hint,
            )
            if value
        )
        overlap = len(query_tokens & grounding_tokens(corpus))
        semantic_match = (
            same_title == 1
            or (same_category == 1 and overlap >= 1)
            or overlap >= 2
        )
        if not semantic_match:
            continue

        ranking = (
            candidate_is_product if workspace_has_product_surfaces else 0,
            same_title,
            same_category,
            overlap,
            1 if not task_has_self_improve_signature(task) else 0,
            terminal_status_rank.get(status, 0),
            task_sort_timestamp(task),
            str(task.get("id") or ""),
        )
        if best_candidate is None or ranking > best_candidate["ranking"]:
            best_candidate = {
                "ranking": ranking,
                "files": grounded_files[:1],
                "anchor_hint": anchor_hint,
            }

    fallback_files, fallback_prefix = select_product_fallback()
    if fallback_files:
        if best_candidate is None:
            return fallback_files, fallback_prefix
        current_files = best_candidate.get("files") if isinstance(best_candidate.get("files"), list) else []
        current_file_hint = current_files[0] if current_files else ""
        if workspace_has_product_surfaces and is_external_project_meta_file(current_file_hint):
            return fallback_files, fallback_prefix

    if best_candidate is None:
        return [], ""

    grounded_files = best_candidate["files"]
    anchor_hint = normalize_text(best_candidate.get("anchor_hint"))
    if grounded_files:
        return grounded_files, build_grounding_prefix(grounded_files, anchor_hint)
    return [], ""


def superseded_pending_self_improve_reason(task: dict[str, Any], metrics: dict[str, Any]) -> str:
    if not isinstance(task, dict):
        return ""
    if normalize_text(task.get("status")).lower() != "pending_approval":
        return ""
    if not is_active_self_improve_task(task):
        return ""

    normalized_title = normalize_text(task.get("title") or task.get("execution_task")).lower()
    if normalized_title != "reduce timeout rate":
        return ""

    zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
    if zero_step_timeout_rate < ZERO_STEP_TIMEOUT_EMERGENCY_THRESHOLD:
        return ""

    planning_budget_title = "Cap pre-step planning budget"
    if has_active_self_improve_title(
        planning_budget_title,
        exclude_task_id=str(task.get("id") or ""),
    ):
        return (
            "narrower `Cap pre-step planning budget` task is already active for the "
            "same zero-step timeout emergency"
        )

    if has_recent_successful_self_improve_title(
        planning_budget_title,
        exclude_task_id=str(task.get("id") or ""),
    ):
        return (
            "recent successful `Cap pre-step planning budget` remediation should absorb "
            "the same zero-step timeout emergency until metrics refresh"
        )

    return ""


def infer_category(text: str) -> str:
    lowered = normalize_text(text).lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll", "iphone", "ipad", "tablet")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane", "orchestrator")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for inferred_category, keywords in categories:
        if any(keyword in lowered for keyword in keywords):
            return inferred_category
    return "general"


def select_provider_for_improvement(
    title: str,
    category: str,
    reason: str,
    target_files: list[str],
) -> tuple[str, dict[str, Any]]:
    combined = " ".join(
        value
        for value in (
            normalize_text(title),
            normalize_text(category),
            normalize_text(reason),
            " ".join(normalize_text(path) for path in target_files if normalize_text(path)),
        )
        if value
    )
    inferred_category = infer_category(combined)

    try:
        routing_payload = json.loads(routing_path.read_text(encoding="utf-8"))
    except Exception:
        routing_payload = {}
    rules = routing_payload.get("rules") if isinstance(routing_payload, dict) else []
    if isinstance(rules, list):
        for rule in rules:
            if not isinstance(rule, dict) or rule.get("enabled") is not True:
                continue
            if normalize_text(rule.get("category")).lower() != inferred_category:
                continue
            provider = normalize_provider(rule.get("provider"))
            if not provider:
                continue
            routing_reason = normalize_text(rule.get("reason")) or (
                f"Learned routing selected {provider} for inferred category '{inferred_category}'."
            )
            return provider, {
                "selected": provider,
                "source": "routing_rule",
                "reason": (
                    f"Learned routing selected {provider} for inferred category '{inferred_category}': "
                    f"{routing_reason}"
                ),
                "updated_at": transition_at,
            }

    try:
        stats_payload = json.loads(stats_path.read_text(encoding="utf-8"))
    except Exception:
        stats_payload = {}
    candidates: list[tuple[str, float, int, float]] = []
    if isinstance(stats_payload, dict):
        for provider_name, categories_map in stats_payload.items():
            if not isinstance(categories_map, dict):
                continue
            entry = categories_map.get(inferred_category)
            if not isinstance(entry, dict):
                continue
            provider = normalize_provider(provider_name)
            if not provider:
                continue
            try:
                task_count = int(entry.get("task_count", 0) or 0)
                success_rate = float(entry.get("success_rate", 0.0) or 0.0)
                avg_total_step_attempts = float(entry.get("avg_total_step_attempts", entry.get("avg_attempts", 0.0)) or 0.0)
            except (TypeError, ValueError):
                continue
            if task_count >= 3:
                candidates.append((provider, success_rate, task_count, avg_total_step_attempts))

    if candidates:
        candidates.sort(key=lambda item: (-item[1], -item[2], item[3], item[0]))
        provider, success_rate, task_count, avg_total_step_attempts = candidates[0]
        return provider, {
            "selected": provider,
            "source": "learned",
            "reason": (
                f"Learned provider stats selected {provider} for inferred category '{inferred_category}' "
                f"({success_rate:.0%} success over {task_count} tasks, {avg_total_step_attempts:.2f} avg total step attempts)."
            ),
            "updated_at": transition_at,
        }

    return "codex", {
        "selected": "codex",
        "source": "default",
        "reason": f"Default provider is Codex when no learned routing rule is available for inferred category '{inferred_category}'.",
        "updated_at": transition_at,
    }


project = normalize_project(project_name)
submitted = 0
skipped_low_signal = 0
skipped_invalid_target_files = 0
submitted_titles: list[str] = []
retired_resolved_pending_tasks = 0
retired_obsolete_pending_tasks = 0
retired_no_gain_completed_tasks = 0
kept_metric_improved_completed_tasks = 0
for index, task in enumerate(tasks):
    if task_project_key(task) != project:
        continue
    repaired_task, changed = repair_active_self_improve_metadata(task, metrics_snap)
    if not changed:
        continue
    tasks[index] = repaired_task
    registry_changed = True

for index, task in enumerate(tasks):
    if task_project_key(task) != project:
        continue
    evaluated_task, changed, outcome = completed_self_improve_metric_outcome(task, metrics_snap)
    if not changed:
        continue
    tasks[index] = evaluated_task
    registry_changed = True
    if outcome == "discarded":
        retired_no_gain_completed_tasks += 1
    elif outcome == "kept":
        kept_metric_improved_completed_tasks += 1

for index, task in enumerate(tasks):
    if task_project_key(task) != project:
        continue
    resolved_reason = resolved_pending_self_improve_reason(task, metrics_snap)
    obsolete_reason = obsolete_pending_self_improve_reason(task)
    invalid_external_reason = invalid_external_pending_self_improve_reason(task)
    zombie_reason = zombie_pending_self_improve_reason(task)
    superseded_reason = superseded_pending_self_improve_reason(task, metrics_snap)
    if not resolved_reason and not obsolete_reason and not invalid_external_reason and not zombie_reason and not superseded_reason:
        continue
    retirement_reason = resolved_reason or obsolete_reason or invalid_external_reason or zombie_reason or superseded_reason
    transition_at = now_utc()
    repaired_task = dict(task)
    repaired_task["status"] = "shelved"
    repaired_task["updated_at"] = transition_at
    repaired_task["shelved_reason"] = f"auto-shelved: {retirement_reason}"
    note = (
        "Task was automatically retired because the triggering metric signal "
        f"is already back within threshold: {retirement_reason}."
    )
    if obsolete_reason:
        note = (
            "Task was automatically retired because it matches a generic repeated-failure placeholder "
            f"with no actionable root cause: {retirement_reason}."
        )
    elif invalid_external_reason:
        note = (
            "Task was automatically retired because external projects must not rewrite control-plane "
            f"self-improve weaknesses into product-facing work: {retirement_reason}."
        )
    elif zombie_reason:
        note = (
            "Task was automatically retired because this self-improve family already crossed "
            f"the zombie threshold: {retirement_reason}."
        )
    elif superseded_reason:
        note = (
            "Task was automatically retired because a narrower active self-improve task already covers "
            f"the same zero-step timeout emergency: {retirement_reason}."
        )
    repaired_task["history"] = append_history_entry(
        repaired_task,
        {
            "at": transition_at,
            "action": "auto_shelve",
            "from_status": "pending_approval",
            "to_status": "shelved",
            "project": project,
            "queue_task": str(repaired_task.get("execution_task") or repaired_task.get("title") or "").strip(),
            "note": note,
        },
    )
    tasks[index] = repaired_task
    if obsolete_reason:
        retired_obsolete_pending_tasks += 1
    else:
        retired_resolved_pending_tasks += 1

if retired_resolved_pending_tasks > 0 or retired_obsolete_pending_tasks > 0:
    registry_changed = True

tasks, deduped_zombie_shelved_tasks = dedupe_zombie_shelved_self_improve_tasks(tasks)
if deduped_zombie_shelved_tasks > 0:
    registry_changed = True

active_self_improve_count = sum(
    1
    for task in tasks
    if task_project_key(task) == project
    and is_active_self_improve_task(task)
)
backlog_bypass_active = any(
    improvement_has_backlog_bypass(item, metrics_snap)
    for item in improvements
)

# Keep the autonomous improvement queue focused on the work already awaiting
# approval/execution instead of continually seeding adjacent experiments.
if active_self_improve_count >= ACTIVE_SELF_IMPROVE_CAP and not backlog_bypass_active:
    MAX_SUBMIT = 0
    submission_limit_reason = "active_self_improve_backlog"

if not improvements:
    if registry_changed:
        registry_payload = {"tasks": tasks}
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w", delete=False, dir=registry_path.parent, encoding="utf-8"
        ) as f:
            json.dump(registry_payload, f, indent=2)
            f.write("\n")
            temp_path = f.name
        os.replace(temp_path, str(registry_path))
    print(json.dumps({
        "submitted": 0,
        "submitted_titles": [],
        "total": 0,
        "skipped": 0,
        "max_submit": 0,
        "active_self_improve_count": active_self_improve_count,
        "active_self_improve_cap": ACTIVE_SELF_IMPROVE_CAP,
        "backlog_bypass_active": backlog_bypass_active,
        "dominant_gating_reason": "none",
        "submission_limit_reason": "none",
        "retired_resolved_pending_tasks": retired_resolved_pending_tasks,
        "retired_obsolete_pending_tasks": retired_obsolete_pending_tasks,
        "retired_no_gain_completed_tasks": retired_no_gain_completed_tasks,
        "kept_metric_improved_completed_tasks": kept_metric_improved_completed_tasks,
        "deduped_zombie_shelved_tasks": deduped_zombie_shelved_tasks,
        "message": "No improvements to submit",
    }))
    raise SystemExit(0)

for imp in improvements:
    if submitted >= MAX_SUBMIT:
        break
    title = imp.get("title", "")
    if not title:
        continue
    reason = imp.get("reason", "")
    if low_signal_self_improve_candidate(title, reason):
        skipped_low_signal += 1
        continue

    # Submission-time dedupe should only block live backlog collisions.
    # Generator-side title-family cooldown already handles stale terminal
    # self-improve families, so exact-title terminal records must not suppress
    # a fresh recurrence after the cooldown expires.
    normalized_candidate = normalize_text(title).lower()
    should_skip_submission = False
    for existing_task in tasks:
        if not isinstance(existing_task, dict):
            continue
        if task_project_key(existing_task) != project:
            continue
        existing_title = normalize_text(
            existing_task.get("title") or existing_task.get("execution_task") or ""
        ).lower()
        if existing_title == normalized_candidate:
            existing_status = normalize_text(existing_task.get("status")).lower()
            if existing_status in ACTIVE_SELF_IMPROVE_STATUSES:
                should_skip_submission = True
                break
            if not task_has_self_improve_signature(existing_task):
                should_skip_submission = True
                break
    if should_skip_submission:
        continue
    # --- end v28 dedup guard ---

    category = imp.get("category", "general")
    priority = imp.get("priority", "medium")
    raw_target_files = imp.get("target_files", []) if isinstance(imp.get("target_files"), list) else []
    target_files_list, invalid_target_files = normalize_target_files_for_project(raw_target_files)
    grounding_prefix = ""
    grounded_target_files: list[str] = []
    if enforce_workspace_target_validation and invalid_target_files:
        grounded_target_files, grounding_prefix = infer_external_project_grounding(
            title,
            category,
            reason,
            raw_target_files,
        )
        if grounded_target_files:
            target_files_list = grounded_target_files
            invalid_target_files = []
    if enforce_workspace_target_validation and not target_files_list:
        target_files_list, grounding_prefix = grounded_target_files, grounding_prefix
        if not target_files_list:
            target_files_list, grounding_prefix = infer_external_project_grounding(
                title,
                category,
                reason,
                raw_target_files,
            )
        invalid_target_files = []
    if enforce_workspace_target_validation and not target_files_list:
        skipped_invalid_target_files += 1
        continue
    if grounding_prefix:
        normalized_prefix = normalize_text(grounding_prefix).lower()
        normalized_reason = normalize_text(reason).lower()
        reason = (
            grounding_prefix
            if not reason
            else reason
            if normalized_prefix and normalized_prefix in normalized_reason
            else f"{grounding_prefix} {reason}"
        )
    strategy_template = normalize_text(imp.get("strategy_template")).lower()
    if strategy_template not in {"bounded_learning_inventory"}:
        strategy_template = "self_improvement"

    transition_at = now_utc()
    task_id = next_task_id(tasks, title)
    impact = safe_int(imp.get("impact"), 7 if priority == "critical" else 6 if priority == "high" else 4)
    effort = max(1, safe_int(imp.get("effort"), 2 if strategy_template == "bounded_learning_inventory" else 3))
    confidence = safe_float(imp.get("confidence"), 0.82 if strategy_template == "bounded_learning_inventory" else 0.7)

    task_text = f"[self-improve:{priority}] {title}"
    if reason:
        task_text += f" -- {reason}"
    if target_files_list:
        task_text += f" (files: {', '.join(target_files_list)})"

    selected_provider, provider_selection = select_provider_for_improvement(
        title,
        category,
        reason,
        target_files_list if isinstance(target_files_list, list) else [],
    )
    playbook_metadata = select_self_improve_playbook_metadata(
        title,
        reason,
        target_files_list if isinstance(target_files_list, list) else [],
    )
    verification_command = str(imp.get("verification_command") or "").strip()
    success_signals = [
        str(item).strip()
        for item in (imp.get("success_signals") if isinstance(imp.get("success_signals"), list) else [])
        if str(item).strip()
    ]
    metric_task, metric_changed = apply_self_improve_metric_baseline(
        {},
        title,
        metrics_snap,
    )

    new_task: dict[str, Any] = {
        "id": task_id,
        "title": title,
        "execution_task": task_text,
        "impact": impact,
        "effort": effort,
        "confidence": confidence,
        "category": category,
        "project": project,
        "reason": reason,
        "score": round(impact * confidence, 2),
        "execution_provider": selected_provider,
        "provider_selection": provider_selection,
        "status": "pending_approval",
        "task_intent": {
            "source": "self-improve",
            "objective": title,
            "project": project,
            "category": category,
            "context_hint": reason[:200] if reason else "",
            "affected_files": [
                str(path).strip()
                for path in target_files_list[:3]
                if str(path).strip()
            ],
            "success_signals": success_signals,
        },
        "source_task_id": "self-improve",
        "root_source_task_id": "self-improve",
        "related_source_task_ids": ["self-improve"],
        "strategy_template": strategy_template,
        "strategy_depth": 0,
        "created_at": transition_at,
        "updated_at": transition_at,
        "execution": {
            "state": "pending_approval",
            "attempt": 0,
            "max_retries": default_max_retries,
            "provider": selected_provider,
            "updated_at": transition_at,
        },
        "history": [
            {
                "at": transition_at,
                "action": "create",
                "from_status": "",
                "to_status": "pending_approval",
                "project": project,
                "queue_task": task_text,
                "note": f"Auto-generated by self-improve engine. Priority: {priority}.",
            }
        ],
    }
    if metric_changed:
        new_task.update(metric_task)
    if playbook_metadata:
        new_task["task_family"] = playbook_metadata["family"]
        new_task["strategy_playbook"] = playbook_metadata["playbook"]
        new_task["task_shape"] = {
            "family": playbook_metadata["family"],
            "playbook": playbook_metadata["playbook"],
        }
    if verification_command:
        task_shape = new_task.get("task_shape") if isinstance(new_task.get("task_shape"), dict) else {}
        task_shape["verification_command"] = verification_command
        new_task["task_shape"] = task_shape
    if strategy_template == "bounded_learning_inventory":
        new_task["hypothesis"] = str(imp.get("hypothesis") or "").strip()
        new_task["experiment"] = str(imp.get("experiment") or "").strip()
        success_criteria = imp.get("success_criteria")
        if isinstance(success_criteria, list):
            new_task["success_criteria"] = [
                str(item).strip()
                for item in success_criteria
                if str(item).strip()
            ]
        rollback = str(imp.get("rollback") or "").strip()
        if rollback:
            new_task["rollback"] = rollback
    if target_files_list:
        new_task["target_files"] = target_files_list

    tasks.append(new_task)
    submitted += 1
    submitted_titles.append(title)
    registry_changed = True

# Write updated registry atomically
if registry_changed:
    registry_payload = {"tasks": tasks}
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", delete=False, dir=registry_path.parent, encoding="utf-8"
    ) as f:
        json.dump(registry_payload, f, indent=2)
        f.write("\n")
        temp_path = f.name
    os.replace(temp_path, str(registry_path))

# Log the run
improvement_log_path.parent.mkdir(parents=True, exist_ok=True)
metrics_snap = improvements_json.get("data", {}).get("metrics_snapshot", {})
with open(improvement_log_path, "a", encoding="utf-8") as log:
    log.write("---\n")
    log.write(f"timestamp: {now_utc()}\n")
    log.write(f"submitted: {submitted}\n")
    log.write(f"total_suggestions: {len(improvements)}\n")
    for k, v in metrics_snap.items():
        log.write(f"  {k}: {v}\n")
    log.write("\n")

skipped = max(0, len(improvements) - submitted)
resulting_active_self_improve_count = sum(
    1
    for task in tasks
    if task_project_key(task) == project
    and is_active_self_improve_task(task)
)
print(json.dumps({
    "submitted": submitted,
    "submitted_titles": submitted_titles,
    "total": len(improvements),
    "skipped": skipped,
    "skipped_low_signal": skipped_low_signal,
    "skipped_invalid_target_files": skipped_invalid_target_files,
    "max_submit": MAX_SUBMIT,
    "active_self_improve_count": active_self_improve_count,
    "resulting_active_self_improve_count": resulting_active_self_improve_count,
    "active_self_improve_cap": ACTIVE_SELF_IMPROVE_CAP,
    "backlog_bypass_active": backlog_bypass_active,
    "retired_resolved_pending_tasks": retired_resolved_pending_tasks,
    "retired_obsolete_pending_tasks": retired_obsolete_pending_tasks,
    "retired_no_gain_completed_tasks": retired_no_gain_completed_tasks,
    "kept_metric_improved_completed_tasks": kept_metric_improved_completed_tasks,
    "deduped_zombie_shelved_tasks": deduped_zombie_shelved_tasks,
    "dominant_gating_reason": (
        "missing_source_file"
        if skipped_invalid_target_files > 0 and submitted == 0
        else "low_signal_submission_filter"
        if skipped_low_signal > 0 and submitted == 0
        else "submission_limit" if skipped > 0 else "none"
    ),
    "submission_limit_reason": submission_limit_reason,
}))
PYSUBMIT
)" || true

  rm -f "$tmp_improvements" 2>/dev/null || true

  if [ -n "$result" ]; then
    local sub_count
    sub_count="$(printf '%s' "$result" | jq -r '(.submitted // 0)' 2>/dev/null || printf '0')"
    local total_count
    total_count="$(printf '%s' "$result" | jq -r '(.total // 0)' 2>/dev/null || printf '0')"
    log_msg INFO self-improve "Registered $sub_count of $total_count improvement tasks in registry as pending_approval"
  else
    log_msg WARN self-improve "Failed to register improvement tasks in registry"
  fi

  printf '%s' "$result"
}

# ─── CLI Health Check ───
# Detect common provider configuration issues before they cause task failures

check_provider_health() {
  local issues_found=0

  # Check codex CLI availability and flags
  if command -v codex >/dev/null 2>&1; then
    local approval_flag
    approval_flag="$(codex_approval_mode 2>/dev/null || true)"
    case "$approval_flag" in
      untrusted|on-failure|on-request|never) ;;
      *)
        log_msg ERROR self-improve "Invalid codex approval flag '-a $approval_flag' from lib.sh helper. Valid: untrusted, on-failure, on-request, never"
        issues_found=$((issues_found + 1))
        ;;
    esac
  else
    log_msg WARN self-improve "codex CLI not available — all codex provider tasks will use fallback"
  fi

  # Check claude CLI availability
  if ! command -v claude >/dev/null 2>&1; then
    log_msg WARN self-improve "claude CLI not available — all claude provider tasks will use fallback"
  fi

  # Check for repeated identical failures in recent logs (same error > 5 times)
  if [ -f "$LOG_DIR/system.log" ]; then
    local repeated_error
    local recent_health_window
    recent_health_window="$(safe_tail_structured_logs "${SELF_IMPROVE_PROVIDER_HEALTH_LOG_WINDOW_LINES:-400}" "$LOG_DIR/system.log")"
    repeated_error="$(
      printf '%s\n' "$recent_health_window" \
        | grep -o 'codex exec failed\|claude print failed or produced no output\|invalid value\|TIMEOUT after' 2>/dev/null \
        | sort | uniq -c | sort -rn | head -1 || true
    )"
    if [ -n "$repeated_error" ]; then
      local count
      count="$(printf '%s' "$repeated_error" | awk '{print $1}' || true)"
      if [ "${count:-0}" -gt 10 ]; then
        log_msg WARN self-improve "Repeated error pattern detected ($count times): $(printf '%s' "$repeated_error" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
        issues_found=$((issues_found + 1))
      fi
    fi
  fi

  return "$issues_found"
}

# Refresh the persisted metrics snapshot from the current registry/task log before
# generating new self-improve tasks so decisions do not depend on stale metrics.json fields.
metrics_refresh_required() {
  local snapshot_status
  snapshot_status="$(inspect_metrics_snapshot)"
  local complete_flag
  complete_flag="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
  if [ "$complete_flag" = "true" ]; then
    return 1
  fi
  return 0
}

inspect_metrics_snapshot() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'false\tfalse\tpython3_unavailable\t\n'
    return 0
  fi

python3 - "$METRICS_FILE" "$REGISTRY_FILE" "$TASK_LOG" "$EXTERNAL_SIGNALS_FILE" <<'PY'
from __future__ import annotations

import json
import math
import os
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

metrics_path = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3])
external_signals_path = Path(sys.argv[4])
DEFAULT_EXTERNAL_SIGNAL_FRESHNESS_WINDOW_SECONDS = 604800
required_keys = (
    "success_rate",
    "timeout_failure_rate",
    "first_pass_success_rate",
    "approved_tasks",
    "pending_approval_tasks",
    # Self-improve and operator paths still consume these compatibility aliases.
    "approved_backlog",
    "task_registry_pressure_bytes",
    "strategy_saturation",
    "self_improve_paused",
    "self_improve_pause_escalated",
    "self_improve_pause_age_seconds",
)
bounded_rate_keys = (
    "success_rate",
    "recent_success_rate",
    "timeout_failure_rate",
    "first_pass_success_rate",
    "retry_classification_coverage",
    "zero_step_timeout_rate",
)


def normalize_project_name(value: object) -> str:
    text = str(value or "").strip()
    return text or "codex-agent-system"


def safe_int(value: object, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def parse_timestamp(value: object) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def external_signal_now() -> datetime:
    override = parse_timestamp(os.environ.get("CODEX_EXTERNAL_SIGNAL_NOW"))
    if override is not None:
        return override
    return datetime.now(timezone.utc)


def external_signal_is_fresh(signal: dict, snapshot: dict | None = None, now: datetime | None = None) -> bool:
    if not isinstance(signal, dict):
        return False
    reference = parse_timestamp(signal.get("published_at") or signal.get("fetched_at"))
    if reference is None:
        return signal.get("fresh") is True
    raw_window = signal.get("freshness_window_seconds")
    if raw_window is None and isinstance(snapshot, dict):
        raw_window = snapshot.get("freshness_window_seconds")
    freshness_window_seconds = max(
        60,
        safe_int(raw_window, DEFAULT_EXTERNAL_SIGNAL_FRESHNESS_WINDOW_SECONDS),
    )
    current = now or external_signal_now()
    age_seconds = max(int((current - reference).total_seconds()), 0)
    return age_seconds <= freshness_window_seconds


def build_external_signal_summary(snapshot: dict | None) -> dict[str, int | str]:
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    signals = [entry for entry in snapshot.get("signals", []) if isinstance(entry, dict)]
    errors = [entry for entry in snapshot.get("errors", []) if isinstance(entry, (dict, str))]
    now = external_signal_now()
    fresh_signal_count = sum(1 for signal in signals if external_signal_is_fresh(signal, snapshot, now))
    if errors:
        status = "error"
    elif fresh_signal_count > 0:
        status = "fresh"
    elif signals:
        status = "stale"
    elif str(snapshot.get("updated_at") or "").strip():
        status = "empty"
    else:
        status = "unavailable"
    return {
        "status": status,
        "fresh_signal_count": fresh_signal_count,
    }


def discover_registry_targets(primary_registry_path: Path) -> list[dict[str, str]]:
    primary_path = primary_registry_path.resolve()
    repo_root = primary_path.parent.parent
    projects_dir = repo_root / "projects"

    registry_targets: list[dict[str, str]] = []
    seen: set[str] = set()

    def append_target(project: object, candidate: Path) -> None:
        resolved = str(candidate.resolve())
        if resolved in seen:
            return
        seen.add(resolved)
        registry_targets.append(
            {
                "project": normalize_project_name(project),
                "resolved_path": resolved,
            }
        )

    if projects_dir.is_dir():
        for entry in sorted(projects_dir.iterdir(), key=lambda item: item.name):
            if not entry.is_dir():
                continue
            metadata_path = entry / "project.json"
            try:
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            except Exception:
                metadata = {}
            if not isinstance(metadata, dict):
                metadata = {}
            registry_candidate = Path(str(metadata.get("task_registry_file") or "").strip() or str(primary_path))
            project_name = metadata.get("project") or metadata.get("project_id") or entry.name
            append_target(project_name, registry_candidate)

    append_target("codex-agent-system", primary_path)
    return registry_targets

def emit(exists: bool, complete: bool, reason: str, missing_keys: tuple[str, ...] | list[str]) -> None:
    print(
        "\t".join(
            (
                "true" if exists else "false",
                "true" if complete else "false",
                reason,
                ",".join(missing_keys),
            )
        )
    )

if not metrics_path.exists():
    emit(False, False, "metrics_file_missing", required_keys)
    raise SystemExit(0)

try:
    payload = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    emit(True, False, "invalid_json", required_keys)
    raise SystemExit(0)

if not isinstance(payload, dict):
    emit(True, False, "invalid_payload", required_keys)
    raise SystemExit(0)

missing_keys = []
for key in required_keys:
    value = payload.get(key)
    if value is None:
        missing_keys.append(key)
        continue
    if isinstance(value, str) and not value.strip():
        missing_keys.append(key)

if missing_keys:
    emit(True, False, "missing_required_keys", missing_keys)
else:
    invalid_bounded_key = ""
    for key in bounded_rate_keys:
        if key not in payload:
            continue
        value = payload.get(key)
        if value is None or (isinstance(value, str) and not value.strip()):
            continue
        try:
            numeric = float(value)
        except (TypeError, ValueError):
            invalid_bounded_key = key
            break
        if not math.isfinite(numeric) or numeric < 0 or numeric > 1:
            invalid_bounded_key = key
            break

    if invalid_bounded_key:
        emit(True, False, f"invalid_bounded_metric_{invalid_bounded_key}", [])
        raise SystemExit(0)

    def registry_source_mismatch_keys(snapshot: dict) -> list[str]:
        mismatches: list[str] = []
        shared_registry_bytes = safe_int(
            snapshot.get("shared_registry_bytes", snapshot.get("task_registry_pressure_bytes"))
        )
        if (
            snapshot.get("task_registry_pressure_bytes") is not None
            and shared_registry_bytes != safe_int(snapshot.get("task_registry_pressure_bytes"))
        ):
            mismatches.append("shared_registry_bytes")

        local_source = snapshot.get("registry_pressure_local_source")
        if isinstance(local_source, dict):
            local_payload_bytes = max(safe_int(local_source.get("payload_bytes"), -1), -1)
            if local_payload_bytes >= 0 and snapshot.get("local_registry_bytes") is not None:
                if safe_int(snapshot.get("local_registry_bytes")) != local_payload_bytes:
                    mismatches.append("local_registry_bytes")
        return mismatches

    registry_source_mismatches = registry_source_mismatch_keys(payload)
    if registry_source_mismatches:
        emit(True, False, "registry_source_mismatch", registry_source_mismatches)
        raise SystemExit(0)

    registry_mismatch_keys = []
    if registry_path.exists():
        status_counts: Counter[str] = Counter()
        primary_status_counts: Counter[str] = Counter()
        total_tasks = 0
        primary_registry_resolved = registry_path.resolve()
        for target in discover_registry_targets(registry_path):
            target_path = Path(target["resolved_path"])
            try:
                registry_payload = json.loads(target_path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(registry_payload, dict):
                continue
            tasks = registry_payload.get("tasks")
            if not isinstance(tasks, list):
                continue
            total_tasks += len(tasks)
            task_statuses = [
                str(task.get("status") or "").strip().lower()
                for task in tasks
                if isinstance(task, dict)
            ]
            status_counts.update(task_statuses)
            if target_path == primary_registry_resolved:
                primary_status_counts.update(task_statuses)

        expected_counts = {
            "approved_tasks": primary_status_counts.get("approved", 0),
            "pending_approval_tasks": status_counts.get("pending_approval", 0),
            "approved_backlog": primary_status_counts.get("approved", 0),
            "queued_tasks": status_counts.get("queued", 0),
            "running_tasks": status_counts.get("running", 0),
            "task_registry_total": total_tasks,
        }
        if "approved_tasks_cross_project" in payload:
            expected_counts["approved_tasks_cross_project"] = max(
                status_counts.get("approved", 0) - primary_status_counts.get("approved", 0),
                0,
            )
        for key, expected_value in expected_counts.items():
            value = payload.get(key)
            if value is None or (isinstance(value, str) and not value.strip()):
                continue
            try:
                numeric = int(value)
            except (TypeError, ValueError):
                emit(True, False, f"invalid_registry_count_{key}", [])
                raise SystemExit(0)
            if numeric != expected_value:
                registry_mismatch_keys.append(key)

    if registry_mismatch_keys:
        emit(True, False, "registry_count_mismatch", registry_mismatch_keys)
        raise SystemExit(0)

    try:
        metrics_mtime = metrics_path.stat().st_mtime
    except OSError:
        emit(True, False, "metrics_stat_failed", [])
        raise SystemExit(0)

    freshness_inputs = (
        ("tasks_json", registry_path),
        ("tasks_log", task_log_path),
        ("external_signals", external_signals_path),
    )
    stale_sources = []
    for label, candidate in freshness_inputs:
        if not candidate.exists():
            continue
        try:
            candidate_stat = candidate.stat()
        except OSError:
            continue
        if candidate_stat.st_size <= 0:
            continue
        if label == "external_signals":
            try:
                external_payload = json.loads(candidate.read_text(encoding="utf-8"))
            except Exception:
                external_payload = {}
            if not isinstance(external_payload, dict):
                continue
            updated_at = str(external_payload.get("updated_at") or "").strip()
            signals = external_payload.get("signals") if isinstance(external_payload.get("signals"), list) else []
            errors = external_payload.get("errors") if isinstance(external_payload.get("errors"), list) else []
            if not updated_at and not signals and not errors:
                continue
            current_signal_summary = build_external_signal_summary(external_payload)
            metrics_signal_status = str(payload.get("external_signal_status") or "").strip().lower()
            metrics_fresh_signal_count = payload.get("fresh_external_signal_count")
            freshness_drift = (
                (metrics_signal_status and metrics_signal_status != current_signal_summary["status"])
                or (
                    metrics_fresh_signal_count is not None
                    and safe_int(metrics_fresh_signal_count, -1) != current_signal_summary["fresh_signal_count"]
                )
            )
            if freshness_drift:
                emit(True, False, "stale_against_external_signal_freshness", [])
                raise SystemExit(0)
        candidate_mtime = candidate_stat.st_mtime
        if candidate_mtime > metrics_mtime:
            stale_sources.append(label)

    if stale_sources:
        emit(True, False, f"stale_against_{stale_sources[0]}", [])
    else:
        emit(True, True, "complete_snapshot", [])
PY
}

repair_metrics_compatibility_aliases() {
  local metrics_path="${1:-$METRICS_FILE}"
  local repaired_aliases=""

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  repaired_aliases="$(python3 - "$metrics_path" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

metrics_path = Path(sys.argv[1])
if not metrics_path.exists():
    raise SystemExit(1)

try:
    payload = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

if not isinstance(payload, dict):
    raise SystemExit(1)

alias_sources = (
    ("approved_backlog", "approved_tasks"),
    ("task_registry_pressure_bytes", "task_registry_payload_bytes"),
    ("strategy_saturation", "strategy_saturation_detected"),
)

def missing(value):
    return value is None or (isinstance(value, str) and not value.strip())

repaired = []
for alias_key, source_key in alias_sources:
    if not missing(payload.get(alias_key)):
        continue
    source_value = payload.get(source_key)
    if missing(source_value):
        continue
    payload[alias_key] = source_value
    repaired.append(alias_key)

if not repaired:
    raise SystemExit(1)

metrics_path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile("w", delete=False, dir=metrics_path.parent, encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
    temp_path = handle.name
os.replace(temp_path, metrics_path)
print(",".join(repaired))
PY
)"

  if [ -z "$(trim_text "$repaired_aliases")" ]; then
    return 1
  fi

  log_msg INFO self-improve "Repaired metrics compatibility aliases before analysis: $repaired_aliases"
  return 0
}

missing_keys_csv_to_json() {
  local raw="${1:-}"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[]'
    return 0
  fi

  python3 - "$raw" <<'PY'
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
keys = [item for item in raw.split(",") if item]
print(json.dumps(keys))
PY
}

capture_metrics_input_state_without_refresh() {
  local snapshot_status=""
  local complete_flag=""
  local reason=""
  local missing_keys_csv=""

  snapshot_status="$(inspect_metrics_snapshot)"
  complete_flag="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
  reason="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
  missing_keys_csv="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"

  SELF_IMPROVE_METRICS_INPUT_REASON="${reason:-not_checked}"
  SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED="false"
  SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$missing_keys_csv")"

  if [ "$complete_flag" = "true" ]; then
    SELF_IMPROVE_METRICS_INPUT_STATUS="complete"
  else
    SELF_IMPROVE_METRICS_INPUT_STATUS="incomplete"
  fi
}

capture_prevalidate_metrics_snapshot() {
  local snapshot_status=""
  snapshot_status="$(inspect_metrics_snapshot)"
  SELF_IMPROVE_PREVALIDATE_COMPLETE="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
  SELF_IMPROVE_PREVALIDATE_REASON="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
  SELF_IMPROVE_PREVALIDATE_MISSING_KEYS_CSV="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"
}

run_validate_metrics_guard() {
  if [ "$SELF_IMPROVE_SHARED_METRICS_FALLBACK" = "true" ]; then
    log_msg DEBUG self-improve "External project is using shared metrics fallback; skipping validate-metrics against project-local registry"
    return 0
  fi

  [ -x "$ROOT_DIR/scripts/validate-metrics.sh" ] || return 0

  local output=""
  output="$(
    METRICS_FILE="$METRICS_FILE" \
    REGISTRY_FILE="$REGISTRY_FILE" \
    bash "$ROOT_DIR/scripts/validate-metrics.sh" 2>&1 || true
  )"
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log_msg INFO self-improve "$line"
      case "$line" in
        *"[validate-metrics] DRIFT DETECTED"*|*"[validate-metrics] Corrected and saved."*)
          SELF_IMPROVE_FORCE_METRICS_REFRESH="true"
          ;;
      esac
    done <<<"$output"
  fi
}

build_cooldown_improvement_snapshot() {
  python3 - "$METRICS_FILE" "$REGISTRY_FILE" "$TASK_LOG" "$RETRY_ANALYSIS_LOG" "$PROJECT_NAME" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

metrics_path = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3])
retry_analysis_path = Path(sys.argv[4])
project_name = str(sys.argv[5] or "codex-agent-system").strip() or "codex-agent-system"
root_dir = Path(sys.argv[6])
sandbox_scripts_dir = root_dir / "scripts"
if str(sandbox_scripts_dir) not in sys.path:
    sys.path.insert(0, str(sandbox_scripts_dir))

try:
    from task_metrics import (
        _compute_pipeline_staleness,
        build_first_pass_success_signal,
        build_latest_success_timestamp_by_identity,
        build_persisted_board_health_signals,
        build_retry_failure_kind_index,
        build_task_index_by_id,
        effective_retry_classification,
        is_unresolved_timeout_record,
    )
except Exception:
    _compute_pipeline_staleness = None
    build_first_pass_success_signal = None
    build_latest_success_timestamp_by_identity = None
    build_persisted_board_health_signals = None
    build_retry_failure_kind_index = None
    build_task_index_by_id = None
    effective_retry_classification = None
    is_unresolved_timeout_record = None

try:
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    metrics = {}
if not isinstance(metrics, dict):
    metrics = {}


def safe_int(value, fallback=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def safe_float(value, fallback=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def normalize_text(value):
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def read_json_lines(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            payload = json.loads(raw_line)
        except Exception:
            continue
        if isinstance(payload, dict):
            rows.append(payload)
    return rows


def read_registry_tasks(path: Path) -> list[dict[str, Any]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return [task for task in tasks if isinstance(task, dict)] if isinstance(tasks, list) else []


def project_key_for_task(task: dict[str, Any]) -> str:
    return normalize_text(task.get("project") or task.get("target_project") or project_name)


def project_key_for_record(record: dict[str, Any]) -> str:
    return normalize_text(record.get("project") or project_name)


def dominant_registry_source(metrics_payload):
    sources = metrics_payload.get("task_registry_pressure_sources")
    if not isinstance(sources, list):
        return {}

    best = {}
    best_bytes = -1
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
        if payload_bytes <= 0:
            continue
        candidate = {
            "project": str(entry.get("project") or "").strip() or "codex-agent-system",
            "file": str(entry.get("file") or "").strip(),
            "payload_bytes": payload_bytes,
        }
        if (
            payload_bytes > best_bytes
            or (
                payload_bytes == best_bytes
                and (candidate["project"], candidate["file"]) < (str(best.get("project") or ""), str(best.get("file") or ""))
            )
        ):
            best = candidate
            best_bytes = payload_bytes
    return best


def project_registry_source(metrics_payload, project_name):
    sources = metrics_payload.get("task_registry_pressure_sources")
    if not isinstance(sources, list):
        return {}

    project_key = normalize_text(project_name)
    best = {}
    best_bytes = -1
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        if normalize_text(entry.get("project")) != project_key:
            continue
        payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
        candidate = {
            "project": str(entry.get("project") or "").strip() or project_name,
            "file": str(entry.get("file") or "").strip(),
            "payload_bytes": payload_bytes,
        }
        if payload_bytes > best_bytes:
            best = candidate
            best_bytes = payload_bytes
    return best


project_key = normalize_text(project_name)
tasks = read_registry_tasks(registry_path)
task_log_records = read_json_lines(task_log_path)
retry_failure_records = read_json_lines(retry_analysis_path)
project_tasks = [task for task in tasks if project_key_for_task(task) == project_key]
project_task_log_records = [
    record for record in task_log_records if project_key_for_record(record) == project_key
]
project_retry_failure_records = [
    record for record in retry_failure_records if project_key_for_record(record) == project_key
]

project_success_rate = safe_float(metrics.get("success_rate", 0.0))
project_recent_success_rate = safe_float(metrics.get("recent_success_rate", metrics.get("success_rate", 0.0)))
project_timeout_rate = safe_float(
    metrics.get("timeout_failure_rate", metrics.get("timeout_rate", 0.0))
)
project_first_pass_success_rate = safe_float(metrics.get("first_pass_success_rate", 0.0))
project_retry_classification_coverage = safe_float(metrics.get("retry_classification_coverage", 0.0))
project_retry_classified_count = max(safe_int(metrics.get("retry_classified_count", 0)), 0)
project_retry_total_count = max(safe_int(metrics.get("retry_total_count", 0)), 0)
project_zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate", 0.0))
project_total_tasks = max(safe_int(metrics.get("total_tasks", 0)), 0)
project_pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks", 0)), 0)
project_approved_tasks = max(
    safe_int(
        metrics.get("approved_backlog")
        if metrics.get("approved_backlog") is not None
        else metrics.get("approved_tasks")
    ),
    0,
)
project_queued_tasks = max(safe_int(metrics.get("queued_tasks", 0)), 0)
project_running_tasks = max(safe_int(metrics.get("running_tasks", 0)), 0)
project_queue_starvation_detected = metrics.get("queue_starvation_detected", False) is True
project_pipeline_stale = metrics.get("pipeline_stale", False) is True
project_pipeline_stale_since = str(metrics.get("pipeline_stale_since") or "")

if project_task_log_records:
    project_total_tasks = len(project_task_log_records)
    project_success_rate = round(
        sum(
            1
            for record in project_task_log_records
            if str(record.get("result") or "").strip().upper() == "SUCCESS"
        ) / project_total_tasks,
        2,
    )
    if (
        build_task_index_by_id is not None
        and build_latest_success_timestamp_by_identity is not None
        and is_unresolved_timeout_record is not None
    ):
        tasks_by_id = build_task_index_by_id(project_tasks)
        latest_success_by_identity = build_latest_success_timestamp_by_identity(project_task_log_records)
        unresolved_timeout_failures = sum(
            1
            for record in project_task_log_records
            if is_unresolved_timeout_record(record, tasks_by_id, latest_success_by_identity)
        )
    else:
        unresolved_timeout_failures = sum(
            1
            for record in project_task_log_records
            if str(record.get("result") or "").strip().upper() == "FAILURE"
            and normalize_text(record.get("failure_kind")) == "timeout"
        )
    timeout_failure_events = sum(
        1
        for record in project_task_log_records
        if str(record.get("result") or "").strip().upper() == "FAILURE"
        and normalize_text(record.get("failure_kind")) == "timeout"
    )
    zero_step_timeouts = sum(
        1
        for record in project_task_log_records
        if str(record.get("result") or "").strip().upper() == "FAILURE"
        and normalize_text(record.get("failure_kind")) == "timeout"
        and safe_int(record.get("total_step_attempts")) == 0
    )
    project_timeout_rate = round(
        unresolved_timeout_failures / project_total_tasks,
        2,
    ) if project_total_tasks else 0.0
    project_zero_step_timeout_rate = round(
        zero_step_timeouts / timeout_failure_events,
        2,
    ) if timeout_failure_events else 0.0
    recent_project_records = [
        record
        for record in project_task_log_records
        if str(record.get("result") or "").strip().upper() in {"SUCCESS", "FAILURE"}
    ][-50:]
    project_recent_success_rate = round(
        sum(
            1
            for record in recent_project_records
            if str(record.get("result") or "").strip().upper() == "SUCCESS"
        ) / len(recent_project_records),
        2,
    ) if recent_project_records else 0.0
    if _compute_pipeline_staleness is not None:
        pipeline_stale_signal = _compute_pipeline_staleness(project_task_log_records, project_tasks)
        project_pipeline_stale = pipeline_stale_signal.get("pipeline_stale") is True
        project_pipeline_stale_since = str(pipeline_stale_signal.get("pipeline_stale_since") or "")

if project_tasks:
    project_pending_approval_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")) == "pending_approval"
    )
    project_approved_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")) == "approved"
    )
    project_queued_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")) == "queued"
    )
    project_running_tasks = sum(
        1 for task in project_tasks if normalize_text(task.get("status")) == "running"
    )

if project_tasks and build_persisted_board_health_signals is not None:
    board_health_signal = build_persisted_board_health_signals(project_tasks)
    project_queue_starvation_detected = board_health_signal.get("queue_starvation_detected") is True

if project_tasks and build_first_pass_success_signal is not None:
    first_pass_signal = build_first_pass_success_signal(project_tasks, project_task_log_records)
    successful_resolutions = max(safe_int(first_pass_signal.get("first_pass_success_count")), 0) + max(
        safe_int(first_pass_signal.get("multi_attempt_resolved_count")),
        0,
    )
    if successful_resolutions > 0:
        project_first_pass_success_rate = safe_float(first_pass_signal.get("first_pass_success_rate", 0.0))

if (
    project_retry_failure_records
    and build_retry_failure_kind_index is not None
    and effective_retry_classification is not None
):
    retry_failure_kind_index = build_retry_failure_kind_index(project_task_log_records)
    project_retry_total_count = len(project_retry_failure_records)
    project_retry_classified_count = sum(
        1
        for record in project_retry_failure_records
        if effective_retry_classification(record, retry_failure_kind_index) != "unknown"
    )
    project_retry_classification_coverage = round(
        project_retry_classified_count / project_retry_total_count,
        2,
    ) if project_retry_total_count else 0.0

approved_backlog = project_approved_tasks
pending_approval_tasks = project_pending_approval_tasks
registry_bytes = safe_int(
    metrics.get("task_registry_pressure_bytes", metrics.get("task_registry_payload_bytes", 0))
)
shared_registry_bytes = safe_int(metrics.get("shared_registry_bytes", registry_bytes))
registry_pressure_dominant_source = metrics.get("registry_pressure_dominant_source")
if not isinstance(registry_pressure_dominant_source, dict):
    registry_pressure_dominant_source = dominant_registry_source(metrics)
registry_pressure_local_source = metrics.get("registry_pressure_local_source")
if not isinstance(registry_pressure_local_source, dict):
    registry_pressure_local_source = project_registry_source(metrics, project_name)
if not registry_pressure_local_source and registry_path.exists():
    try:
        registry_pressure_local_source = {
            "project": project_name,
            "file": str(registry_path),
            "payload_bytes": registry_path.stat().st_size,
        }
    except OSError:
        registry_pressure_local_source = {}
local_registry_bytes = safe_int(
    metrics.get(
        "local_registry_bytes",
        registry_pressure_local_source.get("payload_bytes", registry_bytes),
    )
)
registry_pressure_scope = str(metrics.get("registry_pressure_scope") or "").strip().lower()
if registry_pressure_scope not in {"none", "local", "cross_project"}:
    dominant_project = normalize_text(registry_pressure_dominant_source.get("project"))
    local_project = normalize_text(registry_pressure_local_source.get("project") or project_name)
    if shared_registry_bytes < 512000:
        registry_pressure_scope = "none"
    elif dominant_project and dominant_project != local_project and local_registry_bytes < 512000:
        registry_pressure_scope = "cross_project"
    else:
        registry_pressure_scope = "local"

payload = {
    "status": "success",
    "message": "Cooldown active; skipped improvement generation",
    "data": {
        "improvements": [],
        "analysis": {
            "detected_count": 0,
            "generated_count": 0,
            "blocked_analysis_count": 0,
            "backlog_filtered_count": 0,
            "title_family_filtered_count": 0,
            "dominant_gating_reason": "cooldown_active",
            "suppressed_analysis_reasons": ["cooldown_active"],
            "automation_memory_preference": {
                "title": "",
                "reason": "none",
                "applied": False,
            },
            "overload_gate": {
                "active": False,
                "preserved_title": "",
                "preserved_reason": "inactive",
                "candidate_count": 0,
                "blocked_candidate_count": 0,
                "candidates": [],
            },
        },
        "metrics_snapshot": {
            "success_rate": project_success_rate,
            "first_pass_success_rate": project_first_pass_success_rate,
            "timeout_rate": project_timeout_rate,
            "retry_classification_coverage": project_retry_classification_coverage,
            "retry_classified_count": project_retry_classified_count,
            "retry_total_count": project_retry_total_count,
            "zero_step_timeout_rate": project_zero_step_timeout_rate,
            "pipeline_stale": project_pipeline_stale,
            "pipeline_stale_since": project_pipeline_stale_since,
            "registry_bytes": registry_bytes,
            "shared_registry_bytes": shared_registry_bytes,
            "local_registry_bytes": local_registry_bytes,
            "registry_pressure_scope": registry_pressure_scope,
            "registry_pressure_dominant_source": registry_pressure_dominant_source,
            "registry_pressure_local_source": registry_pressure_local_source,
            "approved_backlog": max(approved_backlog, 0) + max(pending_approval_tasks, 0),
            "queue_starvation_detected": project_queue_starvation_detected,
            "queued_tasks": project_queued_tasks,
            "running_tasks": project_running_tasks,
            "backlog": max(approved_backlog, 0) + max(pending_approval_tasks, 0),
            "backlog_gate_active": metrics.get("backlog_gate_active", False) is True,
            "total_tasks": project_total_tasks,
            "recent_success_rate": project_recent_success_rate,
            "improvement_detected": metrics.get("improvement_detected", False) is True,
            "regression_detected": metrics.get("regression_detected", False) is True,
            "external_signal_status": str(metrics.get("external_signal_status", "unknown") or "unknown"),
            "fresh_external_signal_count": safe_int(metrics.get("fresh_external_signal_count", 0)),
            "latest_external_signal_source": str(metrics.get("latest_external_signal_source") or ""),
        },
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
}

print(json.dumps(payload, indent=2))
PY
}

refresh_persisted_metrics() {
  local snapshot_status
  snapshot_status="$(inspect_metrics_snapshot)"
  local complete_flag
  local reason
  local missing_keys_csv
  complete_flag="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
  reason="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
  missing_keys_csv="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"

  SELF_IMPROVE_METRICS_INPUT_REASON="${reason:-not_checked}"
  SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED="false"
  SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$missing_keys_csv")"

  if [ "$SELF_IMPROVE_SHARED_METRICS_FALLBACK" = "true" ]; then
    if shared_metrics_fallback_snapshot_reason_allowed "${reason:-}"; then
      SELF_IMPROVE_METRICS_INPUT_STATUS="complete"
      SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="[]"
    else
      SELF_IMPROVE_METRICS_INPUT_STATUS="incomplete"
    fi
    SELF_IMPROVE_METRICS_INPUT_REASON="external_shared_metrics_fallback"
    log_msg DEBUG self-improve "External project is using shared metrics fallback; skipping persisted metrics refresh"
    return 0
  fi

  if [ "$complete_flag" = "true" ]; then
    if [ "${SELF_IMPROVE_FORCE_METRICS_REFRESH:-false}" != "true" ]; then
      SELF_IMPROVE_METRICS_INPUT_STATUS="complete"
      log_msg DEBUG self-improve "Existing metrics snapshot is complete; skipping persisted metrics refresh"
      return 0
    fi
    if [ "${SELF_IMPROVE_PREVALIDATE_COMPLETE:-false}" != "true" ]; then
      reason="${SELF_IMPROVE_PREVALIDATE_REASON:-$reason}"
      missing_keys_csv="${SELF_IMPROVE_PREVALIDATE_MISSING_KEYS_CSV:-$missing_keys_csv}"
      SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$missing_keys_csv")"
    else
      reason="validate_metrics_corrected_drift"
    fi
    SELF_IMPROVE_METRICS_INPUT_REASON="${reason:-not_checked}"
  fi

  if [ -n "$(trim_text "$missing_keys_csv")" ]; then
    local repaired_alias_status=0
    local previous_err_trap=""
    previous_err_trap="$(trap -p ERR || true)"
    set +e
    trap - ERR
    repair_metrics_compatibility_aliases "$METRICS_FILE"
    repaired_alias_status=$?
    set -e
    if [ -n "$previous_err_trap" ]; then
      eval "$previous_err_trap"
    fi
    if [ "$repaired_alias_status" -eq 0 ]; then
      SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED="true"
      local repaired_snapshot_status
      repaired_snapshot_status="$(inspect_metrics_snapshot)"
      local repaired_complete_flag
      local repaired_reason
      local repaired_missing_keys_csv
      repaired_complete_flag="$(printf '%s\n' "$repaired_snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
      repaired_reason="$(printf '%s\n' "$repaired_snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
      repaired_missing_keys_csv="$(printf '%s\n' "$repaired_snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"
      SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$repaired_missing_keys_csv")"
      if [ "$repaired_complete_flag" = "true" ] && [ "${SELF_IMPROVE_FORCE_METRICS_REFRESH:-false}" != "true" ]; then
        SELF_IMPROVE_METRICS_INPUT_STATUS="refreshed"
        return 0
      fi
      if [ "${SELF_IMPROVE_FORCE_METRICS_REFRESH:-false}" != "true" ] || [ "${SELF_IMPROVE_PREVALIDATE_COMPLETE:-false}" = "true" ]; then
        reason="${repaired_reason:-$reason}"
        missing_keys_csv="${repaired_missing_keys_csv:-$missing_keys_csv}"
      fi
      SELF_IMPROVE_METRICS_INPUT_REASON="${reason:-not_checked}"
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    SELF_IMPROVE_METRICS_INPUT_STATUS="incomplete"
    SELF_IMPROVE_METRICS_INPUT_REASON="python3_unavailable"
    log_msg WARN self-improve "python3 unavailable; skipping persisted metrics refresh before analysis"
    return 0
  fi

  if [ ! -f "$ROOT_DIR/scripts/sync-task-artifacts.py" ]; then
    SELF_IMPROVE_METRICS_INPUT_STATUS="incomplete"
    SELF_IMPROVE_METRICS_INPUT_REASON="sync_task_artifacts_missing"
    log_msg WARN self-improve "sync-task-artifacts.py missing; skipping persisted metrics refresh before analysis"
    return 0
  fi

  if python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" \
    "$REGISTRY_FILE" \
    "$TASK_LOG" \
    "$METRICS_FILE" \
    "$EXTERNAL_SIGNALS_FILE" >/dev/null 2>&1; then
    SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED="true"
    local refreshed_snapshot_status
    refreshed_snapshot_status="$(inspect_metrics_snapshot)"
    local refreshed_complete_flag
    local refreshed_missing_keys_csv
    refreshed_complete_flag="$(printf '%s\n' "$refreshed_snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
    refreshed_missing_keys_csv="$(printf '%s\n' "$refreshed_snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"
    SELF_IMPROVE_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$refreshed_missing_keys_csv")"
    if [ "$refreshed_complete_flag" = "true" ]; then
      SELF_IMPROVE_METRICS_INPUT_STATUS="refreshed"
    else
      SELF_IMPROVE_METRICS_INPUT_STATUS="incomplete"
      SELF_IMPROVE_METRICS_INPUT_REASON="missing_required_keys_after_refresh"
    fi
    log_msg INFO self-improve "Refreshed persisted metrics before analysis"
    return 0
  fi

  SELF_IMPROVE_METRICS_INPUT_STATUS="refresh_failed"
  SELF_IMPROVE_METRICS_INPUT_REFRESH_PERFORMED="true"
  [ -n "${reason:-}" ] || SELF_IMPROVE_METRICS_INPUT_REASON="refresh_failed"
  log_msg WARN self-improve "Persisted metrics refresh failed before analysis; continuing with existing metrics snapshot"
  return 0
}

# ─── Learning Feedback Loop: Update metrics after improvements ───

update_post_improvement_metrics() {
  if [ ! -f "$METRICS_FILE" ]; then
    return 0
  fi

  # Count recent success rate (last 20 tasks) vs overall. Preserve existing
  # learning when there is no recent sample window instead of overwriting
  # short-term trend fields with zeroes.
  local recent_summary
  recent_summary="$(tail -n 20 "$MEMORY_DIR/tasks.log" 2>/dev/null | python3 -c "
import json, sys
lines = [json.loads(l) for l in sys.stdin if l.strip()]
if not lines:
    print('0\\t0')
else:
    s = sum(1 for l in lines if l.get('result') == 'SUCCESS')
    print(f'{len(lines)}\\t{s/len(lines):.2f}')
" 2>/dev/null || printf '0\t0')"
  local recent_window_size
  recent_window_size="$(printf '%s' "$recent_summary" | awk -F '\t' '{print $1}' 2>/dev/null || printf '0')"
  if [ "${recent_window_size:-0}" -le 0 ]; then
    return 0
  fi

  local recent_success_rate
  recent_success_rate="$(printf '%s' "$recent_summary" | awk -F '\t' '{print $2}' 2>/dev/null || printf '0')"

  # Update metrics with trend data
  python3 - "$METRICS_FILE" "$recent_success_rate" "$recent_window_size" <<'PY'
import json, sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
recent_rate = float(sys.argv[2])
recent_window_size = int(sys.argv[3])

try:
    metrics = json.loads(metrics_path.read_text())
except Exception:
    metrics = {}

# Track improvement trend
trend_history = metrics.get("success_rate_trend", [])
trend_history.append({
    "rate": recent_rate,
    "timestamp": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
})
# Keep last 20 data points
trend_history = trend_history[-20:]
metrics["success_rate_trend"] = trend_history
metrics["recent_success_rate"] = recent_rate
metrics["recent_window_size"] = recent_window_size

# Detect improvement or regression
if len(trend_history) >= 3:
    old_avg = sum(t["rate"] for t in trend_history[:len(trend_history)//2]) / max(len(trend_history)//2, 1)
    new_avg = sum(t["rate"] for t in trend_history[len(trend_history)//2:]) / max(len(trend_history) - len(trend_history)//2, 1)
    metrics["improvement_detected"] = new_avg > old_avg + 0.05
    metrics["regression_detected"] = new_avg < old_avg - 0.1

metrics_path.write_text(json.dumps(metrics, indent=2) + "\n")
PY
}

# Paused runs should still emit a fresh artifact so automation context refreshes
# can distinguish an intentional pause from a stale self-improve snapshot.
build_paused_improvement_snapshot() {
  python3 - "$METRICS_FILE" "$REGISTRY_FILE" "$TASK_LOG" "$RETRY_ANALYSIS_LOG" "$PROJECT_NAME" "$ROOT_DIR" "$SELF_IMPROVE_PAUSE_FILE" "$SELF_IMPROVE_PAUSE_ESCALATION_SECONDS" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

metrics_path = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3])
retry_analysis_path = Path(sys.argv[4])
project_name = str(sys.argv[5] or "codex-agent-system").strip() or "codex-agent-system"
root_dir = Path(sys.argv[6])
pause_file = str(sys.argv[7] or "").strip()
pause_escalation_threshold_seconds = max(int(str(sys.argv[8] or "21600").strip() or "21600"), 0)
sandbox_scripts_dir = root_dir / "scripts"
if str(sandbox_scripts_dir) not in sys.path:
    sys.path.insert(0, str(sandbox_scripts_dir))

try:
    from task_metrics import (
        _compute_pipeline_staleness,
        build_first_pass_success_signal,
        build_persisted_board_health_signals,
        build_retry_failure_kind_index,
        effective_retry_classification,
    )
except Exception:
    _compute_pipeline_staleness = None
    build_first_pass_success_signal = None
    build_persisted_board_health_signals = None
    build_retry_failure_kind_index = None
    effective_retry_classification = None


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project_key(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", normalize_text(value)))


def safe_int(value: Any, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def safe_float(value: Any, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def read_json_lines(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records

    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return records

    for raw_line in raw_lines:
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


def dominant_registry_source(metrics_payload: dict[str, Any]) -> dict[str, Any]:
    sources = metrics_payload.get("task_registry_pressure_sources")
    if not isinstance(sources, list):
        return {}

    best: dict[str, Any] = {}
    best_bytes = -1
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
        if payload_bytes <= 0:
            continue
        candidate = {
            "project": str(entry.get("project") or "").strip(),
            "file": str(entry.get("file") or "").strip(),
            "payload_bytes": payload_bytes,
        }
        if payload_bytes > best_bytes:
            best = candidate
            best_bytes = payload_bytes
    return best


def project_registry_source(metrics_payload: dict[str, Any], project: str) -> dict[str, Any]:
    sources = metrics_payload.get("task_registry_pressure_sources")
    if not isinstance(sources, list):
        return {}

    target_key = normalize_project_key(project)
    best: dict[str, Any] = {}
    best_bytes = -1
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        if normalize_project_key(entry.get("project")) != target_key:
            continue
        payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
        candidate = {
            "project": str(entry.get("project") or "").strip(),
            "file": str(entry.get("file") or "").strip(),
            "payload_bytes": payload_bytes,
        }
        if payload_bytes > best_bytes:
            best = candidate
            best_bytes = payload_bytes
    return best


try:
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    metrics = {}

try:
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    tasks = registry.get("tasks", [])
except Exception:
    tasks = []

if not isinstance(metrics, dict):
    metrics = {}
if not isinstance(tasks, list):
    tasks = []

project_key = normalize_project_key(project_name)
project_tasks = [
    task
    for task in tasks
    if isinstance(task, dict)
    and normalize_project_key(task.get("project") or task.get("target_project") or project_name) == project_key
]
project_task_log_records = [
    record
    for record in read_json_lines(task_log_path)
    if normalize_project_key(record.get("project") or record.get("target_project") or project_name) == project_key
]
project_retry_failure_records = [
    record
    for record in read_json_lines(retry_analysis_path)
    if normalize_project_key(record.get("project") or record.get("target_project") or project_name) == project_key
]

project_success_rate = safe_float(metrics.get("success_rate"))
project_recent_success_rate = safe_float(metrics.get("recent_success_rate"))
project_timeout_rate = safe_float(metrics.get("timeout_failure_rate"))
project_first_pass_success_rate = safe_float(metrics.get("first_pass_success_rate"))
project_retry_classification_coverage = safe_float(metrics.get("retry_classification_coverage"))
project_retry_classified_count = max(safe_int(metrics.get("retry_classified_count")), 0)
project_retry_total_count = max(safe_int(metrics.get("retry_total_count")), 0)
project_zero_step_timeout_rate = safe_float(metrics.get("zero_step_timeout_rate"))
project_queue_starvation_detected = metrics.get("queue_starvation_detected") is True
project_pending_approval_tasks = max(safe_int(metrics.get("pending_approval_tasks")), 0)
project_approved_tasks = max(safe_int(metrics.get("approved_tasks")), 0)
project_queued_tasks = max(safe_int(metrics.get("queued_tasks")), 0)
project_running_tasks = max(safe_int(metrics.get("running_tasks")), 0)
project_total_tasks = max(safe_int(metrics.get("total_tasks")), 0)
project_pipeline_stale = metrics.get("pipeline_stale") is True
project_pipeline_stale_since = str(metrics.get("pipeline_stale_since") or "").strip() or None

if project_tasks and _compute_pipeline_staleness is not None:
    pipeline_stale_signal = _compute_pipeline_staleness(project_task_log_records, project_tasks)
    project_pipeline_stale = pipeline_stale_signal.get("pipeline_stale") is True
    project_pipeline_stale_since = (
        str(pipeline_stale_signal.get("pipeline_stale_since") or "").strip() or project_pipeline_stale_since
    )

if project_tasks and build_persisted_board_health_signals is not None:
    board_health_signal = build_persisted_board_health_signals(project_tasks)
    project_queue_starvation_detected = board_health_signal.get("queue_starvation_detected") is True

if project_tasks and build_first_pass_success_signal is not None:
    first_pass_signal = build_first_pass_success_signal(project_tasks, project_task_log_records)
    successful_resolutions = max(safe_int(first_pass_signal.get("first_pass_success_count")), 0) + max(
        safe_int(first_pass_signal.get("multi_attempt_resolved_count")),
        0,
    )
    if successful_resolutions > 0:
        project_first_pass_success_rate = safe_float(first_pass_signal.get("first_pass_success_rate", 0.0))

if (
    project_retry_failure_records
    and build_retry_failure_kind_index is not None
    and effective_retry_classification is not None
):
    retry_failure_kind_index = build_retry_failure_kind_index(project_task_log_records)
    project_retry_total_count = len(project_retry_failure_records)
    project_retry_classified_count = sum(
        1
        for record in project_retry_failure_records
        if effective_retry_classification(record, retry_failure_kind_index) != "unknown"
    )
    project_retry_classification_coverage = round(
        project_retry_classified_count / project_retry_total_count,
        2,
    ) if project_retry_total_count else 0.0

approved_backlog = project_approved_tasks
registry_bytes = safe_int(
    metrics.get("task_registry_pressure_bytes", metrics.get("task_registry_payload_bytes", 0))
)
shared_registry_bytes = safe_int(metrics.get("shared_registry_bytes", registry_bytes))
registry_pressure_dominant_source = metrics.get("registry_pressure_dominant_source")
if not isinstance(registry_pressure_dominant_source, dict):
    registry_pressure_dominant_source = dominant_registry_source(metrics)
registry_pressure_local_source = metrics.get("registry_pressure_local_source")
if not isinstance(registry_pressure_local_source, dict):
    registry_pressure_local_source = project_registry_source(metrics, project_name)
if not registry_pressure_local_source and registry_path.exists():
    try:
        registry_pressure_local_source = {
            "project": project_name,
            "file": str(registry_path),
            "payload_bytes": registry_path.stat().st_size,
        }
    except OSError:
        registry_pressure_local_source = {}
local_registry_bytes = safe_int(
    metrics.get(
        "local_registry_bytes",
        registry_pressure_local_source.get("payload_bytes", registry_bytes),
    )
)
pause_detected_at = ""
pause_age_seconds = 0
pause_path = Path(pause_file) if pause_file else None
if pause_path is not None and pause_path.is_file():
    try:
        pause_epoch = pause_path.stat().st_mtime
        pause_detected_at = datetime.fromtimestamp(pause_epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        pause_age_seconds = max(int(datetime.now(timezone.utc).timestamp() - pause_epoch), 0)
    except OSError:
        pause_detected_at = ""
        pause_age_seconds = 0
pause_escalation_active = pause_age_seconds >= pause_escalation_threshold_seconds > 0
pause_escalation = {
    "active": pause_escalation_active,
    "kind": "pause_age_threshold" if pause_escalation_active else "none",
    "severity": "warning" if pause_escalation_active else "none",
    "threshold_seconds": pause_escalation_threshold_seconds,
    "title": "Long-lived self-improve pause" if pause_escalation_active else "",
    "summary": (
        f"Self-improve has been paused for {pause_age_seconds}s, exceeding the {pause_escalation_threshold_seconds}s review threshold."
        if pause_escalation_active else ""
    ),
}
registry_pressure_scope = str(metrics.get("registry_pressure_scope") or "").strip().lower()
if registry_pressure_scope not in {"none", "local", "cross_project"}:
    dominant_project = normalize_text(registry_pressure_dominant_source.get("project"))
    local_project = normalize_text(registry_pressure_local_source.get("project") or project_name)
    if shared_registry_bytes < 512000:
        registry_pressure_scope = "none"
    elif dominant_project and dominant_project != local_project and local_registry_bytes < 512000:
        registry_pressure_scope = "cross_project"
    else:
        registry_pressure_scope = "local"

payload = {
    "status": "success",
    "message": "Self-improve paused; skipped improvement generation",
    "data": {
        "improvements": [],
        "analysis": {
            "detected_count": 0,
            "generated_count": 0,
            "blocked_analysis_count": 0,
            "backlog_filtered_count": 0,
            "title_family_filtered_count": 0,
            "dominant_gating_reason": "paused_by_file",
            "suppressed_analysis_reasons": ["paused_by_file"],
            "automation_memory_preference": {
                "title": "",
                "reason": "none",
                "applied": False,
            },
            "overload_gate": {
                "active": False,
                "preserved_title": "",
                "preserved_reason": "inactive",
                "candidate_count": 0,
                "blocked_candidate_count": 0,
                "candidates": [],
            },
        },
        "metrics_snapshot": {
            "success_rate": project_success_rate,
            "first_pass_success_rate": project_first_pass_success_rate,
            "timeout_rate": project_timeout_rate,
            "retry_classification_coverage": project_retry_classification_coverage,
            "retry_classified_count": project_retry_classified_count,
            "retry_total_count": project_retry_total_count,
            "zero_step_timeout_rate": project_zero_step_timeout_rate,
            "pipeline_stale": project_pipeline_stale,
            "pipeline_stale_since": project_pipeline_stale_since,
            "registry_bytes": registry_bytes,
            "shared_registry_bytes": shared_registry_bytes,
            "local_registry_bytes": local_registry_bytes,
            "registry_pressure_scope": registry_pressure_scope,
            "registry_pressure_dominant_source": registry_pressure_dominant_source,
            "registry_pressure_local_source": registry_pressure_local_source,
            "approved_backlog": max(approved_backlog, 0) + max(project_pending_approval_tasks, 0),
            "queue_starvation_detected": project_queue_starvation_detected,
            "queued_tasks": project_queued_tasks,
            "running_tasks": project_running_tasks,
            "backlog": max(approved_backlog, 0) + max(project_pending_approval_tasks, 0),
            "backlog_gate_active": metrics.get("backlog_gate_active", False) is True,
            "total_tasks": project_total_tasks,
            "recent_success_rate": project_recent_success_rate,
            "improvement_detected": metrics.get("improvement_detected", False) is True,
            "regression_detected": metrics.get("regression_detected", False) is True,
            "external_signal_status": str(metrics.get("external_signal_status", "unknown") or "unknown"),
            "fresh_external_signal_count": safe_int(metrics.get("fresh_external_signal_count", 0)),
            "latest_external_signal_source": str(metrics.get("latest_external_signal_source") or ""),
        },
        "pause": {
            "active": True,
            "reason": "paused_by_file",
            "file": pause_file,
            "detected_at": pause_detected_at,
            "age_seconds": pause_age_seconds,
            "escalation": pause_escalation,
            "remediation": {
                "active": True,
                "kind": "remove_pause_file",
                "title": "Remove self-improve pause gate",
                "summary": f"Delete {pause_file} and rerun self-improve when autonomous improvement should resume.",
                "command": f"rm -f {pause_file} && bash scripts/self-improve.sh {project_name}",
            },
        },
        "pause_file": pause_file,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
}

print(json.dumps(payload, indent=2))
PY
}

# Main execution
# v27 FIX: Run validate-metrics.sh BEFORE cooldown check so that
# capture_metrics_input_state_without_refresh sees corrected values.
# Previously, the cooldown path captured stale metrics → reported
# "incomplete" → self-improve never generated improvements.
capture_prevalidate_metrics_snapshot
run_validate_metrics_guard

if [ -f "$SELF_IMPROVE_PAUSE_FILE" ]; then
  log_msg INFO self-improve "Self-improve paused via $SELF_IMPROVE_PAUSE_FILE — skipping"
  capture_metrics_input_state_without_refresh
  paused_improvements_json="$(build_paused_improvement_snapshot)"
  paused_submit_result='{"submitted":0,"skipped":0,"total":0,"submission_limit_reason":"paused_by_file","dominant_gating_reason":"paused_by_file"}'
  write_self_improve_run_artifact "$paused_improvements_json" "$paused_submit_result" "success"
  append_self_improve_memory_summary "$paused_improvements_json" "$paused_submit_result" "success"
  printf '{"status":"skipped","reason":"paused_by_file","pause_file":"%s"}\n' "$SELF_IMPROVE_PAUSE_FILE"
  exit 0
fi

if ! check_cooldown; then
  capture_metrics_input_state_without_refresh
  cooldown_improvements_json="$(build_cooldown_improvement_snapshot)"
  cooldown_submit_result='{"submitted":0,"skipped":0,"total":0,"submission_limit_reason":"cooldown_active","dominant_gating_reason":"cooldown_active"}'
  write_self_improve_run_artifact "$cooldown_improvements_json" "$cooldown_submit_result" "success"
  exit 0
fi

log_msg INFO self-improve "Analyzing system for improvement opportunities..."

# Run CLI health check first
check_provider_health || log_msg WARN self-improve "Provider health check found issues"

# Pre-dispatch metrics validation: fix drifted registry counts before refresh
run_validate_metrics_guard

# Refresh core persisted metrics before layering short-term trend signals on top.
refresh_persisted_metrics 2>/dev/null || true

# Update trend metrics
update_post_improvement_metrics 2>/dev/null || true

# Run rule-effectiveness analysis and log results
if [ -x "$ROOT_DIR/scripts/analyze-rule-effectiveness.sh" ]; then
  rule_report="$(bash "$ROOT_DIR/scripts/analyze-rule-effectiveness.sh" 5 2>/dev/null || printf '{}')"
  rule_status="$(printf '%s' "$rule_report" | jq -r '.status // "unknown"' 2>/dev/null || printf 'unknown')"
  if [ "$rule_status" = "ok" ]; then
    rule_trend="$(printf '%s' "$rule_report" | jq -r '.trend.improving // false' 2>/dev/null || printf 'false')"
    rule_delta="$(printf '%s' "$rule_report" | jq -r '.trend.delta // 0' 2>/dev/null || printf '0')"
    rule_recommendation="$(printf '%s' "$rule_report" | jq -r '.recommendation // ""' 2>/dev/null || true)"
    log_msg INFO self-improve "Rule effectiveness: improving=$rule_trend delta=$rule_delta"
    [ -z "$rule_recommendation" ] || log_msg INFO self-improve "Rule recommendation: $rule_recommendation"
    # Persist report for dashboard consumption
    printf '%s\n' "$rule_report" > "$LEARNING_DIR/rule-effectiveness-report.json" 2>/dev/null || true
  fi
fi

if [ "${SELF_IMPROVE_DEBUG_ERRORS:-0}" = "1" ]; then
  improvements_json="$(generate_improvements || printf '{"status":"fail","data":{"improvements":[]}}')"
else
  improvements_json="$(generate_improvements 2>/dev/null || printf '{"status":"fail","data":{"improvements":[]}}')"
fi
status="$(printf '%s' "$improvements_json" | jq -r '.status' 2>/dev/null || printf 'fail')"

if [ "$status" = "success" ]; then
  submit_result="$(submit_improvement_tasks "$improvements_json")"
  write_self_improve_run_artifact "$improvements_json" "$submit_result" "success"
  append_self_improve_memory_summary "$improvements_json" "$submit_result" "success"
else
  write_self_improve_run_artifact "$improvements_json" "" "analysis_failed"
  append_self_improve_memory_summary "$improvements_json" "" "analysis_failed"
  log_msg WARN self-improve "Improvement analysis failed"
fi
