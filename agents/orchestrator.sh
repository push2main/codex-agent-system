#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
# Source hooks system if available
if [ -f "$ROOT_DIR/scripts/hooks.sh" ]; then
  source "$ROOT_DIR/scripts/hooks.sh"
fi
# Source dual-provider adapter if available
if [ -f "$ROOT_DIR/scripts/dual-provider.sh" ]; then
  source "$ROOT_DIR/scripts/dual-provider.sh"
fi
install_error_trap orchestrator

PROJECT_DIR="${1:-}"
TASK="${2:-}"
TASK_ID="${3:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ]; then
  echo "usage: orchestrator.sh <project_dir> <task> [task_id]" >&2
  exit 2
fi

require_command orchestrator jq
ensure_runtime_dirs
update_restart_needed_status_for_helper_scripts
mkdir -p "$PROJECT_DIR"
export TASK_ID

PROJECT_NAME="$(trim_text "${PROJECT_NAME:-$(basename "$PROJECT_DIR")}")"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$PROJECT_DIR")"
export PROJECT_NAME
ensure_project_state "$PROJECT_NAME"
PROJECT_MEMORY_FILE="$(project_memory_file "$PROJECT_NAME")"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

PLAN_FILE="$RUN_DIR/plan.json"
MEMORY_FILE="$RUN_DIR/memory.txt"
SUMMARY_FILE="$RUN_DIR/result.txt"
TASK_FILE="$RUN_DIR/task.txt"

printf '%s\n' "$TASK" >"$TASK_FILE"
write_status "running" "$PROJECT_NAME" "$TASK" "RUNNING" "run_id=$RUN_ID"
persist_runtime_session_state \
  "$PROJECT_NAME" \
  "$TASK" \
  "${TASK_ID:-$RUN_ID}" \
  "$RUN_ID" \
  "running" \
  "background" \
  "${TASK_PROVIDER:-}" \
  "" \
  "RUNNING" \
  "0" \
  "0" \
  ""
append_runtime_session_event \
  "$PROJECT_NAME" \
  "${TASK_ID:-$RUN_ID}" \
  "$RUN_ID" \
  "session_start" \
  "Task execution started." \
  "provider=${TASK_PROVIDER:-codex}"
log_msg INFO orchestrator "Starting task for $PROJECT_NAME: $TASK"

START_TIME="$(date +%s)"
BRANCH=""
PR_URL=""
SCORE=0
ATTEMPTS=0
TOTAL_STEP_ATTEMPTS=0
RESULT="FAILURE"
FAILED_STEP_INDEX=0
FAILED_STEP_TEXT=""
FAILURE_TIMESTAMP=""
ACTUAL_RUN_PROVIDER=""
LAST_AGENT_PROVIDER_ROLE=""
STEP_COUNT=0
COMPLETED_STEPS=0
TOTAL_SCORE=0
TASK_PROVIDER="$(resolve_task_provider_info "$PROJECT_NAME" "$TASK" | sed -n '1p')"
TASK_PROVIDER="$(normalize_provider_name "$TASK_PROVIDER")"
[ -n "$TASK_PROVIDER" ] || TASK_PROVIDER="codex"
# Dual-provider: check availability and select optimal provider
if command -v check_provider_availability >/dev/null 2>&1; then
  check_provider_availability
  EFFECTIVE_PROVIDER="$(select_optimal_provider "$TASK" "" "" "$TASK_PROVIDER" 2>/dev/null || printf '%s' "$TASK_PROVIDER")"
  log_msg INFO orchestrator "Provider selection: base=$TASK_PROVIDER effective=$EFFECTIVE_PROVIDER"
else
  EFFECTIVE_PROVIDER="$TASK_PROVIDER"
fi
persist_runtime_session_state \
  "$PROJECT_NAME" \
  "$TASK" \
  "${TASK_ID:-$RUN_ID}" \
  "$RUN_ID" \
  "running" \
  "background" \
  "$EFFECTIVE_PROVIDER" \
  "" \
  "RUNNING" \
  "0" \
  "0" \
  ""

task_log_failure_kind() {
  if [ "$RESULT" != "FAILURE" ]; then
    return 0
  fi

  if [ -n "$(trim_text "${failure_kind_tag:-}")" ]; then
    printf '%s' "$(trim_text "${failure_kind_tag:-}")"
    return 0
  fi

  if [ "${FAILED_STEP_INDEX:-0}" -gt 0 ] || [ -n "$(trim_text "${FAILED_STEP_TEXT:-}")" ]; then
    # Prefer the classified failure category over generic "step_failure"
    # when classify_failure has already run and produced a specific category.
    local classified_cat="${failure_category:-}"
    if [ -n "$(trim_text "$classified_cat")" ] && [ "$classified_cat" != "unknown" ]; then
      printf '%s' "$classified_cat"
    else
      printf '%s' "step_failure"
    fi
    return 0
  fi

  if [ "${STEP_COUNT:-0}" -lt 1 ] || [ "${STEP_COUNT:-0}" -gt 8 ]; then
    printf '%s' "planning_failure"
    return 0
  fi

  # Check if this looks like a timeout based on duration
  local elapsed=0
  if [ -n "${START_TIME:-}" ]; then
    elapsed=$(( $(date +%s) - START_TIME ))
  fi
  if [ "$elapsed" -ge "${TASK_TIMEOUT_SECONDS:-420}" ]; then
    printf '%s' "timeout"
    return 0
  fi

  # Always return something — "none" or empty is not acceptable
  printf '%s' "execution_failure"
}

