#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap prepare-automation-context

PROJECT_NAME="${1:-}"
RECENT_LINES_RAW="${2:-8}"

if [ -z "$PROJECT_NAME" ]; then
  python3 - <<'PY'
import json

print(json.dumps({
    "status": "fail",
    "message": "Usage: prepare-automation-context.sh <project> [recent_lines]",
    "data": {},
}, separators=(",", ":"), sort_keys=True))
PY
  exit 1
fi

case "$RECENT_LINES_RAW" in
  ''|*[!0-9]*)
    RECENT_LINES=8
    ;;
  *)
    RECENT_LINES="$RECENT_LINES_RAW"
    ;;
esac

inspect_metrics_snapshot() {
  local registry_file="${1:-$TASK_REGISTRY_FILE}"

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'false\tfalse\tpython3_unavailable\n'
    return 0
  fi

python3 - "$METRICS_FILE" "$registry_file" "$TASK_LOG" "$EXTERNAL_SIGNALS_FILE" <<'PY'
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
    "approved_backlog",
    "task_registry_pressure_bytes",
    "strategy_saturation",
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

def emit(exists: bool, complete: bool, reason: str, missing_keys: list[str] | None = None) -> None:
    missing_keys = [str(item).strip() for item in (missing_keys or []) if str(item).strip()]
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
    emit(False, False, "metrics_file_missing")
    raise SystemExit(0)

try:
    payload = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    emit(True, False, "invalid_json")
    raise SystemExit(0)

if not isinstance(payload, dict):
    emit(True, False, "invalid_payload")
    raise SystemExit(0)

missing_keys = []
for key in required_keys:
    value = payload.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        missing_keys.append(key)

if missing_keys:
    emit(True, False, "missing_required_keys", missing_keys)
    raise SystemExit(0)

for key in bounded_rate_keys:
    if key not in payload:
        continue
    value = payload.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        continue
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        emit(True, False, f"invalid_bounded_metric_{key}")
        raise SystemExit(0)
    if not math.isfinite(numeric) or numeric < 0 or numeric > 1:
        emit(True, False, f"invalid_bounded_metric_{key}")
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
        local_payload_bytes = safe_int(local_source.get("payload_bytes"), -1)
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
        "pending_approval_tasks": primary_status_counts.get("pending_approval", 0),
        "approved_backlog": primary_status_counts.get("approved", 0),
        "queued_tasks": primary_status_counts.get("queued", 0),
        "running_tasks": primary_status_counts.get("running", 0),
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
            emit(True, False, f"invalid_registry_count_{key}")
            raise SystemExit(0)
        if numeric != expected_value:
            registry_mismatch_keys.append(key)

if registry_mismatch_keys:
    emit(True, False, "registry_count_mismatch", registry_mismatch_keys)
    raise SystemExit(0)

try:
    metrics_mtime = metrics_path.stat().st_mtime
except OSError:
    emit(True, False, "metrics_stat_failed")
    raise SystemExit(0)

for label, candidate in (
    ("tasks_json", registry_path),
    ("tasks_log", task_log_path),
    ("external_signals", external_signals_path),
):
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
            emit(True, False, "stale_against_external_signal_freshness")
            raise SystemExit(0)
    if candidate_stat.st_mtime > metrics_mtime:
        emit(True, False, f"stale_against_{label}")
        raise SystemExit(0)

emit(True, True, "complete_snapshot")
PY
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

repair_metrics_compatibility_aliases() {
  local metrics_path="${1:-$METRICS_FILE}"

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$metrics_path" <<'PY'
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
}

AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="unknown"
AUTOMATION_CONTEXT_METRICS_INPUT_REASON="not_checked"
AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED="false"
AUTOMATION_CONTEXT_METRICS_INPUT_MISSING_KEYS_JSON="[]"
AUTOMATION_CONTEXT_SHARED_METRICS_FALLBACK="false"

refresh_metrics_snapshot_if_needed() {
  local registry_file="${1:-$TASK_REGISTRY_FILE}"
  local snapshot_status=""
  local complete_flag=""
  local reason=""
  local missing_keys_csv=""

  snapshot_status="$(inspect_metrics_snapshot "$registry_file")"
  complete_flag="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
  reason="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
  missing_keys_csv="$(printf '%s\n' "$snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"

  AUTOMATION_CONTEXT_METRICS_INPUT_REASON="${reason:-not_checked}"
  AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED="false"
  AUTOMATION_CONTEXT_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$missing_keys_csv")"

  if [ "$AUTOMATION_CONTEXT_SHARED_METRICS_FALLBACK" = "true" ]; then
    if shared_metrics_fallback_snapshot_reason_allowed "${reason:-}"; then
      AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="complete"
      AUTOMATION_CONTEXT_METRICS_INPUT_MISSING_KEYS_JSON="[]"
    else
      AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="incomplete"
    fi
    AUTOMATION_CONTEXT_METRICS_INPUT_REASON="external_shared_metrics_fallback"
    log_msg DEBUG prepare-automation-context "External project is using shared metrics fallback; skipping persisted metrics refresh"
    return 0
  fi

  if [ "$complete_flag" = "true" ]; then
    AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="complete"
    return 0
  fi

  if [ -n "$(trim_text "$missing_keys_csv")" ]; then
    local repaired_alias_status=0
    local previous_err_trap=""
    previous_err_trap="$(trap -p ERR || true)"
    set +e
    trap - ERR
    repair_metrics_compatibility_aliases "$METRICS_FILE" >/dev/null
    repaired_alias_status=$?
    set -e
    if [ -n "$previous_err_trap" ]; then
      eval "$previous_err_trap"
    fi
    if [ "$repaired_alias_status" -eq 0 ]; then
      AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED="true"
      local repaired_snapshot_status=""
      local repaired_complete_flag=""
      local repaired_reason=""
      local repaired_missing_keys_csv=""
      repaired_snapshot_status="$(inspect_metrics_snapshot "$registry_file")"
      repaired_complete_flag="$(printf '%s\n' "$repaired_snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
      repaired_reason="$(printf '%s\n' "$repaired_snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
      repaired_missing_keys_csv="$(printf '%s\n' "$repaired_snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"
      AUTOMATION_CONTEXT_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$repaired_missing_keys_csv")"
      if [ "$repaired_complete_flag" = "true" ]; then
        AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="refreshed"
        return 0
      fi
      reason="${repaired_reason:-$reason}"
      missing_keys_csv="${repaired_missing_keys_csv:-$missing_keys_csv}"
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="incomplete"
    AUTOMATION_CONTEXT_METRICS_INPUT_REASON="python3_unavailable"
    return 0
  fi

  if [ ! -f "$ROOT_DIR/scripts/sync-task-artifacts.py" ]; then
    AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="incomplete"
    AUTOMATION_CONTEXT_METRICS_INPUT_REASON="sync_task_artifacts_missing"
    return 0
  fi

  if python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" \
    "$registry_file" \
    "$TASK_LOG" \
    "$METRICS_FILE" \
    "$EXTERNAL_SIGNALS_FILE" >/dev/null 2>&1; then
    AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED="true"
    local refreshed_snapshot_status=""
    local refreshed_complete_flag=""
    local refreshed_reason=""
    local refreshed_missing_keys_csv=""
    refreshed_snapshot_status="$(inspect_metrics_snapshot "$registry_file")"
    refreshed_complete_flag="$(printf '%s\n' "$refreshed_snapshot_status" | awk -F '\t' 'NR==1 {print $2}')"
    refreshed_reason="$(printf '%s\n' "$refreshed_snapshot_status" | awk -F '\t' 'NR==1 {print $3}')"
    refreshed_missing_keys_csv="$(printf '%s\n' "$refreshed_snapshot_status" | awk -F '\t' 'NR==1 {print $4}')"
    AUTOMATION_CONTEXT_METRICS_INPUT_MISSING_KEYS_JSON="$(missing_keys_csv_to_json "$refreshed_missing_keys_csv")"
    if [ "$refreshed_complete_flag" = "true" ]; then
      AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="refreshed"
    else
      AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="incomplete"
      AUTOMATION_CONTEXT_METRICS_INPUT_REASON="${refreshed_reason:-missing_required_keys_after_refresh}"
    fi
    log_msg INFO prepare-automation-context "Refreshed persisted metrics before emitting automation context (reason=${reason:-unknown})"
    return 0
  fi

  AUTOMATION_CONTEXT_METRICS_INPUT_STATUS="refresh_failed"
  AUTOMATION_CONTEXT_METRICS_INPUT_REASON="${reason:-refresh_failed}"
  AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED="true"
}

ensure_runtime_dirs
ensure_project_state "$PROJECT_NAME"

AUTOMATION_ID="$(project_automation_id "$PROJECT_NAME")"
WORKSPACE="$(resolve_project_workspace "$PROJECT_NAME" 2>/dev/null || true)"
PROJECT_MEMORY_FILE="$(project_memory_file "$PROJECT_NAME" 2>/dev/null || true)"
PROJECT_SPEC_FILE="$(project_spec_file "$PROJECT_NAME" 2>/dev/null || true)"
PROJECT_POLICY_FILE="$(project_policy_file "$PROJECT_NAME" 2>/dev/null || true)"
PROJECT_TASK_REGISTRY_FILE="$(project_task_registry_file "$PROJECT_NAME" 2>/dev/null || true)"
if project_uses_shared_metrics_fallback "$PROJECT_NAME" "$METRICS_FILE"; then
  AUTOMATION_CONTEXT_SHARED_METRICS_FALLBACK="true"
fi
SELF_IMPROVE_RUN_FILE="${LEARNING_DIR:-$ROOT_DIR/codex-learning}/self-improve-run.json"
AUTOMATION_CONTEXT_AUTO_REFRESH_SELF_IMPROVE="${AUTOMATION_CONTEXT_AUTO_REFRESH_SELF_IMPROVE:-false}"
AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_ENABLED="false"
AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_PERFORMED="false"
AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS="not_requested"
AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_REASON="disabled"

refresh_metrics_snapshot_if_needed "${PROJECT_TASK_REGISTRY_FILE:-$TASK_REGISTRY_FILE}"

maybe_refresh_self_improve_artifact() {
  local stale_status=""
  local stale_flag=""
  local stale_reason=""
  local refresh_trigger="disabled"

  case "$(printf '%s' "$AUTOMATION_CONTEXT_AUTO_REFRESH_SELF_IMPROVE" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_ENABLED="true"
      refresh_trigger="explicit_request"
      ;;
  esac

  if [ "$AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED" = "true" ]; then
    AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_ENABLED="true"
    if [ "$refresh_trigger" = "disabled" ]; then
      refresh_trigger="metrics_input_refreshed"
    fi
  fi

  if [ "$refresh_trigger" = "disabled" ]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS="refresh_unavailable"
    AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_REASON="python3_unavailable"
    return 0
  fi

  inspect_self_improve_artifact_staleness() {
    python3 - "$METRICS_FILE" "$SELF_IMPROVE_RUN_FILE" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
artifact_path = Path(sys.argv[2])
threshold_seconds = 60


def parse_timestamp(value: object) -> float | None:
    text = str(value or "").strip()
    if not text:
        return None
    normalized = text.replace("Z", "+00:00")
    try:
        return __import__("datetime").datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return None


metrics_epoch = None
if metrics_path.is_file():
    try:
        metrics_epoch = metrics_path.stat().st_mtime
    except OSError:
        metrics_epoch = None

if not artifact_path.is_file():
    print("true\tself_improve_run_missing")
    raise SystemExit(0)

artifact_timestamp_candidates: list[float] = []
try:
    artifact_payload = json.loads(artifact_path.read_text(encoding="utf-8"))
except Exception:
    artifact_payload = {}
if isinstance(artifact_payload, dict):
    generated_epoch = parse_timestamp(artifact_payload.get("generated_at"))
    if generated_epoch is not None:
        artifact_timestamp_candidates.append(generated_epoch)
try:
    artifact_timestamp_candidates.append(artifact_path.stat().st_mtime)
except OSError:
    pass

if not artifact_timestamp_candidates:
    print("true\tartifact_timestamp_missing")
    raise SystemExit(0)

artifact_epoch = max(artifact_timestamp_candidates)
if metrics_epoch is not None and metrics_epoch > artifact_epoch + threshold_seconds:
    print("true\tmetrics_newer")
else:
    print("false\tup_to_date")
PY
  }

  stale_status="$(inspect_self_improve_artifact_staleness)"
  stale_flag="$(printf '%s\n' "$stale_status" | awk -F '\t' 'NR==1 {print $1}')"
  stale_reason="$(printf '%s\n' "$stale_status" | awk -F '\t' 'NR==1 {print $2}')"

  if [ "${stale_flag:-false}" != "true" ]; then
    AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS="not_needed"
    AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_REASON="${stale_reason:-up_to_date}"
    return 0
  fi

  AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_PERFORMED="true"
  AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_REASON="${stale_reason:-stale_detected}"
  if bash "$ROOT_DIR/scripts/self-improve.sh" "$PROJECT_NAME" >/dev/null 2>&1; then
    stale_status="$(inspect_self_improve_artifact_staleness)"
    stale_flag="$(printf '%s\n' "$stale_status" | awk -F '\t' 'NR==1 {print $1}')"
    if [ "${stale_flag:-false}" = "true" ]; then
      AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS="refresh_failed"
    else
      AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS="refreshed"
    fi
  else
    AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS="refresh_failed"
  fi
}

maybe_refresh_self_improve_artifact

AUTOMATION_MEMORY_FILE=""
AUTOMATION_MEMORY_SOURCE="none"
AUTOMATION_MEMORY_EXTERNAL_HYDRATED="false"
AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING="true"

if [ -n "$AUTOMATION_ID" ] && resolve_automation_memory_read_file "$PROJECT_NAME" "$AUTOMATION_ID" >/dev/null 2>&1; then
  AUTOMATION_MEMORY_FILE="${AUTOMATION_MEMORY_RESOLVED_FILE:-}"
  AUTOMATION_MEMORY_SOURCE="${AUTOMATION_MEMORY_RESOLVED_SOURCE:-none}"
  AUTOMATION_MEMORY_EXTERNAL_HYDRATED="${AUTOMATION_MEMORY_EXTERNAL_HYDRATED:-false}"
  AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING="${AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING:-true}"
fi

python3 - \
  "$PROJECT_NAME" \
  "$AUTOMATION_ID" \
  "$WORKSPACE" \
  "$PROJECT_MEMORY_FILE" \
  "$PROJECT_SPEC_FILE" \
  "$PROJECT_POLICY_FILE" \
  "$PROJECT_TASK_REGISTRY_FILE" \
  "$METRICS_FILE" \
  "$TASK_LOG" \
  "$SELF_IMPROVE_RUN_FILE" \
  "$AUTOMATION_MEMORY_FILE" \
  "$AUTOMATION_MEMORY_SOURCE" \
  "$AUTOMATION_MEMORY_EXTERNAL_HYDRATED" \
  "$AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING" \
  "$AUTOMATION_CONTEXT_METRICS_INPUT_STATUS" \
  "$AUTOMATION_CONTEXT_METRICS_INPUT_REASON" \
  "$AUTOMATION_CONTEXT_METRICS_INPUT_REFRESH_PERFORMED" \
  "$AUTOMATION_CONTEXT_METRICS_INPUT_MISSING_KEYS_JSON" \
  "$AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_ENABLED" \
  "$AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_PERFORMED" \
  "$AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_STATUS" \
  "$AUTOMATION_CONTEXT_SELF_IMPROVE_REFRESH_REASON" \
  "$RECENT_LINES" <<'PY'
import json
import sys
from pathlib import Path

(
    project_name,
    automation_id,
    workspace,
    project_memory_file,
    project_spec_file,
    project_policy_file,
    project_task_registry_file,
    metrics_file,
    task_log_file,
    self_improve_run_file,
    automation_memory_file,
    automation_memory_source,
    external_hydrated_raw,
    external_sync_pending_raw,
    metrics_input_status,
    metrics_input_reason,
    metrics_input_refresh_performed_raw,
    metrics_input_missing_keys_raw,
    self_improve_refresh_enabled_raw,
    self_improve_refresh_performed_raw,
    self_improve_refresh_status,
    self_improve_refresh_reason,
    recent_lines_raw,
) = sys.argv[1:]

recent_lines = max(int(recent_lines_raw or "8"), 0)
external_hydrated = external_hydrated_raw.strip().lower() == "true"
external_sync_pending = external_sync_pending_raw.strip().lower() == "true"
metrics_input_refresh_performed = metrics_input_refresh_performed_raw.strip().lower() == "true"
self_improve_refresh_enabled = self_improve_refresh_enabled_raw.strip().lower() == "true"
self_improve_refresh_performed = self_improve_refresh_performed_raw.strip().lower() == "true"
automation_memory_path = Path(automation_memory_file) if automation_memory_file else None
metrics_path = Path(metrics_file) if metrics_file else None
task_log_path = Path(task_log_file) if task_log_file else None
self_improve_run_path = Path(self_improve_run_file) if self_improve_run_file else None

SELF_IMPROVE_ARTIFACT_STALE_THRESHOLD_SECONDS = 60

try:
    metrics_input_missing_keys = json.loads(metrics_input_missing_keys_raw or "[]")
except Exception:
    metrics_input_missing_keys = []
if not isinstance(metrics_input_missing_keys, list):
    metrics_input_missing_keys = []

recent_entries: list[str] = []
if automation_memory_path and automation_memory_path.is_file():
    for raw_line in automation_memory_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if line.startswith("- "):
            recent_entries.append(line)
if recent_lines >= 0:
    recent_entries = recent_entries[-recent_lines:] if recent_lines else []


def parse_timestamp(value: object) -> float | None:
    text = str(value or "").strip()
    if not text:
        return None
    normalized = text.replace("Z", "+00:00")
    try:
        return __import__("datetime").datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return None


def isoformat_from_epoch(epoch: float | None) -> str:
    if epoch is None:
        return ""
    datetime_module = __import__("datetime")
    return datetime_module.datetime.fromtimestamp(
        epoch,
        datetime_module.timezone.utc,
    ).isoformat(timespec="seconds").replace("+00:00", "Z")


def first_non_empty_string(*values: object) -> str:
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def normalize_string_list(values: object, limit: int = 8) -> list[str]:
    if not isinstance(values, list):
        return []
    normalized: list[str] = []
    for value in values:
        text = str(value or "").strip()
        if text and text not in normalized:
            normalized.append(text)
        if len(normalized) >= limit:
            break
    return normalized


def build_self_improve_artifact_detail(payload: object) -> dict[str, object]:
    snapshot = payload if isinstance(payload, dict) else {}
    selection = snapshot.get("selection") if isinstance(snapshot.get("selection"), dict) else {}
    counts = snapshot.get("counts") if isinstance(snapshot.get("counts"), dict) else {}
    gating = snapshot.get("gating") if isinstance(snapshot.get("gating"), dict) else {}
    pause = snapshot.get("pause") if isinstance(snapshot.get("pause"), dict) else {}
    pause_escalation = pause.get("escalation") if isinstance(pause.get("escalation"), dict) else {}
    pause_remediation = pause.get("remediation") if isinstance(pause.get("remediation"), dict) else {}

    return {
        "generated_at": first_non_empty_string(snapshot.get("generated_at")),
        "selected_improvement": first_non_empty_string(
            snapshot.get("selected_improvement"),
            selection.get("selected_title"),
        ),
        "selection": {
            "selected_title": first_non_empty_string(
                selection.get("selected_title"),
                snapshot.get("selected_improvement"),
            ),
            "state": first_non_empty_string(selection.get("state"), "none"),
            "submitted_titles": normalize_string_list(selection.get("submitted_titles")),
            "ranked_titles": normalize_string_list(selection.get("ranked_titles")),
            "next_title": first_non_empty_string(selection.get("next_title")),
        },
        "counts": {
            "detected": max(safe_int(counts.get("detected")), 0),
            "generated": max(safe_int(counts.get("generated")), 0),
            "submitted": max(safe_int(counts.get("submitted")), 0),
            "skipped": max(safe_int(counts.get("skipped")), 0),
            "blocked_analysis": max(safe_int(counts.get("blocked_analysis")), 0),
        },
        "gating": {
            "dominant_reason": first_non_empty_string(gating.get("dominant_reason"), "none"),
            "analysis_reason": first_non_empty_string(gating.get("analysis_reason"), "none"),
            "submission_reason": first_non_empty_string(gating.get("submission_reason"), "none"),
        },
        "pause": {
            "active": pause.get("active") is True,
            "reason": first_non_empty_string(pause.get("reason"), "none"),
            "file": first_non_empty_string(pause.get("file")),
            "detected_at": first_non_empty_string(pause.get("detected_at")),
            "age_seconds": max(safe_int(pause.get("age_seconds")), 0),
            "escalation": {
                "active": pause_escalation.get("active") is True,
                "kind": first_non_empty_string(pause_escalation.get("kind"), "none"),
                "severity": first_non_empty_string(pause_escalation.get("severity"), "none"),
                "threshold_seconds": max(safe_int(pause_escalation.get("threshold_seconds")), 0),
                "title": first_non_empty_string(pause_escalation.get("title")),
                "summary": first_non_empty_string(pause_escalation.get("summary")),
            },
            "remediation": {
                "active": pause_remediation.get("active") is True,
                "kind": first_non_empty_string(pause_remediation.get("kind"), "none"),
                "title": first_non_empty_string(pause_remediation.get("title")),
                "summary": first_non_empty_string(pause_remediation.get("summary")),
                "command": first_non_empty_string(pause_remediation.get("command")),
            },
        },
    }


def build_self_improve_artifact_freshness() -> dict[str, object]:
    metrics_updated_at = ""
    metrics_epoch = None
    if metrics_path and metrics_path.is_file():
        try:
            metrics_epoch = metrics_path.stat().st_mtime
        except OSError:
            metrics_epoch = None
        metrics_updated_at = isoformat_from_epoch(metrics_epoch)

    if not self_improve_run_path or not self_improve_run_path.is_file():
        result = {
            "exists": False,
            "status": "missing",
            "stale": False,
            "reason": "self_improve_run_missing",
            "artifact_updated_at": "",
            "compared_source": "metrics.json" if metrics_updated_at else "",
            "compared_updated_at": metrics_updated_at,
            "remediation": {
                "active": True,
                "kind": "rerun_self_improve",
                "title": "Generate self-improve artifact",
                "summary": f"Run bash scripts/self-improve.sh {project_name} to create a fresh self-improve artifact.",
                "command": f"bash scripts/self-improve.sh {project_name}",
            },
        }
        result.update(build_self_improve_artifact_detail({}))
        return result

    artifact_timestamp_candidates: list[float] = []
    try:
        artifact_payload = json.loads(self_improve_run_path.read_text(encoding="utf-8"))
    except Exception:
        artifact_payload = {}
    artifact_detail = build_self_improve_artifact_detail(artifact_payload)
    if isinstance(artifact_payload, dict):
        generated_epoch = parse_timestamp(artifact_payload.get("generated_at"))
        if generated_epoch is not None:
            artifact_timestamp_candidates.append(generated_epoch)
    try:
        artifact_timestamp_candidates.append(self_improve_run_path.stat().st_mtime)
    except OSError:
        pass

    artifact_epoch = max(artifact_timestamp_candidates) if artifact_timestamp_candidates else None
    artifact_updated_at = isoformat_from_epoch(artifact_epoch)
    command = f"bash scripts/self-improve.sh {project_name}"

    if artifact_epoch is None:
        result = {
            "exists": True,
            "status": "unknown",
            "stale": False,
            "reason": "artifact_timestamp_missing",
            "artifact_updated_at": "",
            "compared_source": "metrics.json" if metrics_updated_at else "",
            "compared_updated_at": metrics_updated_at,
            "remediation": {
                "active": True,
                "kind": "rerun_self_improve",
                "title": "Refresh self-improve artifact",
                "summary": f"Run {command} to regenerate ranking details from current metrics.",
                "command": command,
            },
        }
        result.update(artifact_detail)
        return result

    if metrics_epoch is not None and metrics_epoch > artifact_epoch + SELF_IMPROVE_ARTIFACT_STALE_THRESHOLD_SECONDS:
        result = {
            "exists": True,
            "status": "stale",
            "stale": True,
            "reason": "metrics_newer",
            "artifact_updated_at": artifact_updated_at,
            "compared_source": "metrics.json",
            "compared_updated_at": metrics_updated_at,
            "remediation": {
                "active": True,
                "kind": "rerun_self_improve",
                "title": "Refresh self-improve artifact",
                "summary": f"Run {command} to regenerate ranking details from current metrics.",
                "command": command,
            },
        }
        result.update(artifact_detail)
        return result

    result = {
        "exists": True,
        "status": "current",
        "stale": False,
        "reason": "up_to_date",
        "artifact_updated_at": artifact_updated_at,
        "compared_source": "metrics.json" if metrics_updated_at else "",
        "compared_updated_at": metrics_updated_at,
        "remediation": {
            "active": False,
            "kind": "none",
            "title": "",
            "summary": "",
            "command": "",
        },
    }
    result.update(artifact_detail)
    return result


def normalize_text(value: object) -> str:
    return " ".join(str(value or "").strip().lower().split())


def normalize_project(value: object) -> str:
    return normalize_text(value) or "codex-agent-system"


def normalize_project_field(value: object) -> str:
    return normalize_text(value)


def safe_float(value: object, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def safe_int(value: object, fallback: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def read_json(path: Path, fallback: dict[str, object]) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        payload = fallback
    return payload if isinstance(payload, dict) else dict(fallback)


def read_json_lines(path: Path | None) -> list[dict[str, object]]:
    if path is None or not path.is_file():
        return []
    records: list[dict[str, object]] = []
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
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


def build_project_health_snapshot() -> dict[str, object]:
    metrics_payload = read_json(metrics_path, {}) if metrics_path and metrics_path.is_file() else {}
    registry_payload = (
        read_json(Path(project_task_registry_file), {"tasks": []})
        if project_task_registry_file and Path(project_task_registry_file).is_file()
        else {"tasks": []}
    )
    registry_tasks = registry_payload.get("tasks")
    if not isinstance(registry_tasks, list):
        registry_tasks = []
    task_log_records = read_json_lines(task_log_path)
    project_key = normalize_project(project_name)
    project_tasks = [
        task
        for task in registry_tasks
        if isinstance(task, dict)
        and normalize_project_field(task.get("project") or task.get("target_project")) == project_key
    ]
    project_records = [
        record
        for record in task_log_records
        if isinstance(record, dict)
        and normalize_project_field(record.get("project") or record.get("target_project")) == project_key
    ]

    if not project_tasks and not project_records:
        return {
            "scope": "global_fallback",
            "total_tasks": max(safe_int(metrics_payload.get("total_tasks")), 0),
            "success_rate": round(safe_float(metrics_payload.get("success_rate")), 2),
            "recent_success_rate": round(
                safe_float(metrics_payload.get("recent_success_rate", metrics_payload.get("success_rate"))),
                2,
            ),
            "timeout_failure_rate": round(
                safe_float(metrics_payload.get("timeout_failure_rate", metrics_payload.get("timeout_rate"))),
                2,
            ),
            "zero_step_timeout_rate": round(safe_float(metrics_payload.get("zero_step_timeout_rate")), 2),
            "first_pass_success_rate": round(safe_float(metrics_payload.get("first_pass_success_rate")), 2),
            "approved_tasks": max(safe_int(metrics_payload.get("approved_tasks")), 0),
            "pending_approval_tasks": max(safe_int(metrics_payload.get("pending_approval_tasks")), 0),
        }

    scripts_dir = Path.cwd() / "scripts"
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    try:
        from task_metrics import (
            build_first_pass_success_signal,
            build_latest_success_timestamp_by_identity,
            build_task_index_by_id,
            is_unresolved_timeout_record,
        )
    except Exception:
        build_first_pass_success_signal = None
        build_latest_success_timestamp_by_identity = None
        build_task_index_by_id = None
        is_unresolved_timeout_record = None

    total_tasks = len(project_records)
    success_rate = 0.0
    recent_success_rate = 0.0
    timeout_failure_rate = 0.0
    zero_step_timeout_rate = 0.0

    if project_records:
        success_count = sum(
            1 for record in project_records if str(record.get("result") or "").strip().upper() == "SUCCESS"
        )
        total_tasks = len(project_records)
        success_rate = round(success_count / total_tasks, 2) if total_tasks else 0.0
        recent_records = [
            record
            for record in project_records
            if str(record.get("result") or "").strip().upper() in {"SUCCESS", "FAILURE"}
        ][-50:]
        if recent_records:
            recent_success_rate = round(
                sum(1 for record in recent_records if str(record.get("result") or "").strip().upper() == "SUCCESS")
                / len(recent_records),
                2,
            )
        timeout_failure_events = [
            record
            for record in project_records
            if str(record.get("result") or "").strip().upper() == "FAILURE"
            and str(record.get("failure_kind") or "").strip().lower() == "timeout"
        ]
        if (
            project_tasks
            and build_task_index_by_id is not None
            and build_latest_success_timestamp_by_identity is not None
            and is_unresolved_timeout_record is not None
        ):
            tasks_by_id = build_task_index_by_id(project_tasks)
            latest_success_by_identity = build_latest_success_timestamp_by_identity(project_records)
            unresolved_timeouts = sum(
                1
                for record in project_records
                if is_unresolved_timeout_record(record, tasks_by_id, latest_success_by_identity)
            )
        else:
            unresolved_timeouts = len(timeout_failure_events)
        timeout_failure_rate = round(unresolved_timeouts / total_tasks, 2) if total_tasks else 0.0
        if timeout_failure_events:
            zero_step_timeout_rate = round(
                sum(1 for record in timeout_failure_events if safe_int(record.get("total_step_attempts")) == 0)
                / len(timeout_failure_events),
                2,
            )

    first_pass_success_rate = round(safe_float(metrics_payload.get("first_pass_success_rate")), 2)
    if project_tasks and build_first_pass_success_signal is not None:
        try:
            first_pass_signal = build_first_pass_success_signal(project_tasks, project_records)
        except Exception:
            first_pass_signal = {}
        successful_resolutions = max(safe_int(first_pass_signal.get("first_pass_success_count")), 0) + max(
            safe_int(first_pass_signal.get("multi_attempt_resolved_count")),
            0,
        )
        if successful_resolutions > 0:
            first_pass_success_rate = round(safe_float(first_pass_signal.get("first_pass_success_rate")), 2)

    if not total_tasks:
        total_tasks = len(project_tasks)
        recent_success_rate = success_rate

    return {
        "scope": "project_local",
        "total_tasks": max(total_tasks, 0),
        "success_rate": round(success_rate, 2),
        "recent_success_rate": round(recent_success_rate if total_tasks else success_rate, 2),
        "timeout_failure_rate": round(timeout_failure_rate, 2),
        "zero_step_timeout_rate": round(zero_step_timeout_rate, 2),
        "first_pass_success_rate": round(first_pass_success_rate, 2),
        "approved_tasks": sum(1 for task in project_tasks if str(task.get("status") or "").strip().lower() == "approved"),
        "pending_approval_tasks": sum(
            1 for task in project_tasks if str(task.get("status") or "").strip().lower() == "pending_approval"
        ),
    }


self_improve_artifact = build_self_improve_artifact_freshness()
project_health = build_project_health_snapshot()

payload = {
    "status": "success",
    "message": "Prepared automation context.",
    "data": {
        "project": {
            "name": project_name,
            "workspace": workspace,
        },
        "files": {
            "memory_file": project_memory_file,
            "metrics_file": metrics_file,
            "policy_file": project_policy_file,
            "self_improve_run_file": self_improve_run_file,
            "spec_file": project_spec_file,
            "task_registry_file": project_task_registry_file,
        },
        "automation_memory": {
            "exists": bool(automation_memory_file),
            "external_hydrated": external_hydrated,
            "external_sync_pending": external_sync_pending,
            "memory_file": automation_memory_file,
            "readable": bool(automation_memory_path and automation_memory_path.is_file()),
            "recent_entries": recent_entries,
            "requested_recent_entries": recent_lines,
            "source": automation_memory_source or "none",
        },
        "metrics_input": {
            "missing_keys": [
                str(item).strip()
                for item in metrics_input_missing_keys
                if str(item).strip()
            ],
            "reason": str(metrics_input_reason or "").strip() or "not_checked",
            "refresh_performed": metrics_input_refresh_performed,
            "status": str(metrics_input_status or "").strip() or "unknown",
        },
        "project_health": project_health,
        "self_improve_artifact_refresh": {
            "enabled": self_improve_refresh_enabled,
            "performed": self_improve_refresh_performed,
            "reason": str(self_improve_refresh_reason or "").strip() or "disabled",
            "status": str(self_improve_refresh_status or "").strip() or "not_requested",
        },
        "self_improve_artifact": self_improve_artifact,
    },
}

if automation_id:
    payload["data"]["project"]["automation_id"] = automation_id

print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
PY