append_task_record() {
  local duration="$1"
  local failure_kind=""
  local failed_step_index="0"
  local failed_step_text=""
  local recorded_provider=""

  if [ "$RESULT" = "FAILURE" ]; then
    failure_kind="$(task_log_failure_kind)"
    failed_step_index="${FAILED_STEP_INDEX:-0}"
    failed_step_text="$(trim_text "$FAILED_STEP_TEXT")"
    # Ensure diagnostic text is never empty for failures — extract from run artifacts
    if [ -z "$failed_step_text" ] && [ -d "$RUN_DIR" ]; then
      # Try plan.json for planner-level errors
      if [ -f "$RUN_DIR/plan.json" ]; then
        local plan_msg
        plan_msg="$(json_get "$RUN_DIR/plan.json" '.message // ""' 2>/dev/null | head -c 300 || true)"
        [ -n "$(trim_text "$plan_msg")" ] && failed_step_text="plan: $plan_msg"
      fi
      # Try failure-classification.json
      if [ -z "$failed_step_text" ] && [ -f "$RUN_DIR/failure-classification.json" ]; then
        local fc_reason
        fc_reason="$(json_get "$RUN_DIR/failure-classification.json" '.reason // ""' 2>/dev/null | head -c 300 || true)"
        [ -n "$(trim_text "$fc_reason")" ] && failed_step_text="classified: $fc_reason"
      fi
      # Last resort: scan coder logs for error lines
      if [ -z "$failed_step_text" ]; then
        for logfile in "$RUN_DIR"/*.codex.log "$RUN_DIR"/*.claude.log; do
          [ -f "$logfile" ] || continue
          local log_errors
          log_errors="$(grep -i 'error\|fail\|timeout\|exception' "$logfile" 2>/dev/null | head -3 | tr '\n' ' ' | head -c 300 || true)"
          if [ -n "$(trim_text "$log_errors")" ]; then
            failed_step_text="log: $log_errors"
            break
          fi
        done
      fi
      [ -z "$failed_step_text" ] && failed_step_text="failure_kind=$failure_kind duration=${duration}s steps=${COMPLETED_STEPS:-0}/${STEP_COUNT:-0}"
    fi
  fi

  recorded_provider="$(resolved_run_provider)"

  append_task_log_record \
    "$PROJECT_NAME" \
    "$TASK" \
    "$RESULT" \
    "$ATTEMPTS" \
    "$SCORE" \
    "$BRANCH" \
    "$PR_URL" \
    "$RUN_ID" \
    "$duration" \
    "$recorded_provider" \
    "$failure_kind" \
    "$TOTAL_STEP_ATTEMPTS" \
    "$TASK_ID" \
    "$failed_step_index" \
    "$failed_step_text"
}

record_agent_execution_provider() {
  local role="$1"
  local output_file="$2"
  local provider=""

  provider="$(read_agent_exec_metadata_field "$output_file" "provider")"
  provider="$(normalize_provider_name "$provider")"
  if [ -n "$provider" ]; then
    ACTUAL_RUN_PROVIDER="$provider"
    LAST_AGENT_PROVIDER_ROLE="$role"
  fi
}

resolved_run_provider() {
  local provider=""

  provider="$(normalize_provider_name "${ACTUAL_RUN_PROVIDER:-}")"
  if [ -n "$provider" ]; then
    printf '%s\n' "$provider"
    return 0
  fi

  provider="$(normalize_provider_name "${TASK_PROVIDER:-}")"
  if [ -n "$provider" ]; then
    printf '%s\n' "$provider"
    return 0
  fi

  printf '%s\n' "codex"
}

refresh_run_monitoring_artifacts() {
  local final_state="$1"
  local metrics_payload=""
  local incident_id=""
  local incident_failure_kind=""
  local incident_message=""
  local incident_payload=""
  local CRA_COMPLIANCE_FILE=""
  local cra_base_payload=""
  local cra_existing_payload=""
  local cra_artifacts_dir=""
  local project_id=""
  local spec_file=""
  local policy_file=""
  local task_registry_file=""
  local spec_present="false"
  local policy_present="false"
  local task_registry_present="false"

  sync_task_artifacts || true

  if [ -f "$METRICS_FILE" ]; then
    metrics_payload="$(cat "$METRICS_FILE" 2>/dev/null || true)"
  fi

  incident_failure_kind="${failure_kind_tag:-}"
  if [ -z "$(trim_text "$incident_failure_kind")" ] && [ "$RESULT" = "FAILURE" ]; then
    incident_failure_kind="$(task_log_failure_kind)"
  fi

  if [ "$RESULT" = "SUCCESS" ]; then
    incident_message="Task completed successfully."
  else
    incident_message="$(trim_text "$FAILED_STEP_TEXT")"
    [ -n "$incident_message" ] || incident_message="Task failed."
  fi
  incident_id="$(trim_text "$RUN_ID")"
  [ -n "$incident_id" ] || incident_id="$(trim_text "${TASK_ID:-}")"
  [ -n "$incident_id" ] || incident_id="incident-$(date +%s)"

  incident_payload="$(classify_incident_record \
    "$RESULT" \
    "$final_state" \
    "$incident_failure_kind" \
    "$incident_message" \
    "$metrics_payload" 2>/dev/null || true)"

  if [ -n "$(trim_text "$incident_payload")" ]; then
    incident_payload="$(printf '%s' "$incident_payload" | jq -c \
      --arg incident_id "$incident_id" \
      '. + {
        id: $incident_id,
        actions: [
          {id: "block", label: "Block", method: "POST", path: ("/api/incidents/" + $incident_id + "/block")},
          {id: "allow", label: "Allow", method: "POST", path: ("/api/incidents/" + $incident_id + "/allow")},
          {id: "details", label: "Details", method: "GET", path: ("/incidents/" + $incident_id)}
        ]
      }' 2>/dev/null || true)"
    incident_failure_kind="$(printf '%s' "$incident_payload" | jq -r '.failure_kind // ""' 2>/dev/null || printf '%s' "$incident_failure_kind")"
  fi

  python3 - "$INCIDENT_LOG_FILE" "$(now_utc)" "$PROJECT_NAME" "$incident_id" "$RESULT" "$final_state" "$incident_failure_kind" "$incident_message" "$metrics_payload" <<'PY' || true
import json
import sys
from pathlib import Path

(
    incident_log_path,
    timestamp,
    project_id,
    incident_id,
    result,
    run_state,
    failure_kind,
    message,
    metrics_payload,
) = sys.argv[1:]


def normalize_text(value: str) -> str:
    return " ".join(str(value or "").split())


def parse_metrics(raw: str) -> dict:
    text = str(raw or "").strip()
    if not text:
        return {}
    try:
        payload = json.loads(text)
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


incident_id = normalize_text(incident_id) or normalize_text(timestamp)
record = {
    "actions": [
        {"id": "block", "label": "Block", "method": "POST", "path": f"/api/incidents/{incident_id}/block"},
        {"id": "allow", "label": "Allow", "method": "POST", "path": f"/api/incidents/{incident_id}/allow"},
        {"id": "details", "label": "Details", "method": "GET", "path": f"/incidents/{incident_id}"},
    ],
    "failure_kind": normalize_text(failure_kind).lower() or "unknown",
    "id": incident_id,
    "message": normalize_text(message),
    "metrics": parse_metrics(metrics_payload),
    "project_id": normalize_text(project_id),
    "result": normalize_text(result).upper() or "UNKNOWN",
    "run_state": normalize_text(run_state).lower() or "unknown",
    "timestamp": normalize_text(timestamp),
}

path = Path(incident_log_path)
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
PY
  write_alerts_payload "$PROJECT_NAME" "$metrics_payload" || true

  project_id="$(read_project_metadata_field_raw "$PROJECT_NAME" "project_id")"
  [ -n "$(trim_text "$project_id")" ] || project_id="$PROJECT_NAME"
  spec_file="$(project_spec_file "$PROJECT_NAME")"
  policy_file="$(project_policy_file "$PROJECT_NAME")"
  task_registry_file="$(project_task_registry_file "$PROJECT_NAME")"
  cra_artifacts_dir="$PROJECT_DIR/.codex-agent"
  CRA_COMPLIANCE_FILE="$(resolve_setting "cra_compliance_file" "cra-compliance.json" "$PROJECT_NAME")"
  CRA_COMPLIANCE_FILE="$(trim_text "$CRA_COMPLIANCE_FILE")"
  if [ -z "$CRA_COMPLIANCE_FILE" ]; then
    CRA_COMPLIANCE_FILE="$cra_artifacts_dir/cra-compliance.json"
  elif [[ "$CRA_COMPLIANCE_FILE" = "$cra_artifacts_dir/"* ]]; then
    :
  elif [[ "$CRA_COMPLIANCE_FILE" = .codex-agent/* ]]; then
    CRA_COMPLIANCE_FILE="$PROJECT_DIR/$CRA_COMPLIANCE_FILE"
  else
    CRA_COMPLIANCE_FILE="$cra_artifacts_dir/${CRA_COMPLIANCE_FILE##*/}"
  fi

  if [ -f "$spec_file" ]; then
    spec_present="true"
  fi
  if [ -f "$policy_file" ]; then
    policy_present="true"
  fi
  if [ -f "$task_registry_file" ]; then
    task_registry_present="true"
  fi

  if command -v default_cra_compliance_payload >/dev/null 2>&1; then
    cra_base_payload="$(default_cra_compliance_payload 2>/dev/null || true)"
  fi
  if [ -z "$(trim_text "$cra_base_payload")" ]; then
    cra_base_payload='{
  "updated_at": "",
  "project_id": "",
  "project_name": "",
  "project_root": "",
  "framework": "EU Cyber Resilience Act",
  "status": "incomplete",
  "missing_artifacts": [],
  "incident_summary": {
    "severity": "unknown",
    "failure_kind": "unknown",
    "message": "No incident recorded."
  },
  "supply_chain_controls": {
    "spec_present": false,
    "policy_present": false,
    "task_registry_present": false
  },
  "evidence": []
}'
  fi

  if [ -f "$CRA_COMPLIANCE_FILE" ]; then
    cra_existing_payload="$(cat "$CRA_COMPLIANCE_FILE" 2>/dev/null || true)"
  fi

  if ! python3 - "$CRA_COMPLIANCE_FILE" "$cra_base_payload" "$cra_existing_payload" "$(now_utc)" "$project_id" "$PROJECT_NAME" "$PROJECT_DIR" "$final_state" "$spec_file" "$spec_present" "$policy_file" "$policy_present" "$task_registry_file" "$task_registry_present" "$incident_payload" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    base_payload,
    existing_payload,
    timestamp,
    project_id,
    project_name,
    project_root,
    run_state,
    spec_file,
    spec_present,
    policy_file,
    policy_present,
    task_registry_file,
    task_registry_present,
    incident_payload,
) = sys.argv[1:]


def parse_json(raw: str, fallback):
    text = str(raw or "").strip()
    if not text:
        return fallback
    try:
        parsed = json.loads(text)
    except Exception:
        return fallback
    return parsed


def normalize_text(value: str) -> str:
    return " ".join(str(value or "").split())


def normalize_bool(value: str) -> bool:
    return normalize_text(value).lower() == "true"


payload = {}
base = parse_json(base_payload, {})
if isinstance(base, dict):
    payload.update(base)

existing = parse_json(existing_payload, {})
if not isinstance(existing, dict):
    existing = {}
payload.update(existing)

spec_exists = normalize_bool(spec_present)
policy_exists = normalize_bool(policy_present)
task_registry_exists = normalize_bool(task_registry_present)
incident = parse_json(incident_payload, {})
if not isinstance(incident, dict):
    incident = {}
last_incident = payload.get("last_incident")
if not isinstance(last_incident, dict):
    last_incident = {}

missing_artifacts: list[str] = []
for present, artifact_path in (
    (spec_exists, spec_file),
    (policy_exists, policy_file),
    (task_registry_exists, task_registry_file),
):
    if not present:
        normalized_path = normalize_text(artifact_path)
        if normalized_path:
            missing_artifacts.append(normalized_path)

incident_summary = payload.get("incident_summary")
if not isinstance(incident_summary, dict):
    incident_summary = {}
incident_severity = normalize_text(
    incident.get("severity")
    or incident_summary.get("severity")
    or last_incident.get("severity")
    or "unknown"
).lower() or "unknown"
incident_failure_kind = normalize_text(
    incident.get("failure_kind")
    or incident_summary.get("failure_kind")
    or last_incident.get("failure_kind")
    or "unknown"
).lower() or "unknown"
incident_message = normalize_text(
    incident.get("failure_text")
    or incident.get("message")
    or incident_summary.get("message")
    or last_incident.get("message")
    or "No incident recorded."
)
incident_type = normalize_text(
    incident.get("incident_type")
    or incident_summary.get("incident_type")
    or last_incident.get("incident_type")
)

review_failure_kinds = {
    "approval_blocked",
    "context_limit",
    "execution_failure",
    "execution_timeout",
    "planning_failure",
    "provider_failure",
    "review_blocked",
    "sandbox_restriction",
    "step_failure",
    "task_failure",
    "tool_failure",
}

status = "documented"
if missing_artifacts:
    status = "incomplete"
elif incident_severity in {"critical", "high", "medium", "warning"} or incident_failure_kind in review_failure_kinds:
    status = "review_required"

payload["updated_at"] = normalize_text(timestamp)
payload["project_id"] = normalize_text(project_id)
payload["project_name"] = normalize_text(project_name) or normalize_text(project_id)
payload["project_root"] = normalize_text(project_root)
payload["framework"] = normalize_text(payload.get("framework") or "EU Cyber Resilience Act")
payload["run_state"] = normalize_text(run_state).lower() or "unknown"
payload["status"] = status
payload["missing_artifacts"] = missing_artifacts
payload["supply_chain_controls"] = {
    "spec_present": spec_exists,
    "policy_present": policy_exists,
    "task_registry_present": task_registry_exists,
}
payload["incident_summary"] = {
    "severity": incident_severity,
    "failure_kind": incident_failure_kind,
    "incident_type": incident_type,
    "message": incident_message,
    "run_state": normalize_text(incident.get("run_state") or payload["run_state"]).lower() or "unknown",
}
payload["evidence"] = [
    {"artifact": "spec_file", "path": normalize_text(spec_file), "present": spec_exists},
    {"artifact": "policy_file", "path": normalize_text(policy_file), "present": policy_exists},
    {
        "artifact": "task_registry_file",
        "path": normalize_text(task_registry_file),
        "present": task_registry_exists,
    },
]
payload["last_incident"] = dict(payload["incident_summary"])

path = Path(output_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  then
    printf '%s\n' "CRA compliance artifact write failed: $CRA_COMPLIANCE_FILE" >&2
  fi
}

persist_final_run_context() {
  local duration="$1"
  local normalized_result
  local normalized_run_id
  local normalized_attempts
  local normalized_score
  local normalized_failed_step_index
  local normalized_failed_step_text
  local normalized_provider
  local normalized_failure_timestamp
  local normalized_failure_kind

  if [ "$RESULT" = "FAILURE" ]; then
    # Persist terminal failure evidence before slower bookkeeping so queue timeout
    # reconciliation can still recover the exact outcome if finalize_run is cut off.
    normalized_result="$(trim_text "$RESULT")"
    [ -n "$normalized_result" ] || normalized_result="FAILURE"
    normalized_run_id="$(trim_text "$RUN_ID")"
    normalized_attempts="${ATTEMPTS:-0}"
    normalized_score="${SCORE:-0}"
    normalized_failed_step_index="${FAILED_STEP_INDEX:-0}"
    normalized_failed_step_text="$(trim_text "$FAILED_STEP_TEXT")"
    normalized_provider="$(resolved_run_provider)"
    [ -n "$normalized_provider" ] || normalized_provider="codex"
    normalized_failure_timestamp="$(trim_text "$FAILURE_TIMESTAMP")"
    [ -n "$normalized_failure_timestamp" ] || normalized_failure_timestamp="$(now_utc)"
    normalized_failure_kind="$(trim_text "${failure_kind_tag:-}")"
    FAILURE_TIMESTAMP="$normalized_failure_timestamp"
    persist_task_run_context \
      "$PROJECT_NAME" \
      "$TASK" \
      "$normalized_result" \
      "$normalized_run_id" \
      "$normalized_attempts" \
      "$TOTAL_STEP_ATTEMPTS" \
      "$normalized_score" \
      "$duration" \
      "$STEP_COUNT" \
      "$COMPLETED_STEPS" \
      "$normalized_failed_step_index" \
      "$normalized_failed_step_text" \
      "$PLAN_FILE" \
      "$normalized_provider" \
      "$normalized_failure_timestamp" \
      "$TASK_ID" \
      "$normalized_failure_kind" || true
    return 0
  fi

  persist_task_run_context \
    "$PROJECT_NAME" \
    "$TASK" \
    "$RESULT" \
    "$RUN_ID" \
    "$ATTEMPTS" \
    "$TOTAL_STEP_ATTEMPTS" \
    "$SCORE" \
    "$duration" \
    "$STEP_COUNT" \
    "$COMPLETED_STEPS" \
    "0" \
    "" \
    "$PLAN_FILE" \
    "$(resolved_run_provider)" \
    "" \
    "$TASK_ID" \
    "" || true
}

append_memory_notes() {
  local duration="$1"
  local entry_timestamp
  entry_timestamp="$(now_utc)"
  {
    printf -- '- %s | task=%s | result=%s | score=%s | attempts=%s | duration=%ss | run=%s\n' "$entry_timestamp" "$TASK" "$RESULT" "$SCORE" "$ATTEMPTS" "$duration" "$RUN_ID"
    [ -n "$BRANCH" ] && printf '  branch: %s\n' "$BRANCH"
    [ -n "$PR_URL" ] && printf '  pr: %s\n' "$PR_URL"
    [ -n "$FAILED_STEP_TEXT" ] && printf '  failed_step: %s\n' "$FAILED_STEP_TEXT"
    printf '\n'
  } >>"$PROJECT_MEMORY_FILE"

  if [ "$RESULT" = "FAILURE" ] || [ -n "$FAILED_STEP_TEXT" ]; then
    {
      printf -- '- %s | project=%s | result=%s | score=%s | attempts=%s | duration=%ss\n' "$entry_timestamp" "$PROJECT_NAME" "$RESULT" "$SCORE" "$ATTEMPTS" "$duration"
      printf '  task: %s\n' "$TASK"
      [ -n "$FAILED_STEP_TEXT" ] && printf '  failed_step: %s\n' "$FAILED_STEP_TEXT"
      [ -n "$BRANCH" ] && printf '  branch: %s\n' "$BRANCH"
      [ -n "$PR_URL" ] && printf '  pr: %s\n' "$PR_URL"
      printf '\n'
    } >>"$PROJECT_MEMORY_FILE"
  fi

  {
    printf -- '- %s | project=%s | result=%s | score=%s | attempts=%s | duration=%ss\n' "$entry_timestamp" "$PROJECT_NAME" "$RESULT" "$SCORE" "$ATTEMPTS" "$duration"
    printf '  task: %s\n' "$TASK"
    [ -n "$FAILED_STEP_TEXT" ] && printf '  failed_step: %s\n' "$FAILED_STEP_TEXT"
    [ -n "$BRANCH" ] && printf '  branch: %s\n' "$BRANCH"
    [ -n "$PR_URL" ] && printf '  pr: %s\n' "$PR_URL"
    printf '\n'
  } >>"$DECISIONS_FILE"

  {
    printf -- '- %s | %s | %s\n' "$entry_timestamp" "$PROJECT_NAME" "$TASK"
    printf '  result: %s\n' "$RESULT"
    printf '  run: %s\n' "$RUN_ID"
    printf '\n'
  } >>"$CONTEXT_FILE"
}

synthesize_agent_failure() {
  local role="$1"
  local output_file="$2"
  local message="$3"
  local status

  case "$role" in
    reviewer) status="retry" ;;
    *) status="fail" ;;
  esac

  write_json_file "$output_file" "$status" "$message" "$(jq -cn --arg role "$role" '{role:$role}')"
}

resolve_failed_step_text() {
  local default_step="$1"
  local coder_output_file="${2:-}"
  local reviewer_output_file="${3:-}"
  local task_guidance="${4:-}"

  python3 - "$default_step" "$coder_output_file" "$reviewer_output_file" "$task_guidance" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


default_step = str(sys.argv[1] or "").strip()
coder_output_path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
reviewer_output_path = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
task_guidance = str(sys.argv[4] or "").strip()


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def unwrap_retry_step(value: str) -> str:
    normalized = normalize_text(value)
    if not normalized:
        return ""
    match = re.search(
        r"ORIGINAL STEP:\s*(.+?)(?:\s+PREVIOUS FAILURE DETAILS:|\s+MANDATORY RULES FOR THIS RETRY:|$)",
        normalized,
        flags=re.IGNORECASE,
    )
    if match:
        return normalize_text(match.group(1))
    return normalized


def is_generic_step(value: str) -> bool:
    normalized = unwrap_retry_step(value).lower().rstrip(".")
    return normalized == "implement the requested change with minimal modifications"


def safe_read_json(path: Path | None) -> dict:
    if path is None or not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def extract_error_context(payload: dict) -> str:
    """Extract error/failure context from coder or reviewer JSON output."""
    candidates = []
    # Check common error fields
    for key in ("message", "error", "stderr"):
        val = unwrap_retry_step(payload.get(key, ""))
        if val and len(val) > 10:
            candidates.append(val[:300])
    # Check nested data fields
    data = payload.get("data") or {}
    for key in ("summary", "error", "step", "reason", "output"):
        val = unwrap_retry_step(data.get(key, ""))
        if val and len(val) > 10:
            candidates.append(val[:300])
    return " | ".join(candidates[:3]) if candidates else ""


default_step = unwrap_retry_step(default_step)
task_guidance = unwrap_retry_step(task_guidance)
resolved = default_step
coder_payload = safe_read_json(coder_output_path)

if is_generic_step(default_step):
    guidance_candidate = unwrap_retry_step(task_guidance)
    if guidance_candidate and not is_generic_step(guidance_candidate):
        resolved = guidance_candidate

# Upgrade generic step text from coder output
if is_generic_step(default_step):
    candidate = unwrap_retry_step(((coder_payload.get("data") or {}).get("step") or ""))
    if candidate and not is_generic_step(candidate):
        resolved = candidate

# If still empty or generic, try to extract error context from coder output
if not resolved or is_generic_step(resolved):
    error_ctx = extract_error_context(coder_payload)
    if error_ctx:
        resolved = f"coder_error: {error_ctx}"

# If still empty, try reviewer output
if not resolved or is_generic_step(resolved):
    reviewer_payload = safe_read_json(reviewer_output_path)
    error_ctx = extract_error_context(reviewer_payload)
    if error_ctx:
        resolved = f"reviewer_error: {error_ctx}"

# Final fallback: if we have a non-empty default_step, use it
if not resolved:
    resolved = default_step or "no_diagnostic_context_available"

print(resolved[:500])
PY
}

is_generic_implementation_step_value() {
  local normalized_step
  normalized_step="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/[.]$//; s/ $//')"
  [ "$normalized_step" = "implement the requested change with minimal modifications" ]
}

build_orchestrator_task_step_guidance() {
  local task_text="${1:-}"
  local project_name="${2:-}"
  local task_id="${3:-}"
  local similar_tasks="[]"

  similar_tasks="$(build_similar_task_context "$task_text" "$project_name" "$task_id" 2>/dev/null || printf '[]')"

  python3 - "$similar_tasks" "$task_text" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


similar_raw = sys.argv[1]
fallback_task = sys.argv[2]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_list(value: Any, *, limit: int = 3) -> list[str]:
    if not isinstance(value, list):
        return []
    items: list[str] = []
    for entry in value:
        normalized = normalize_text(entry)
        if not normalized or normalized in items:
            continue
        items.append(normalized)
        if len(items) >= limit:
            break
    return items


def pick_current_task(tasks: Any) -> dict[str, Any] | None:
    if not isinstance(tasks, list):
        return None
    for task in tasks:
        if isinstance(task, dict) and task.get("current_task") is True:
            return task
    return None


def task_intent_payload(task: dict[str, Any]) -> dict[str, Any]:
    task_intent = task.get("task_intent")
    if isinstance(task_intent, dict):
        return task_intent
    execution_brief = task.get("execution_brief")
    if isinstance(execution_brief, dict):
        brief_intent = execution_brief.get("task_intent")
        if isinstance(brief_intent, dict):
            return brief_intent
    return {}


def intent_implementation_step(task: dict[str, Any], fallback_task_text: str) -> str:
    task_intent = task_intent_payload(task)
    if not task_intent:
        return ""

    objective = normalize_text(task_intent.get("objective") or task.get("title") or fallback_task_text)
    if not objective:
        return ""

    affected_files = normalize_list(task_intent.get("affected_files"))
    constraints = normalize_list(task_intent.get("constraints"))
    context_hint = normalize_text(task_intent.get("context_hint"))

    file_scope = ""
    if affected_files:
        tick = chr(96)
        formatted_files = ", ".join(f"{tick}{path}{tick}" for path in affected_files)
        file_scope = f"In {formatted_files}, "

    step = f"{file_scope}implement the smallest safe change for: {objective}."
    if context_hint:
        step += f" Focus on {context_hint.rstrip('.')}."
    if constraints:
        step += " Keep these constraints: " + "; ".join(constraint.rstrip(".") for constraint in constraints) + "."
    return step


try:
    similar_tasks = json.loads(similar_raw)
except Exception:
    similar_tasks = []

current_task = pick_current_task(similar_tasks)
if not isinstance(current_task, dict):
    raise SystemExit(0)

step = intent_implementation_step(current_task, fallback_task)
if step:
    print(step[:500])
PY
}

run_agent_script() {
  local role="$1"
  local script_path="$2"
  local stdout_file="$3"
  local output_file="$4"
  shift 4

  # Per-step timeout: cap each agent invocation to prevent single steps from
  # consuming the entire task budget. This is the primary fix for zero-step
  # timeouts where the planner completes in <60s but coder.sh runs for 500-800s.
  # Budget: min(180s, 70% of remaining task budget). Most successful steps
  # complete in <60s; 180s is generous but prevents runaway execution.
  local step_timeout=180
  if [ -n "${START_TIME:-}" ] && [ -n "${resolved_timeout:-}" ]; then
    local now_ts
    now_ts="$(date +%s)"
    local remaining=$(( resolved_timeout - (now_ts - START_TIME) ))
    local budget_cap=$(( remaining * 70 / 100 ))
    if [ "$budget_cap" -gt 0 ] && [ "$budget_cap" -lt "$step_timeout" ]; then
      step_timeout="$budget_cap"
    fi
    # Minimum 30s to allow any meaningful work
    if [ "$step_timeout" -lt 30 ]; then
      step_timeout=30
    fi
  fi

  local rc=0
  if python3 "$ROOT_DIR/scripts/run-with-timeout.py" \
    "$step_timeout" \
    bash "$script_path" "$@" \
    >"$stdout_file" 2>&1; then
    record_agent_execution_provider "$role" "$output_file"
    if validate_agent_json "$output_file"; then
      return 0
    fi
    log_msg ERROR orchestrator "$role produced invalid JSON; synthesizing failure response"
  else
    rc=$?
    record_agent_execution_provider "$role" "$output_file"
    if [ "$rc" -eq 124 ]; then
      log_msg WARN orchestrator "$role timed out after ${step_timeout}s — failing step to preserve budget"
      synthesize_agent_failure "$role" "$output_file" "$role timed out after ${step_timeout}s"
      return 124
    fi
    log_msg ERROR orchestrator "$role exited with code $rc; synthesizing failure response"
  fi

  synthesize_agent_failure "$role" "$output_file" "$role failed unexpectedly."
  return 1
}

fail_low_completion_run() {
  local completion="$1"
  local threshold="$2"
  local reason="$3"
  local failure_reason="${reason:-unspecified reason}"
  local failure_note=""
  local planned_failed_step_text=""

  if [ "$failure_reason" = "empty_executable_work_after_low_completion" ] && [ -n "$completion" ] && [ -n "$threshold" ] && awk "BEGIN { exit !($completion < $threshold) }"; then
    planned_failed_step_text="$(jq -r '.data.steps[0] // ""' "$PLAN_FILE" 2>/dev/null || printf '')"
    FAILED_STEP_INDEX="1"
    if [ -n "$(trim_text "$planned_failed_step_text")" ]; then
      FAILED_STEP_TEXT="$planned_failed_step_text"
    else
      FAILED_STEP_TEXT="Low-completion gate failed: reason=empty_executable_work_after_low_completion completion=${completion} threshold=${threshold}"
    fi
    FAILURE_TIMESTAMP="$(now_utc)"
  fi

  fail_low_completion_gate "$completion" "$threshold" "$reason" || true
  FAILED_STEP_INDEX="${FAILED_STEP_INDEX:-0}"
  FAILED_STEP_TEXT="${FAILED_STEP_TEXT:-Low-completion gate failed: completion=${completion:-unknown} threshold=${threshold:-unknown} reason=${failure_reason}}"
  FAILURE_TIMESTAMP="${FAILURE_TIMESTAMP:-$(now_utc)}"
  RESULT="FAILURE"
  failure_note="Low-completion gate failed before execution retries because completion=${completion:-unknown} stayed below threshold=${threshold:-unknown} and ${failure_reason}."
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "failed" \
    "execute_failure" \
    "$failure_note" \
    "0" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "" \
    "$FAILED_STEP_TEXT" \
    "$FAILED_STEP_INDEX" \
    "$TASK_ID" || true
  write_status "failed" "$PROJECT_NAME" "$TASK" "$RESULT" "run_id=$RUN_ID reason=low_completion_gate"
  finalize_run
  exit 1
}

finalize_run() {
  local duration
  local final_state
  duration="$(( $(date +%s) - START_TIME ))"
  final_state="failed"

  if [ "$COMPLETED_STEPS" -gt 0 ]; then
    SCORE=$((TOTAL_SCORE / COMPLETED_STEPS))
  fi

  if [ -n "$(git_repo_root "$PROJECT_DIR")" ]; then
    BRANCH="$(git -C "$(git_repo_root "$PROJECT_DIR")" branch --show-current 2>/dev/null || true)"
  fi

  if [ "$RESULT" = "SUCCESS" ]; then
    local repo_root project_path
    repo_root="$(git_repo_root "$PROJECT_DIR")"
    project_path=""
    if [ -n "$repo_root" ]; then
      project_path="$(relative_path "$PROJECT_DIR" "$repo_root")"
    fi

    if [ -z "$repo_root" ]; then
      log_msg INFO orchestrator "Project is not inside a git repository; skipping commit and push"
    elif commit_project_changes "$PROJECT_DIR" "$TASK"; then
      if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ] && [ "${AUTO_PUSH_PR:-0}" = "1" ]; then
        PR_URL="$(push_branch_and_create_pr "$PROJECT_DIR" "$BRANCH" "$TASK" || true)"
      else
        log_msg INFO orchestrator "Push and PR creation skipped for the current branch"
      fi
    elif git -C "$repo_root" status --porcelain -- "${project_path:-.}" | grep -q .; then
      RESULT="FAILURE"
      log_msg ERROR orchestrator "Task execution succeeded but git commit automation failed"
    else
      log_msg INFO orchestrator "No git changes remained after task completion"
    fi
  fi

  if [ "$RESULT" = "SUCCESS" ]; then
    final_state="completed"
    notify_ntfy "Codex task succeeded" "$PROJECT_NAME: $TASK" default white_check_mark
  else
    notify_ntfy "Codex task failed" "$PROJECT_NAME: $TASK" high warning
  fi

  # Post-execution guard: flag low-score successes for manual review
  post_execution_guard "$SCORE" "$RESULT" "$TASK_ID" 2>/dev/null || true

  # Fire post-task hook
  if command -v fire_hook >/dev/null 2>&1; then
    local post_hook_data
    post_hook_data="$(jq -cn \
      --arg task "$TASK" \
      --arg project "$PROJECT_NAME" \
      --arg result "$RESULT" \
      --argjson score "$SCORE" \
      --arg duration "$duration" \
      --arg task_id "$TASK_ID" \
      '{task:$task,project:$project,result:$result,score:$score,duration:$duration,task_id:$task_id}' 2>/dev/null || printf '{}')"
    fire_hook "post_task_execute" "$post_hook_data" || true
  fi

  # --- Rule-Outcome Tracing: record which rules were active and whether the task succeeded ---
  if [ -n "$RULE_TRACE_FILE" ]; then
    jq -cn \
      --arg task_id "${TASK_ID:-$RUN_ID}" \
      --arg task "$TASK" \
      --arg result "$RESULT" \
      --argjson score "${SCORE:-0}" \
      --arg rules_hash "${ACTIVE_RULES_HASH:-none}" \
      --argjson rules_count "${ACTIVE_RULES_SNAPSHOT:-0}" \
      --argjson attempts "${ATTEMPTS:-0}" \
      --arg provider "$(resolved_run_provider)" \
      --arg failure_kind "${failure_kind_tag:-}" \
      --arg timestamp "$(now_utc)" \
      --argjson duration "$duration" \
      '{task_id:$task_id,task:($task|.[0:120]),result:$result,score:$score,
        rules_hash:$rules_hash,rules_count:$rules_count,attempts:$attempts,
        provider:$provider,failure_kind:$failure_kind,timestamp:$timestamp,
        duration_seconds:$duration}' >>"$RULE_TRACE_FILE" 2>/dev/null || true
  fi

  append_task_record "$duration"
  persist_final_run_context "$duration"
  compute_provider_stats || true
  refresh_run_monitoring_artifacts "$final_state"
  append_memory_notes "$duration"
  PROJECT_NAME="$PROJECT_NAME" \
    "$ROOT_DIR/agents/learner.sh" "$PROJECT_DIR" "$TASK" "$RESULT" "$RUN_DIR" "$PROMPT_RULES_FILE" "$RUN_DIR/learner.json" >"$RUN_DIR/learner.stdout" 2>&1 || log_msg WARN orchestrator "Learner step failed"
  # Store learning in topic-based memory
  if [ "$RESULT" = "SUCCESS" ] && command -v categorize_and_store_learning >/dev/null 2>&1; then
    local task_category
    task_category="$(classify_task_category "$TASK" 2>/dev/null || printf 'code_quality')"
    categorize_and_store_learning "Task succeeded: $TASK (score=$SCORE, attempts=$ATTEMPTS)" "$task_category" 2>/dev/null || true
  elif [ "$RESULT" = "FAILURE" ] && command -v categorize_and_store_learning >/dev/null 2>&1; then
    local task_category
    task_category="$(classify_task_category "$TASK" 2>/dev/null || printf 'code_quality')"
    local fail_class_note="${failure_kind_tag:-unknown}"
    categorize_and_store_learning "Task failed [$fail_class_note]: $TASK — $FAILED_STEP_TEXT" "$task_category" 2>/dev/null || true
  fi
  "$ROOT_DIR/agents/safety.sh" "$PROMPT_RULES_FILE" "$RULES_FILE" "$RUN_DIR/safety.json" >"$RUN_DIR/safety.stdout" 2>&1 || log_msg WARN orchestrator "Safety step failed"
  run_memory_index || true
  # Trigger memory sync export if memory-sync.sh is available
  if [ -f "$ROOT_DIR/scripts/memory-sync.sh" ]; then
    bash "$ROOT_DIR/scripts/memory-sync.sh" export >/dev/null 2>&1 || log_msg WARN orchestrator "Memory sync export failed"
  fi

  cat >"$SUMMARY_FILE" <<EOF
result=$RESULT
project=$PROJECT_NAME
task=$TASK
provider=$(resolved_run_provider)
steps=$STEP_COUNT
completed_steps=$COMPLETED_STEPS
attempts=$ATTEMPTS
total_step_attempts=$TOTAL_STEP_ATTEMPTS
score=$SCORE
branch=$BRANCH
pr_url=$PR_URL
failed_step_index=$FAILED_STEP_INDEX
failure_kind=${failure_kind_tag:-}
run_dir=$(relative_path "$RUN_DIR" "$ROOT_DIR")
duration_seconds=$duration
EOF

  persist_runtime_session_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "${TASK_ID:-$RUN_ID}" \
    "$RUN_ID" \
    "$final_state" \
    "background" \
    "$(resolved_run_provider)" \
    "" \
    "$RESULT" \
    "$STEP_COUNT" \
    "$COMPLETED_STEPS" \
    "${FAILED_STEP_TEXT:-}"
  append_runtime_session_event \
    "$PROJECT_NAME" \
    "${TASK_ID:-$RUN_ID}" \
    "$RUN_ID" \
    "session_complete" \
    "Task execution ${final_state}." \
    "result=$RESULT duration=${duration}s"
  write_status "$final_state" "$PROJECT_NAME" "$TASK" "$RESULT" "run_id=$RUN_ID duration=${duration}s"
  log_msg INFO orchestrator "Completed task for $PROJECT_NAME with result=$RESULT score=$SCORE attempts=$ATTEMPTS steps=$COMPLETED_STEPS/$STEP_COUNT"
  cat "$SUMMARY_FILE"
}

# --- Rule-Outcome Tracing ---
# Snapshot active rules at task start so we can correlate with outcome later.
RULE_TRACE_FILE="$LEARNING_DIR/rule-outcome-trace.jsonl"
ACTIVE_RULES_SNAPSHOT=""
if [ -f "$RULES_FILE" ]; then
  ACTIVE_RULES_SNAPSHOT="$(grep -c '^- ' "$RULES_FILE" 2>/dev/null || printf '0')"
  ACTIVE_RULES_HASH="$(md5sum "$RULES_FILE" 2>/dev/null | cut -c1-8 || printf 'unknown')"
else
  ACTIVE_RULES_SNAPSHOT="0"
  ACTIVE_RULES_HASH="none"
fi

# Fire pre-task hook (can block execution with exit 2)
if command -v fire_hook >/dev/null 2>&1; then
  hook_data="$(jq -cn --arg task "$TASK" --arg project "$PROJECT_NAME" --arg task_id "$TASK_ID" '{task:$task,project:$project,task_id:$task_id}' 2>/dev/null || printf '{}')"
  if ! fire_hook "pre_task_execute" "$hook_data"; then
    log_msg WARN orchestrator "pre_task_execute hook blocked execution"
    RESULT="FAILURE"
    FAILED_STEP_TEXT="Blocked by pre_task_execute hook"
    append_runtime_session_blocker "$PROJECT_NAME" "${TASK_ID:-$RUN_ID}" "$RUN_ID" "pre_task_execute_hook" "Blocked by pre_task_execute hook"
    finalize_run
    exit 1
  fi
fi

# --- Pre-execution environment gate ---
# Fail fast if the task requires toolchains that are not installed (e.g. Android SDK).
# If Docker is available and a delegate script exists, the task is allowed through
# and CODEX_DOCKER_DELEGATE is exported so downstream agents can wrap commands.
export CODEX_DOCKER_DELEGATE=""
if command -v check_task_environment_requirements >/dev/null 2>&1; then
  env_check="$(check_task_environment_requirements "$TASK" "$PROJECT_NAME" 2>/dev/null || printf '{"blocked":false}')"
  env_blocked="$(printf '%s' "$env_check" | jq -r '.blocked // false' 2>/dev/null || printf 'false')"
  env_docker_delegate="$(printf '%s' "$env_check" | jq -r '.docker_delegate // ""' 2>/dev/null || printf '')"
  if [ -n "$env_docker_delegate" ]; then
    # Docker can satisfy the missing environment — delegate instead of blocking.
    CODEX_DOCKER_DELEGATE="$ROOT_DIR/scripts/$env_docker_delegate"
    if [ ! -x "$CODEX_DOCKER_DELEGATE" ]; then
      log_msg WARN orchestrator "Docker delegate script not found or not executable: $CODEX_DOCKER_DELEGATE"
      CODEX_DOCKER_DELEGATE=""
    else
      log_msg INFO orchestrator "Environment gate: delegating to Docker via $env_docker_delegate"
    fi
  fi
  if [ "$env_blocked" = "true" ]; then
    env_reason="$(printf '%s' "$env_check" | jq -r '.reason // "unknown"' 2>/dev/null)"
    env_blocker="$(printf '%s' "$env_check" | jq -r '.blocker // "unknown"' 2>/dev/null)"
    log_msg WARN orchestrator "Environment gate blocked task: blocker=$env_blocker reason=$env_reason"
    RESULT="FAILURE"
    FAILED_STEP_TEXT="Environment pre-check: $env_reason"
    FAILED_STEP_INDEX=0
    FAILURE_TIMESTAMP="$(now_utc)"
    failure_kind_tag="missing_environment"
    is_retriable="false"
    failure_reason="$env_reason"
    # Write failure classification for queue-worker
    mkdir -p "$RUN_DIR"
    jq -cn \
      --arg category "missing_environment" \
      --argjson retriable false \
      --arg reason "$env_reason" \
      '{category:$category,retriable:$retriable,reason:$reason}' >"$RUN_DIR/failure-classification.json" 2>/dev/null || true
    sync_task_registry_execution_state \
      "$PROJECT_NAME" \
      "$TASK" \
      "failed" \
      "execute_failure" \
      "Environment pre-check failed: $env_reason" \
      "0" \
      "$MAX_AGENT_RETRIES" \
      "$TASK_PROVIDER" \
      "" \
      "$FAILED_STEP_TEXT" \
      "0" \
      "$TASK_ID" || true
    append_runtime_session_blocker "$PROJECT_NAME" "${TASK_ID:-$RUN_ID}" "$RUN_ID" "environment_gate" "$env_reason"
    write_status "failed" "$PROJECT_NAME" "$TASK" "$RESULT" "run_id=$RUN_ID reason=environment_gate blocker=$env_blocker"
    finalize_run
    exit 3
  fi
fi

# --- Task scope complexity gate ---
# Tasks that are too broad consistently timeout (900s). Detect overscoped tasks
# and reduce their timeout budget to fail faster, preserving worker capacity.
# Heuristic: tasks with high word counts or multiple conjunctions signal broad scope.
# Iteration 20 fix: resolved_timeout must be initialized before the if-elif chain.
# Problem 69: The elif branch at "verbose task" uses resolved_timeout in arithmetic
# but it was never set if no prior branch matched. Under set -u, this causes
# "unbound variable" which kills ALL task execution (0 tasks can run).
resolved_timeout="${resolved_timeout:-${TASK_TIMEOUT_SECONDS:-420}}"
task_scope_budget="$resolved_timeout"
task_word_count="$(printf '%s' "$TASK" | wc -w | tr -d ' ')"
task_conjunction_count="$(
  {
    printf '%s' "$TASK" | grep -oi '\band\b\|with\b\|for all\b\|across\b\|comprehensive\b\|full\b\|complete\b\|end.to.end\b' || true
  } | wc -l | tr -d ' '
)"

# --- Multi-platform / heavy-framework complexity detector ---
# Tasks mentioning multiple platforms or heavy frameworks have 0% success rate
# historically. Detect and aggressively cap to fail fast (120s) or reject.
task_lower="$(printf '%s' "$TASK" | tr '[:upper:]' '[:lower:]')"
platform_hits=0
for kw in "swiftui" "jetpack compose" "compose multiplatform" "kotlin multiplatform" \
          "next.js" "react native" "flutter" "docker compose" "kubernetes" \
          "ios.*android" "android.*ios" "iphone.*ipad" "multi.?platform"; do
  if printf '%s' "$task_lower" | grep -qiE "$kw" 2>/dev/null; then
    platform_hits=$((platform_hits + 1))
  fi
done

# Tasks with heavy-scope keywords: "migrate", "redesign", "comprehensive", "end-to-end"
scope_amplifier=0
for amp in "migrate" "redesign" "overhaul" "rewrite" "comprehensive" "end.to.end" "full.stack" "all screens"; do
  if printf '%s' "$task_lower" | grep -qiE "$amp" 2>/dev/null; then
    scope_amplifier=$((scope_amplifier + 1))
  fi
done

if [ "$platform_hits" -ge 2 ] || { [ "$platform_hits" -ge 1 ] && [ "$scope_amplifier" -ge 1 ]; }; then
  # High-complexity multi-platform task: cap at 120s to fail fast
  task_scope_budget=120
  resolved_timeout="$task_scope_budget"
  log_msg WARN orchestrator "Task scope gate: multi-platform complexity (platforms=$platform_hits amplifiers=$scope_amplifier) — capping timeout to ${task_scope_budget}s"
elif [ "$task_word_count" -gt 15 ] && [ "$task_conjunction_count" -ge 3 ]; then
  # Overscoped task: cap timeout at 300s to fail fast
  task_scope_budget=300
  resolved_timeout="$task_scope_budget"
  log_msg WARN orchestrator "Task scope gate: high complexity detected (${task_word_count} words, ${task_conjunction_count} conjunctions) — capping timeout to ${task_scope_budget}s"
elif [ "$scope_amplifier" -ge 2 ]; then
  # Multiple scope amplifiers without platform hits: cap at 200s
  task_scope_budget=200
  resolved_timeout="$task_scope_budget"
  log_msg WARN orchestrator "Task scope gate: scope amplifier overload (${scope_amplifier} amplifiers) — capping timeout to ${task_scope_budget}s"
elif [ "$task_word_count" -gt 20 ]; then
  # Verbose task: reduce timeout by 25%
  task_scope_budget=$(( resolved_timeout * 75 / 100 ))
  resolved_timeout="$task_scope_budget"
  log_msg INFO orchestrator "Task scope gate: verbose task (${task_word_count} words) — reducing timeout to ${task_scope_budget}s"
fi

# Use topic-aware memory if available, fall back to standard
if command -v read_memory_context_with_topics >/dev/null 2>&1; then
  read_memory_context_with_topics "$PROJECT_NAME" "$TASK" >"$MEMORY_FILE"
else
  read_memory_context "$PROJECT_NAME" "$TASK" >"$MEMORY_FILE"
fi

CURRENT_TASK_STEP_GUIDANCE="$(build_orchestrator_task_step_guidance "$TASK" "$PROJECT_NAME" "$TASK_ID")"
CURRENT_TASK_STEP_GUIDANCE="$(clamp_prompt_context "$CURRENT_TASK_STEP_GUIDANCE" 500)"
PLANNER_TASK="$TASK"
if [ "${#PLANNER_TASK}" -gt 500 ] && [ -n "$CURRENT_TASK_STEP_GUIDANCE" ]; then
  PLANNER_TASK="$CURRENT_TASK_STEP_GUIDANCE"
  log_msg INFO orchestrator "Using compact planner prompt derived from task metadata (${#PLANNER_TASK} chars)"
fi

# Resolve execution path (dynamic pipeline)
EXECUTION_PATH="$(resolve_execution_path "$TASK" 2>/dev/null || printf 'planner,coder,reviewer,evaluator')"
SKIP_REVIEWER=0
SKIP_EVALUATOR=0
case "$EXECUTION_PATH" in
  "planner,coder")
    SKIP_REVIEWER=1
    SKIP_EVALUATOR=1
    ;;
  "planner,coder,evaluator")
    SKIP_REVIEWER=1
    ;;
esac
log_msg INFO orchestrator "Execution path: $EXECUTION_PATH (skip_reviewer=$SKIP_REVIEWER skip_evaluator=$SKIP_EVALUATOR)"

# Cap planning phase at 60s to prevent zero-step timeouts where planning
# consumes the entire task timeout budget (94% of timeouts are zero-step).
# Reduced from 90s→60s: 90s was still too generous — most successful plans
# complete in <30s, and the extra 30s just delays failure detection.
PLANNER_TIMEOUT="${PLANNER_TIMEOUT_SECONDS:-60}"
case "$PLANNER_TIMEOUT" in
  ''|*[!0-9]*)
    PLANNER_TIMEOUT=60
    ;;
esac
if [ "$PLANNER_TIMEOUT" -gt 60 ]; then
  PLANNER_TIMEOUT=60
fi
case "$resolved_timeout" in
  ''|*[!0-9]*)
    resolved_timeout="${TASK_TIMEOUT_SECONDS:-420}"
    ;;
esac
if [ "$resolved_timeout" -gt 0 ] && [ "$PLANNER_TIMEOUT" -gt "$resolved_timeout" ]; then
  PLANNER_TIMEOUT="$resolved_timeout"
fi
if [ "$PLANNER_TIMEOUT" -lt 1 ]; then
  PLANNER_TIMEOUT=1
fi
planner_timed_out=0
planner_rc=0
if python3 "$ROOT_DIR/scripts/run-with-timeout.py" \
  "$PLANNER_TIMEOUT" \
  bash "$ROOT_DIR/agents/planner.sh" "$PROJECT_DIR" "$PLANNER_TASK" "$PLAN_FILE" "$MEMORY_FILE" \
  >"$RUN_DIR/planner.stdout" 2>&1; then
  planner_rc=0
else
  planner_rc=$?
fi

if [ "$planner_rc" -eq 124 ]; then
  planner_timed_out=1
  log_msg WARN orchestrator "Planner timed out after ${PLANNER_TIMEOUT}s — failing fast to preserve worker budget"
elif [ "$planner_rc" -ne 0 ]; then
  log_msg ERROR orchestrator "planner exited with code $planner_rc; synthesizing failure response"
  synthesize_agent_failure "planner" "$PLAN_FILE" "planner failed unexpectedly."
  planner_rc=1
elif ! validate_agent_json "$PLAN_FILE"; then
  log_msg ERROR orchestrator "planner produced invalid JSON; synthesizing failure response"
  synthesize_agent_failure "planner" "$PLAN_FILE" "planner failed unexpectedly."
  planner_rc=1
fi

if [ "$planner_timed_out" -eq 1 ]; then
  RESULT="FAILURE"
  failure_kind_tag="timeout"
  is_retriable="false"
  FAILED_STEP_INDEX=0
  FAILED_STEP_TEXT="Planner timed out after ${PLANNER_TIMEOUT}s before step execution began"
  FAILURE_TIMESTAMP="$(now_utc)"
  failure_reason="$FAILED_STEP_TEXT"
  failure_class_file="$RUN_DIR/failure-classification.json"
  jq -cn \
    --arg category "$failure_kind_tag" \
    --argjson retriable false \
    --arg reason "$failure_reason" \
    '{category:$category,retriable:$retriable,reason:$reason}' >"$failure_class_file" 2>/dev/null || true
  finalize_run
  exit 3
fi

if [ "$(json_get "$PLAN_FILE" '.status')" != "success" ]; then
  log_msg ERROR orchestrator "Planner did not return success; aborting task"
  RESULT="FAILURE"
  planner_error_msg="$(json_get "$PLAN_FILE" '.message // ""' 2>/dev/null | head -c 300 || true)"
  FAILED_STEP_TEXT="Planner failed: ${planner_error_msg:-status was not success}"
  failure_kind_tag="planning_failure"
  finalize_run
  exit 1
fi

if jq -e '
  (.data.completion? != null) and
  (.data.low_completion_threshold? != null) and
  (((.data.executable_work? // []) | length) == 0) and
  ((.data.completion | tonumber) < (.data.low_completion_threshold | tonumber))
' "$PLAN_FILE" >/dev/null 2>&1; then
  plan_completion="$(jq -r '.data.completion' "$PLAN_FILE" 2>/dev/null || printf '')"
  plan_low_completion_threshold="$(jq -r '.data.low_completion_threshold' "$PLAN_FILE" 2>/dev/null || printf '')"
  fail_low_completion_run "$plan_completion" "$plan_low_completion_threshold" "empty_executable_work_after_low_completion"
fi

STEP_COUNT="$(json_get "$PLAN_FILE" '.data.steps | length')"
if [ "$STEP_COUNT" -lt 1 ] || [ "$STEP_COUNT" -gt 8 ]; then
  log_msg ERROR orchestrator "Planner returned invalid step count: $STEP_COUNT"
  RESULT="FAILURE"
  FAILED_STEP_TEXT="Planning produced invalid step count: ${STEP_COUNT} (expected 1-8)"
  failure_kind_tag="planning_failure"
  finalize_run
  exit 1
fi

# Adaptive retries: use task complexity to determine max retries
EFFECTIVE_MAX_RETRIES="$MAX_AGENT_RETRIES"
if command -v resolve_max_retries >/dev/null 2>&1; then
  EFFECTIVE_MAX_RETRIES="$(resolve_max_retries "$TASK" 2>/dev/null || printf '%s' "$MAX_AGENT_RETRIES")"
fi
log_msg INFO orchestrator "Adaptive retries: max=$EFFECTIVE_MAX_RETRIES for task complexity"

for index in $(seq 0 $((STEP_COUNT - 1))); do
  # Elapsed-time guard: if we've consumed >80% of the task timeout budget,
  # abort remaining steps to avoid a zero-step-like timeout on the outer wrapper.
  # This converts silent timeouts into fast, classifiable failures.
  step_elapsed=$(( $(date +%s) - START_TIME ))
  step_budget_limit=$(( ${resolved_timeout:-420} * 80 / 100 ))
  if [ "$step_elapsed" -ge "$step_budget_limit" ]; then
    log_msg WARN orchestrator "Elapsed time ${step_elapsed}s exceeds 80% of timeout budget (${step_budget_limit}s) — aborting remaining steps"
    RESULT="FAILURE"
    failure_kind_tag="timeout"
    FAILED_STEP_INDEX=$((index + 1))
    FAILED_STEP_TEXT="Aborted: elapsed time exceeded 80% of timeout budget before step $((index + 1)) could start"
    break
  fi

  step_number=$((index + 1))
  step_text="$(jq -er --argjson idx "$index" '.data.steps[$idx]' "$PLAN_FILE")"
  step_file="$RUN_DIR/step-$step_number.json"

  feedback_file=""
  step_completed=0
  step_score=0
  previous_error_signature=""
  previous_failure_signature=""
  retry_context=""
  current_error_signature=""
  current_failure_signature=""
  normalized_failure_category=""
  classified_failed_step_text=""
  context_failure_message="context unavailable after truncation"

  for attempt in $(seq 1 "$EFFECTIVE_MAX_RETRIES"); do
    step_state="running"
    if [ "$attempt" -gt 1 ]; then
      step_state="retrying"
    fi
    TOTAL_STEP_ATTEMPTS=$((TOTAL_STEP_ATTEMPTS + 1))
    if [ "$attempt" -gt "$ATTEMPTS" ]; then
      ATTEMPTS="$attempt"
    fi
    write_status "$step_state" "$PROJECT_NAME" "$TASK" "RUNNING" "step=$step_number/$STEP_COUNT attempt=$attempt"
    persist_runtime_session_state \
      "$PROJECT_NAME" \
      "$TASK" \
      "${TASK_ID:-$RUN_ID}" \
      "$RUN_ID" \
      "$step_state" \
      "background" \
      "$EFFECTIVE_PROVIDER" \
      "" \
      "RUNNING" \
      "$STEP_COUNT" \
      "$COMPLETED_STEPS" \
      "$step_text"
    append_runtime_session_event \
      "$PROJECT_NAME" \
      "${TASK_ID:-$RUN_ID}" \
      "$RUN_ID" \
      "step_start" \
      "Step ${step_number} started." \
      "attempt=${attempt}/${EFFECTIVE_MAX_RETRIES} step=${step_number}/${STEP_COUNT}"
    log_msg INFO orchestrator "Running step $step_number/$STEP_COUNT attempt $attempt: $step_text"

    context_text="$step_text"

    # On retry: enrich step file with failure context from prior attempt
    if [ "$attempt" -gt 1 ] && [ -n "$feedback_file" ] && [ -f "$feedback_file" ]; then
      retry_step_seed="$step_text"
      if is_generic_implementation_step_value "$retry_step_seed" && [ -n "$CURRENT_TASK_STEP_GUIDANCE" ]; then
        retry_step_seed="$CURRENT_TASK_STEP_GUIDANCE"
      fi
      retry_context="$(python3 - "$feedback_file" "$attempt" "$retry_step_seed" "$RUN_DIR" <<'PYRETRY'
import json, sys, os, hashlib, re
from pathlib import Path

feedback_path, attempt_str, original_step = sys.argv[1], sys.argv[2], sys.argv[3]
run_dir = sys.argv[4] if len(sys.argv) > 4 else ""
attempt_num = int(attempt_str)


def normalize_text(value):
    return re.sub(r"\s+", " ", str(value or "").strip())


def step_kind(value):
    lower = normalize_text(value).lower()
    if lower.startswith(("verify", "run ", "check", "confirm")):
        return "verify"
    if lower.startswith(("inspect", "review", "analy", "understand", "choose")) or "inspect only" in lower:
        return "inspect"
    return "implement"

try:
    feedback = json.loads(Path(feedback_path).read_text(encoding="utf-8"))
except Exception:
    feedback = {}

errors = []
error_categories = set()
for role in ("coder", "review", "evaluation"):
    entry = feedback.get(role) or {}
    if entry.get("status") in ("fail", "retry"):
        msg = entry.get("message", "")
        data = entry.get("data") or {}
        findings = data.get("findings", [])
        reason = data.get("reason", "")
        if msg: errors.append(f"{role}: {msg}")
        if reason: errors.append(f"{role} reason: {reason}")
        for f in (findings if isinstance(findings, list) else [])[:3]:
            errors.append(f"  - {f}")
        # Classify error type for strategy mutation
        combined = (msg + " " + reason).lower()
        if any(w in combined for w in ("not found", "missing", "no such file")):
            error_categories.add("missing_resource")
        if any(w in combined for w in ("syntax", "parse", "unexpected token")):
            error_categories.add("syntax_error")
        if any(w in combined for w in ("test", "assert", "expect")):
            error_categories.add("test_failure")
        if any(w in combined for w in ("timeout", "timed out")):
            error_categories.add("timeout")
        if any(w in combined for w in ("empty", "null", "no output")):
            error_categories.add("empty_output")

if not errors:
    print(original_step)
    raise SystemExit(0)

is_inspection_retry = step_kind(original_step) == "inspect"

# --- Strategy Mutation ---
# Generate specific counter-strategies based on what went wrong
mutations = []
if "missing_resource" in error_categories:
    mutations.append("STRATEGY CHANGE: Before any edits, run `ls` and `find` to verify all target files exist. Create missing files before editing.")
if "syntax_error" in error_categories:
    mutations.append("STRATEGY CHANGE: Read the ENTIRE target file first with `cat`. Understand the existing structure before making any changes. Use small, targeted edits instead of large rewrites.")
if "test_failure" in error_categories:
    mutations.append("STRATEGY CHANGE: Read the failing test file FIRST to understand expected behavior. Then implement to match the test expectations exactly.")
if "timeout" in error_categories:
    mutations.append("STRATEGY CHANGE: Reduce scope drastically. Do the minimum viable change for this step only. Avoid running full test suites.")
if "empty_output" in error_categories:
    mutations.append("STRATEGY CHANGE: Use explicit print/echo statements to verify each sub-step produces output. Check tool availability before using it.")
if is_inspection_retry:
    mutations.append(
        "STRATEGY CHANGE: Keep this retry inspection-only. Do not edit files in this step. Re-read the live file state and correct the inspection summary so it matches the current structure exactly."
    )
if not mutations:
    mutations.append("STRATEGY CHANGE: The previous approach failed for unclear reasons. Try a fundamentally different implementation: different libraries, different file organization, or different algorithm.")

# Track previous approaches to prevent repetition
approach_log_path = os.path.join(run_dir, "approach-log.jsonl") if run_dir else ""
previous_approaches = []
if approach_log_path and os.path.isfile(approach_log_path):
    try:
        for line in Path(approach_log_path).read_text().strip().split("\n"):
            if line.strip():
                previous_approaches.append(json.loads(line).get("summary", ""))
    except Exception:
        pass

# Log this approach attempt
if approach_log_path:
    try:
        error_sig = hashlib.md5("\n".join(errors).encode()).hexdigest()[:8]
        with open(approach_log_path, "a") as f:
            f.write(json.dumps({"attempt": attempt_num, "error_hash": error_sig, "summary": "\n".join(errors[:2])}) + "\n")
    except Exception:
        pass

avoid_section = ""
if previous_approaches:
    avoid_section = "\n\nPREVIOUS FAILED APPROACHES (DO NOT REPEAT THESE):\n" + "\n".join(
        f"  Attempt {i+1}: {a[:200]}" for i, a in enumerate(previous_approaches)
    )

enriched = f"""RETRY ATTEMPT {attempt_str} for this step.

ORIGINAL STEP: {original_step}

PREVIOUS FAILURE DETAILS:
{chr(10).join(errors)}

{chr(10).join(mutations)}
{avoid_section}

MANDATORY RULES FOR THIS RETRY:
1. You MUST NOT repeat the same approach that just failed.
2. Start by reading/inspecting the current state of affected files.
3. {"Keep this retry read-only. Do not change files in this step; correct the inspection result against the live state." if is_inspection_retry else "Make the SMALLEST possible change that addresses the failure."}
4. {"Verify your inspection summary matches the live file state before declaring success." if is_inspection_retry else "Verify your change works before declaring success."}"""

print(enriched)
PYRETRY
)" || retry_context="$step_text"
      context_text="$retry_context"
      log_msg INFO orchestrator "Enriched step $step_number with failure context for retry attempt $attempt"
    fi

    context_text="$(clamp_prompt_context "${context_text-}" "$MAX_PROMPT_CONTEXT_CHARS")"
    if [ -z "${context_text-}" ]; then
      log_msg ERROR orchestrator "Step $step_number attempt $attempt aborted: $context_failure_message"
      coder_file="$RUN_DIR/step-$step_number-coder-$attempt.json"
      reviewer_file="$RUN_DIR/step-$step_number-reviewer-$attempt.json"
      evaluator_file="$RUN_DIR/step-$step_number-evaluator-$attempt.json"
      feedback_next="$RUN_DIR/step-$step_number-feedback-$attempt.json"
      synthesize_agent_failure coder "$coder_file" "$context_failure_message"
      synthesize_agent_failure reviewer "$reviewer_file" "$context_failure_message"
      write_json_file "$evaluator_file" "fail" "$context_failure_message" '{"score":0}' 2>/dev/null || true
      jq -cn \
        --slurpfile coder "$coder_file" \
        --slurpfile review "$reviewer_file" \
        --slurpfile evaluation "$evaluator_file" \
        '{coder:$coder[0],review:$review[0],evaluation:$evaluation[0]}' >"$feedback_next"
      feedback_file="$feedback_next"
      break
    fi

    jq -cn --argjson index "$step_number" --arg text "$context_text" '{index:$index,text:$text}' >"$step_file"

    coder_file="$RUN_DIR/step-$step_number-coder-$attempt.json"
    reviewer_file="$RUN_DIR/step-$step_number-reviewer-$attempt.json"
    evaluator_file="$RUN_DIR/step-$step_number-evaluator-$attempt.json"
    feedback_next="$RUN_DIR/step-$step_number-feedback-$attempt.json"

    # Fire pre-coder-step hook
    if command -v fire_hook >/dev/null 2>&1; then
      step_hook_data="$(jq -cn --arg task "$TASK" --arg step "$step_text" --argjson idx "$step_number" '{task:$task,step:$step,step_index:$idx}' 2>/dev/null || printf '{}')"
      fire_hook "pre_coder_step" "$step_hook_data" || true
    fi

    coder_rc=0
    run_agent_script coder "$ROOT_DIR/agents/coder.sh" "$RUN_DIR/step-$step_number-coder-$attempt.stdout" "$coder_file" "$PROJECT_DIR" "$TASK" "$step_file" "$PLAN_FILE" "$MEMORY_FILE" "$feedback_file" "$coder_file" || coder_rc=$?

    # If coder timed out (rc=124), abort the entire task immediately — don't
    # waste budget on reviewer/evaluator for a step that never completed.
    if [ "$coder_rc" -eq 124 ]; then
      log_msg WARN orchestrator "Step $step_number coder timed out — aborting task to preserve budget"
      RESULT="FAILURE"
      failure_kind_tag="timeout"
      FAILED_STEP_INDEX="$step_number"
      FAILED_STEP_TEXT="Step $step_number coder timed out — per-step budget exhausted before completion"
      append_runtime_session_event \
        "$PROJECT_NAME" \
        "${TASK_ID:-$RUN_ID}" \
        "$RUN_ID" \
        "step_failure" \
        "Step ${step_number} timed out." \
        "attempt=${attempt}/${EFFECTIVE_MAX_RETRIES}"
      # Break out of both retry loop and step loop
      break 2
    fi

    # Dynamic pipeline: conditionally run reviewer
    if [ "$SKIP_REVIEWER" -eq 0 ]; then
      run_agent_script reviewer "$ROOT_DIR/agents/reviewer.sh" "$RUN_DIR/step-$step_number-reviewer-$attempt.stdout" "$reviewer_file" "$PROJECT_DIR" "$TASK" "$step_file" "$PLAN_FILE" "$coder_file" "$reviewer_file" || true
    else
      # Synthesize auto-approved review
      write_json_file "$reviewer_file" "approved" "Review skipped (dynamic pipeline)" '{}' 2>/dev/null || true
    fi

    # Dynamic pipeline: conditionally run evaluator
    if [ "$SKIP_EVALUATOR" -eq 0 ]; then
      run_agent_script evaluator "$ROOT_DIR/agents/evaluator.sh" "$RUN_DIR/step-$step_number-evaluator-$attempt.stdout" "$evaluator_file" "$PROJECT_DIR" "$TASK" "$step_file" "$PLAN_FILE" "$reviewer_file" "$evaluator_file" || true
    else
      # Synthesize default pass score
      write_json_file "$evaluator_file" "success" "Evaluation skipped (dynamic pipeline)" '{"score":5}' 2>/dev/null || true
    fi

    # Fire post-coder-step hook
    if command -v fire_hook >/dev/null 2>&1; then
      fire_hook "post_coder_step" "$step_hook_data" || true
    fi

    jq -cn \
      --slurpfile coder "$coder_file" \
      --slurpfile review "$reviewer_file" \
      --slurpfile evaluation "$evaluator_file" \
      '{coder:$coder[0],review:$review[0],evaluation:$evaluation[0]}' >"$feedback_next"
    feedback_file="$feedback_next"

    coder_status="$(json_get "$coder_file" '.status')"
    review_status="$(json_get "$reviewer_file" '.status')"
    evaluation_status="$(json_get "$evaluator_file" '.status')"
    step_score="$(json_get "$evaluator_file" '.data.score // 0')"

    log_msg INFO orchestrator "Step $step_number attempt $attempt statuses: coder=$coder_status reviewer=$review_status evaluator=$evaluation_status score=$step_score"

    # Context recovery: refresh memory at midpoint of execution
    refresh_core_context_if_needed "$step_number" "$STEP_COUNT" "$MEMORY_FILE" "$PROJECT_NAME" "$TASK" 2>/dev/null || true

    # Failure classification + intelligent retry decision
    if [ "$coder_status" != "success" ] || [ "$review_status" != "approved" ] || [ "$evaluation_status" = "fail" ]; then
      # Extract error details for classification — include both coder AND reviewer/evaluator
      # output, because when coder reports success but reviewer rejects, the coder's message
      # won't match any failure patterns (root cause of 80% "unknown" classifications).
      error_output="$(json_get "$coder_file" '.message // ""' 2>/dev/null | head -c 500)"
      failed_step_detail="$(json_get "$coder_file" '.data.summary // ""' 2>/dev/null | head -c 300)"
      # Append reviewer and evaluator rejection text so classify_failure can see WHY it was rejected
      if [ -n "${reviewer_file:-}" ] && [ -f "$reviewer_file" ]; then
        review_msg="$(json_get "$reviewer_file" '.message // ""' 2>/dev/null | head -c 300)"
        review_findings="$(json_get "$reviewer_file" '.data.findings[0] // ""' 2>/dev/null | head -c 200)"
        error_output="${error_output} review: ${review_msg} ${review_findings}"
      fi
      if [ -n "${evaluator_file:-}" ] && [ -f "$evaluator_file" ]; then
        eval_msg="$(json_get "$evaluator_file" '.message // ""' 2>/dev/null | head -c 200)"
        error_output="${error_output} evaluation: ${eval_msg}"
      fi
      retry_failure_text="$(resolve_failed_step_text "$step_text" "$coder_file" "${reviewer_file:-}" "$CURRENT_TASK_STEP_GUIDANCE")"
      [ -n "$retry_failure_text" ] || retry_failure_text="$step_text"
      # Enrich retry failure text with the full error_output (which includes reviewer+evaluator)
      # so classify_retry_failure can see WHY the step actually failed, not just the coder's output.
      # Fix 2026-03-25: Also include all reviewer findings (not just [0]) and step text as fallback
      # to ensure enriched_retry_text is never empty — root cause of 76% "unknown" classifications.
      if [ -n "${reviewer_file:-}" ] && [ -f "$reviewer_file" ]; then
        all_findings="$(jq -r '(.data.findings // []) | join("; ")' "$reviewer_file" 2>/dev/null || true)"
        review_status_text="$(jq -r '.status // ""' "$reviewer_file" 2>/dev/null || true)"
        error_output="${error_output} all_findings: ${all_findings} review_status: ${review_status_text}"
      fi
      enriched_retry_text="${retry_failure_text} ${error_output}"
      # Fallback: if enriched text is essentially empty, use step text + review/eval status
      enriched_trimmed="$(printf '%s' "$enriched_retry_text" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
      if [ "${#enriched_trimmed}" -lt 10 ]; then
        enriched_retry_text="step: ${step_text} review: ${review_status} eval: ${evaluation_status}"
      fi
      retry_failure_classification="unknown"
      retry_failure_timestamp="$(now_utc)"

      if [ "$attempt" -gt 1 ]; then
        retry_failure_classification="$(classify_retry_failure "$enriched_retry_text" 2>/dev/null || printf 'unknown')"
        # Extract evaluator reason for enriched failure tracking
        evaluator_reason_for_record="$(json_get "$evaluator_file" '.data.reason // ""' 2>/dev/null | head -c 200 || true)"
        record_retry_failure_event \
          "${TASK_ID:-$RUN_ID}" \
          "$PROJECT_NAME" \
          "$attempt" \
          "$step_number" \
          "$retry_failure_classification" \
          "$retry_failure_timestamp" \
          "$enriched_retry_text" \
          "$enriched_retry_text" \
          "$retry_failure_text" \
          "$evaluator_reason_for_record"
      fi

      # Classify failure as retriable vs non-retriable (MAST taxonomy)
      failure_class=""
      if command -v classify_failure >/dev/null 2>&1; then
        failure_class="$(classify_failure "$failed_step_detail" "$error_output" "$attempt" 2>/dev/null || printf '{}')"
      fi
      is_retriable="$(printf '%s' "$failure_class" | jq -r '.retriable // true' 2>/dev/null || printf 'true')"
      failure_category="$(printf '%s' "$failure_class" | jq -r '.category // "unknown"' 2>/dev/null || printf 'unknown')"
      failure_reason="$(printf '%s' "$failure_class" | jq -r '.reason // ""' 2>/dev/null || true)"
      backoff_mult="$(printf '%s' "$failure_class" | jq -r '.backoff_multiplier // 1' 2>/dev/null || printf '1')"

      case "$failure_category" in
        vpn_conflict|permission_denied|low_storage)
          is_retriable="false"
          failure_reason="deterministic protection failure [$failure_category]"
          classified_failed_step_text="$failure_reason"
          if [ -n "$(trim_text "$retry_failure_text")" ]; then
            classified_failed_step_text="$classified_failed_step_text: $retry_failure_text"
          elif [ -n "$(trim_text "$error_output")" ]; then
            classified_failed_step_text="$classified_failed_step_text: $error_output"
          fi
          ;;
      esac

      log_msg INFO orchestrator "Failure classification: category=$failure_category retriable=$is_retriable reason=$failure_reason"

      # Non-retriable failure: abort retries immediately
      if [ "$is_retriable" = "false" ]; then
        log_msg WARN orchestrator "Non-retriable failure for step $step_number ($failure_category): $failure_reason — skipping remaining retries"
        break
      fi

      # Retry loop detection: same error signature repeating
      current_error_signature="$(printf '%s' "$error_output" | head -c 200)"
      normalized_failure_category="$failure_category"
      case "$normalized_failure_category" in
        *_persistent) normalized_failure_category="${normalized_failure_category%_persistent}" ;;
      esac
      current_failure_signature="$(
        printf '%s\n%s\n%s\n%s\n%s\n' \
          "$normalized_failure_category" \
          "$retry_failure_text" \
          "$failed_step_detail" \
          "$review_status" \
          "$evaluation_status" \
          | tr '\n' ' ' \
          | tr -s '[:space:]' ' ' \
          | sed 's/^ //; s/ $//' \
          | cut -c 1-400
      )"
      if [ -n "$previous_error_signature" ] && [ "$current_error_signature" = "$previous_error_signature" ]; then
        log_msg WARN orchestrator "Retry loop detected for step $step_number: same error repeating ($failure_category) — aborting retries"
        break
      fi
      case "$failure_category" in
        rate_limit|network_error|server_error|timeout)
          ;;
        *)
          if [ -n "$previous_failure_signature" ] && [ -n "$current_failure_signature" ] && [ "$current_failure_signature" = "$previous_failure_signature" ]; then
            log_msg WARN orchestrator "Retry loop detected for step $step_number: same failure fingerprint repeating ($failure_category) — aborting retries"
            break
          fi
          ;;
      esac
      previous_error_signature="$current_error_signature"
      previous_failure_signature="$current_failure_signature"

      # Exponential backoff with jitter before retry
      if command -v calculate_retry_backoff >/dev/null 2>&1; then
        backoff_seconds="$(calculate_retry_backoff "$attempt" "5" "60" "$backoff_mult" 2>/dev/null || printf '5')"
        log_msg INFO orchestrator "Backoff ${backoff_seconds}s before retry attempt $((attempt+1)) for step $step_number"
        sleep "$backoff_seconds"
      fi

      if [ "$coder_status" != "success" ]; then
        log_msg WARN orchestrator "Coder failed step $step_number attempt $attempt"
      fi
      if [ "$review_status" != "approved" ]; then
        log_msg WARN orchestrator "Reviewer requested retry for step $step_number attempt $attempt ($failure_category)"
      fi
      if [ "$evaluation_status" = "fail" ]; then
        log_msg WARN orchestrator "Evaluator failed step $step_number attempt $attempt ($failure_category)"
      fi
      append_runtime_session_event \
        "$PROJECT_NAME" \
        "${TASK_ID:-$RUN_ID}" \
        "$RUN_ID" \
        "step_retry" \
        "Step ${step_number} needs another attempt." \
        "attempt=${attempt}/${EFFECTIVE_MAX_RETRIES} category=${failure_category:-unknown}"
      continue
    fi

    step_completed=1
    COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
    TOTAL_SCORE=$((TOTAL_SCORE + step_score))
    persist_runtime_session_state \
      "$PROJECT_NAME" \
      "$TASK" \
      "${TASK_ID:-$RUN_ID}" \
      "$RUN_ID" \
      "running" \
      "background" \
      "$EFFECTIVE_PROVIDER" \
      "" \
      "RUNNING" \
      "$STEP_COUNT" \
      "$COMPLETED_STEPS" \
      "$step_text"
    append_runtime_session_event \
      "$PROJECT_NAME" \
      "${TASK_ID:-$RUN_ID}" \
      "$RUN_ID" \
      "step_success" \
      "Step ${step_number} completed." \
      "attempt=${attempt}/${EFFECTIVE_MAX_RETRIES} score=${step_score}"
    break
  done

  if [ "$step_completed" -ne 1 ]; then
    FAILED_STEP_INDEX="$step_number"
    FAILED_STEP_TEXT="$classified_failed_step_text"
    if [ -z "$(trim_text "$FAILED_STEP_TEXT")" ]; then
      FAILED_STEP_TEXT="$(resolve_failed_step_text "$step_text" "$coder_file" "${reviewer_file:-}")"
    fi
    [ -n "$FAILED_STEP_TEXT" ] || FAILED_STEP_TEXT="$step_text"
    [ -n "$FAILED_STEP_TEXT" ] || FAILED_STEP_TEXT="step_${step_number}_failed_no_context"
    FAILURE_TIMESTAMP="$(now_utc)"
    RESULT="FAILURE"
    append_runtime_session_event \
      "$PROJECT_NAME" \
      "${TASK_ID:-$RUN_ID}" \
      "$RUN_ID" \
      "step_failure" \
      "Step ${step_number} failed." \
      "${FAILED_STEP_TEXT:-step failure}"
    # Store failure classification in the run summary for self-improve analysis.
    # If classify_failure didn't run (first attempt only, or step errored before
    # classification), perform a retroactive classification using available context.
    if [ -z "$(trim_text "${failure_category:-}")" ] || [ "${failure_category:-}" = "unknown" ]; then
      # Gather whatever error context is available for retroactive classification
      retro_error="$(json_get "${coder_file:-/dev/null}" '.message // ""' 2>/dev/null | head -c 500 || true)"
      retro_detail="$(json_get "${coder_file:-/dev/null}" '.data.summary // ""' 2>/dev/null | head -c 300 || true)"
      if [ -n "${reviewer_file:-}" ] && [ -f "$reviewer_file" ]; then
        retro_review="$(json_get "$reviewer_file" '.message // ""' 2>/dev/null | head -c 300 || true)"
        retro_error="${retro_error} review: ${retro_review}"
      fi
      retro_combined="${retro_detail} ${retro_error} ${FAILED_STEP_TEXT}"
      if [ "${#retro_combined}" -gt 10 ] && command -v classify_failure >/dev/null 2>&1; then
        retro_class="$(classify_failure "$retro_detail" "$retro_error" "${attempt:-1}" 2>/dev/null || printf '{}')"
        retro_category="$(printf '%s' "$retro_class" | jq -r '.category // "unknown"' 2>/dev/null || printf 'unknown')"
        retro_retriable="$(printf '%s' "$retro_class" | jq -r '.retriable // true' 2>/dev/null || printf 'true')"
        if [ "$retro_category" != "unknown" ]; then
          failure_category="$retro_category"
          is_retriable="$retro_retriable"
          log_msg INFO orchestrator "Retroactive classification: $retro_category (retriable=$retro_retriable)"
        fi
      fi
    fi
    failure_kind_tag="${failure_category:-unknown}"
    log_msg ERROR orchestrator "Step $step_number failed after $attempt attempt(s) [kind=$failure_kind_tag retriable=${is_retriable:-true}]"
    # Write failure classification to a well-known file so queue-worker can
    # decide whether to requeue or skip retries for non-retriable failures.
    failure_class_file="$RUN_DIR/failure-classification.json"
    jq -cn \
      --arg category "$failure_kind_tag" \
      --argjson retriable "${is_retriable:-true}" \
      --arg reason "${failure_reason:-}" \
      '{category:$category,retriable:$retriable,reason:$reason}' >"$failure_class_file" 2>/dev/null || true
    # Exit with code 3 for non-retriable failures so queue-worker can skip requeue
    if [ "${is_retriable:-true}" = "false" ]; then
      finalize_run
      exit 3
    fi
    finalize_run
    exit 1
  fi
done

RESULT="SUCCESS"

finalize_run
if [ "$RESULT" = "SUCCESS" ]; then
  exit 0
fi
exit 1
