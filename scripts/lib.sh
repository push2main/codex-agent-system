#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/codex-logs"
RUNS_DIR="$LOG_DIR/runs"
MEMORY_DIR="$ROOT_DIR/codex-memory"
LEARNING_DIR="$ROOT_DIR/codex-learning"
QUEUE_DIR="$ROOT_DIR/queues"
PROJECTS_DIR="$ROOT_DIR/projects"
DASHBOARD_DIR="$ROOT_DIR/codex-dashboard"
SYSTEM_LOG="$LOG_DIR/system.log"
CODEX_RUNTIME_HOME="${CODEX_RUNTIME_HOME:-$LOG_DIR/codex-home}"
STATUS_FILE="$ROOT_DIR/status.txt"
QUEUE_RETRY_DIR="$LOG_DIR/queue-retries"
RULES_FILE="$LEARNING_DIR/rules.md"
RULES_CANDIDATE_FILE="$LEARNING_DIR/rules-candidate.md"
PROMPT_RULES_FILE="$LEARNING_DIR/prompt-rules.md"
EXTERNAL_SIGNAL_SOURCES_FILE="${EXTERNAL_SIGNAL_SOURCES_FILE:-$LEARNING_DIR/external-signal-sources.json}"
EXTERNAL_SIGNALS_FILE="${EXTERNAL_SIGNALS_FILE:-$LEARNING_DIR/external-signals.json}"
TASK_LOG="${TASK_LOG:-$MEMORY_DIR/tasks.log}"
TASK_REGISTRY_FILE="${TASK_REGISTRY_FILE:-$MEMORY_DIR/tasks.json}"
METRICS_FILE="${METRICS_FILE:-$LEARNING_DIR/metrics.json}"
INCIDENT_LOG_FILE="${INCIDENT_LOG_FILE:-$MEMORY_DIR/incidents.jsonl}"
ALERTS_FILE="${ALERTS_FILE:-$LEARNING_DIR/alerts.json}"
DECISIONS_FILE="$MEMORY_DIR/decisions.md"
CONTEXT_FILE="$MEMORY_DIR/context.md"
QUEUE_LIMIT="${QUEUE_LIMIT:-20}"
TASK_TIMEOUT_SECONDS="${TASK_TIMEOUT_SECONDS:-600}"
MAX_AGENT_RETRIES=2
RETRY_ANALYSIS_LOG="${RETRY_ANALYSIS_LOG:-$LEARNING_DIR/retry-failure-analysis.jsonl}"
INCIDENTS_FILE="${INCIDENTS_FILE:-$LEARNING_DIR/incidents.json}"
MAX_PROMPT_CONTEXT_CHARS="${MAX_PROMPT_CONTEXT_CHARS:-4000}"
# Hard planning timeout: planner must finish within this budget (seconds),
# leaving remaining time for step execution.  Prevents zero-step timeouts.
PLANNING_TIMEOUT_SECONDS="${PLANNING_TIMEOUT_SECONDS:-90}"

classify_retry_failure() {
  local failure_text="${1:-}"

  python3 - "$failure_text" <<'PY'
import re
import sys

failure_text = " ".join((sys.argv[1] if len(sys.argv) > 1 else "").lower().split())

buckets = (
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
    # Broader patterns to reduce "unknown" rate — added 2026-03-25 self-learning fix
    ("model_refusal", (r"i cannot|i can't|i'm unable|i am unable|as an ai|not able to|refus", r"policy|content policy|safety")),
    ("build_failure", (r"build failed|compilation error|compile error|linker error|assembl.*fail", r"error:.*expected|error:.*undeclared|error:.*undefined")),
    # Keep single-pattern buckets as 1-tuples; otherwise Python iterates characters and corrupts classification.
    ("test_failure", (r"tests?\s+fail|assert.*fail|expect.*fail|tests? did not pass",)),
    ("no_change_produced", (r"no changes (made|produced|detected)|no diff produced|nothing to commit|working tree clean|no files changed|did not produce any",)),
    ("plan_incomplete", (r"plan.*incomplete|step.*missing|could not complete.*plan|no plan produced",)),
    # Catch-all patterns for common failure modes that were falling through as "unknown"
    ("step_not_completed", (r"step.*not.*complet|did not complete|incomplete.*step|step.*fail|could not.*finish",)),
    ("verification_failed", (r"verif.*fail|check.*fail|assert.*error|expect.*but.*got|does not match",)),
    ("file_not_found", (r"file.*not found|no such file|path.*does not exist|cannot find|enoent",)),
    ("syntax_error", (r"syntax.*error|parse.*error|unexpected token|invalid syntax|indentation",)),
    ("permission_error", (r"permission denied|eacces|eperm|access denied|forbidden",)),
    ("network_error", (r"network.*error|connection.*refused|econnrefused|dns.*fail|fetch.*fail|socket.*error",)),
    ("git_conflict", (r"merge conflict|rebase.*fail|git.*conflict|cannot.*merge|unmerged.*paths",)),
    ("dependency_conflict", (r"version.*conflict|incompatible.*version|peer.*dependency|resolution.*fail",)),
    ("resource_limit", (r"out of memory|oom|heap.*limit|stack.*overflow|segfault|killed",)),
    # Additional patterns to reduce "unknown" classification rate — 2026-03-25 enrichment fix
    ("placeholder_code", (r"placeholder|stub|dummy|skeleton|not implemented",)),
    ("no_change_detected", (r"no changes|no modifications|unchanged|working tree clean|nothing.*committed",)),
    ("provider_unavailable", (r"provider.*unavailable|auth.*fail|cooldown|rate.*limit|temporarily unavailable",)),
    ("low_quality_output", (r"score.*[0-3]|low.*score|poor.*quality|insufficient|below threshold",)),
)

for name, patterns in buckets:
    for pattern in patterns:
        if re.search(pattern, failure_text):
            print(name)
            raise SystemExit(0)

print("unknown")
PY
}

failure_kind_needs_reclassification() {
  local normalized_failure_kind
  normalized_failure_kind="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1; print}')"
  case "$normalized_failure_kind" in
    ""|unknown|step_failure|execution_failure)
      return 0
      ;;
  esac
  return 1
}

default_incident_trigger_flags_json() {
  cat <<'EOF'
{"notify":false,"page":false,"open_followup":false,"systemic":false}
EOF
}

default_incidents_payload() {
  cat <<'EOF'
{
  "updated_at": "",
  "incident_count": 0,
  "incident_counts": {},
  "severity_counts": {
    "critical": 0,
    "high": 0,
    "warning": 0,
    "info": 0
  },
  "last_incident_at": "",
  "last_incident_type": "",
  "last_incident_failure_kind": "",
  "last_incident_severity": "",
  "last_incident": {
    "run_id": "",
    "project": "",
    "task": "",
    "provider": "",
    "incident_type": "",
    "failure_kind": "",
    "severity": "",
    "micro_learning": {
      "title": "",
      "lesson": "",
      "operator_action": "",
      "source": "",
      "incident_key": ""
    },
    "trigger_flags": {
      "notify": false,
      "page": false,
      "open_followup": false,
      "systemic": false
    }
  },
  "incidents": []
}
EOF
}

default_alerts_payload() {
  cat <<'EOF'
{
  "updated_at": "",
  "project_id": "",
  "alert_count": 0,
  "active": false,
  "alerts": []
}
EOF
}

classify_incident_record() {
  local result="${1:-}"
  local run_state="${2:-}"
  local failure_kind="${3:-}"
  local failure_text="${4:-}"
  local metrics_payload="${5:-}"
  local normalized_failure_kind="${failure_kind:-}"

  if failure_kind_needs_reclassification "$normalized_failure_kind"; then
    local classified_failure_kind=""
    classified_failure_kind="$(classify_retry_failure "$failure_text")"
    if [ -n "$(trim_text "$classified_failure_kind")" ] && [ "$classified_failure_kind" != "unknown" ]; then
      normalized_failure_kind="$classified_failure_kind"
    fi
  fi

  python3 - "$result" "$run_state" "$normalized_failure_kind" "$failure_text" "$metrics_payload" <<'PY'
import json
import sys

result, run_state, failure_kind, failure_text, metrics_payload = sys.argv[1:]


def normalize_text(value: str) -> str:
    return " ".join(str(value or "").split())


def normalize_bool(value) -> bool:
    return value is True


def parse_metrics(raw: str) -> dict:
    text = str(raw or "").strip()
    if not text:
        return {}
    try:
        payload = json.loads(text)
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


severity_order = {"info": 0, "warning": 1, "high": 2, "critical": 3}
failure_kind = normalize_text(failure_kind).lower()
failure_text = normalize_text(failure_text)
result = normalize_text(result).upper()
run_state = normalize_text(run_state).lower()
metrics = parse_metrics(metrics_payload)

metric_signals = [
    ("queue_starvation_detected", "queue_starvation", "critical"),
    ("task_registry_pressure_detected", "task_registry_pressure", "critical"),
    ("strategy_saturation_detected", "strategy_saturation", "high"),
    ("retry_churn_detected", "retry_churn", "high"),
    ("pending_approval_blocked_detected", "approval_blocked", "warning"),
    ("low_completion_drain_detected", "low_completion_drain", "warning"),
    ("loop_effort_detected", "loop_effort", "warning"),
    ("loop_effort_bounded_experiment_detected", "loop_effort", "warning"),
]

active_metric_types: list[str] = []
metric_severity = "info"
for flag_name, incident_type, severity in metric_signals:
    if normalize_bool(metrics.get(flag_name)):
        if incident_type not in active_metric_types:
            active_metric_types.append(incident_type)
        if severity_order[severity] > severity_order[metric_severity]:
            metric_severity = severity

base_map = {
    "timeout": ("execution_timeout", "high"),
    "context_limit": ("context_saturation", "critical"),
    "missing_dependency": ("dependency_missing", "high"),
    "missing_environment": ("environment_missing", "high"),
    "review_rejection": ("review_blocked", "warning"),
    "evaluation_failure": ("evaluation_regression", "warning"),
    "low_completion": ("low_completion", "warning"),
    "empty_output": ("empty_output", "warning"),
    "tool_failure": ("provider_failure", "high"),
    "step_failure": ("step_failure", "warning"),
    "planning_failure": ("planning_failure", "warning"),
    "execution_failure": ("execution_failure", "warning"),
}

incident_type = ""
severity = "info"
if failure_kind in base_map:
    incident_type, severity = base_map[failure_kind]
elif result == "FAILURE":
    incident_type, severity = ("task_failure", "warning")
elif active_metric_types:
    incident_type, severity = (active_metric_types[0], metric_severity)

if not incident_type:
    raise SystemExit(0)

if active_metric_types and severity_order[metric_severity] > severity_order[severity]:
    severity = metric_severity

systemic_types = {
    "queue_starvation",
    "task_registry_pressure",
    "strategy_saturation",
    "retry_churn",
    "approval_blocked",
    "low_completion_drain",
    "loop_effort",
    "context_saturation",
    "provider_failure",
    "low_completion",
}
trigger_flags = {
    "notify": severity in {"high", "critical"} or bool(active_metric_types),
    "page": severity == "critical",
    "open_followup": result == "FAILURE" or bool(active_metric_types),
    "systemic": incident_type in systemic_types or bool(active_metric_types),
}

payload = {
    "incident_type": incident_type,
    "failure_kind": failure_kind or "unknown",
    "severity": severity,
    "result": result or "UNKNOWN",
    "run_state": run_state or "unknown",
    "failure_text": failure_text,
    "metrics_flags": active_metric_types,
    "trigger_flags": trigger_flags,
}
print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
PY
}

append_incident_record_jsonl() {
  local project_id="${1:-}"
  local result="${2:-}"
  local run_state="${3:-}"
  local failure_kind="${4:-}"
  local message="${5:-}"
  local metrics_payload="${6:-}"

  ensure_runtime_dirs

  python3 - "$INCIDENT_LOG_FILE" "$(now_utc)" "$project_id" "$result" "$run_state" "$failure_kind" "$message" "$metrics_payload" <<'PY'
import json
import sys
from pathlib import Path

(
    incident_log_path,
    timestamp,
    project_id,
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


record = {
    "failure_kind": normalize_text(failure_kind).lower() or "unknown",
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
}

write_alerts_payload() {
  local project_id="${1:-}"
  local metrics_payload="${2:-}"

  ensure_runtime_dirs

  if [ -z "$(trim_text "$metrics_payload")" ] && [ -f "$METRICS_FILE" ]; then
    metrics_payload="$(cat "$METRICS_FILE" 2>/dev/null || true)"
  fi

  python3 - "$ALERTS_FILE" "$(now_utc)" "$project_id" "$metrics_payload" <<'PY'
import json
import sys
from pathlib import Path

alerts_path, timestamp, project_id, metrics_payload = sys.argv[1:]


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


def as_bool(payload: dict, key: str) -> bool:
    return payload.get(key) is True


def as_int(payload: dict, key: str) -> int:
    value = payload.get(key)
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    try:
        return int(str(value).strip())
    except Exception:
        return 0


def as_number(payload: dict, key: str) -> float:
    value = payload.get(key)
    if isinstance(value, bool):
        return float(int(value))
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except Exception:
        return 0.0


def as_text(payload: dict, key: str) -> str:
    return normalize_text(payload.get(key) or "")


metrics = parse_metrics(metrics_payload)
catalog = [
    {
        "code": "queue_starvation",
        "metric": "queue_starvation_detected",
        "severity": "critical",
        "message": "Queue starvation is active.",
        "details": {"pending_approval_tasks": as_int(metrics, "pending_approval_tasks")},
    },
    {
        "code": "task_registry_pressure",
        "metric": "task_registry_pressure_detected",
        "severity": "critical",
        "message": "Task registry pressure is active.",
        "details": {
            "task_registry_payload_bytes": as_int(metrics, "task_registry_payload_bytes"),
            "task_registry_total": as_int(metrics, "task_registry_total"),
            "primary_surface": as_text(metrics, "task_registry_pressure_primary_surface"),
        },
    },
    {
        "code": "strategy_saturation",
        "metric": "strategy_saturation_detected",
        "severity": "high",
        "message": "Strategy saturation is active.",
        "details": {"saturated_failed_tasks": as_int(metrics, "saturated_failed_tasks")},
    },
    {
        "code": "retry_churn",
        "metric": "retry_churn_detected",
        "severity": "high",
        "message": "Retry churn is active.",
        "details": {"analysis_runs": as_int(metrics, "analysis_runs")},
    },
    {
        "code": "approval_blocked",
        "metric": "pending_approval_blocked_detected",
        "severity": "warning",
        "message": "Pending approvals are blocking progress.",
        "details": {"pending_approval_tasks": as_int(metrics, "pending_approval_tasks")},
    },
    {
        "code": "low_completion_drain",
        "metric": "low_completion_drain_detected",
        "severity": "warning",
        "message": "Low completion drain is active.",
        "details": {"success_rate": as_number(metrics, "success_rate")},
    },
    {
        "code": "loop_effort",
        "metric": "loop_effort_detected",
        "severity": "warning",
        "message": "Loop effort has crossed the alert threshold.",
        "details": {
            "loop_effort_task_count": as_int(metrics, "loop_effort_task_count"),
            "loop_effort_extra_step_attempts": as_int(metrics, "loop_effort_extra_step_attempts"),
        },
    },
    {
        "code": "loop_effort_bounded_experiment",
        "metric": "loop_effort_bounded_experiment_detected",
        "severity": "warning",
        "message": "Bounded loop effort experiment is active.",
        "details": {
            "metric_name": as_text(metrics, "loop_effort_bounded_experiment_metric_name"),
            "threshold": as_int(metrics, "loop_effort_bounded_experiment_extra_step_threshold"),
            "summary": as_text(metrics, "loop_effort_bounded_experiment_message"),
        },
    },
    {
        "code": "self_improve_pause_escalated",
        "metric": "self_improve_pause_escalated",
        "severity": "warning",
        "message": "Self-improve pause escalation is active.",
        "details": {
            "pause_age_seconds": as_int(metrics, "self_improve_pause_age_seconds"),
            "pause_file": as_text(metrics, "self_improve_pause_file"),
            "pause_reason": as_text(metrics, "self_improve_pause_reason"),
            "remediation_kind": as_text(metrics, "self_improve_pause_remediation_kind"),
            "remediation_title": as_text(metrics, "self_improve_pause_remediation_title"),
            "remediation_summary": as_text(metrics, "self_improve_pause_remediation_summary"),
            "remediation_command": as_text(metrics, "self_improve_pause_remediation_command"),
        },
    },
]

alerts = []
for item in catalog:
    if not as_bool(metrics, item["metric"]):
        continue
    alerts.append(
        {
            "code": item["code"],
            "details": item["details"],
            "message": item["message"],
            "metric": item["metric"],
            "severity": item["severity"],
        }
    )

payload = {
    "active": bool(alerts),
    "alert_count": len(alerts),
    "alerts": alerts,
    "project_id": normalize_text(project_id),
    "updated_at": normalize_text(timestamp),
}

path = Path(alerts_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

record_incident_event() {
  local run_id="${1:-}"
  local project_name="${2:-}"
  local queue_task="${3:-}"
  local provider="${4:-}"
  local incident_payload="${5:-}"

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0
  [ -n "$(trim_text "$incident_payload")" ] || return 0

  ensure_runtime_dirs

  python3 - "$INCIDENTS_FILE" "$METRICS_FILE" "$run_id" "$project_name" "$queue_task" "$provider" "$incident_payload" "$(now_utc)" <<'PY'
import json
import sys
from pathlib import Path

(
    incidents_path,
    metrics_path,
    run_id,
    project_name,
    queue_task,
    provider,
    incident_payload,
    timestamp,
) = sys.argv[1:]


def read_json(path: Path, fallback: dict) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        payload = fallback
    return payload if isinstance(payload, dict) else dict(fallback)


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def normalize_text(value: str) -> str:
    return " ".join(str(value or "").split())


def normalize_bool(value) -> bool:
    return value is True


default_trigger_flags = {
    "notify": False,
    "page": False,
    "open_followup": False,
    "systemic": False,
}
default_store = {
    "updated_at": "",
    "incident_count": 0,
    "incident_counts": {},
    "severity_counts": {"critical": 0, "high": 0, "warning": 0, "info": 0},
    "last_incident_at": "",
    "last_incident_type": "",
    "last_incident_failure_kind": "",
    "last_incident_severity": "",
    "last_incident": {
        "run_id": "",
        "project": "",
        "task": "",
        "provider": "",
        "incident_type": "",
        "failure_kind": "",
        "severity": "",
        "trigger_flags": dict(default_trigger_flags),
    },
    "incidents": [],
}
default_metrics = {
    "incident_records": 0,
    "incident_critical_records": 0,
    "incident_notification_records": 0,
    "last_incident_at": "",
    "last_incident_type": "",
    "last_incident_failure_kind": "",
    "last_incident_severity": "",
}

incident_path = Path(incidents_path)
metrics_file_path = Path(metrics_path)
store = read_json(incident_path, default_store)
metrics = read_json(metrics_file_path, default_metrics)
for key, value in default_store.items():
    if key not in store:
        store[key] = value if not isinstance(value, dict) else dict(value)
store["severity_counts"] = {
    "critical": int(((store.get("severity_counts") or {}).get("critical")) or 0),
    "high": int(((store.get("severity_counts") or {}).get("high")) or 0),
    "warning": int(((store.get("severity_counts") or {}).get("warning")) or 0),
    "info": int(((store.get("severity_counts") or {}).get("info")) or 0),
}
store["incident_counts"] = store.get("incident_counts") if isinstance(store.get("incident_counts"), dict) else {}
store["incidents"] = store.get("incidents") if isinstance(store.get("incidents"), list) else []
for key, value in default_metrics.items():
    if key not in metrics:
        metrics[key] = value

try:
    classified = json.loads(incident_payload)
except Exception:
    raise SystemExit(0)
if not isinstance(classified, dict):
    raise SystemExit(0)

incident_type = normalize_text(classified.get("incident_type") or "")
if not incident_type:
    raise SystemExit(0)

severity = normalize_text(classified.get("severity") or "warning").lower()
if severity not in {"critical", "high", "warning", "info"}:
    severity = "warning"
failure_kind = normalize_text(classified.get("failure_kind") or "unknown").lower() or "unknown"
trigger_flags_raw = classified.get("trigger_flags") if isinstance(classified.get("trigger_flags"), dict) else {}
trigger_flags = {
    key: normalize_bool(trigger_flags_raw.get(key))
    for key in default_trigger_flags
}

record = {
    "timestamp": timestamp,
    "run_id": normalize_text(run_id),
    "project": normalize_text(project_name),
    "task": normalize_text(queue_task),
    "provider": normalize_text(provider).lower(),
    "incident_type": incident_type,
    "failure_kind": failure_kind,
    "severity": severity,
    "metrics_flags": classified.get("metrics_flags") if isinstance(classified.get("metrics_flags"), list) else [],
    "trigger_flags": trigger_flags,
}
failure_text = normalize_text(classified.get("failure_text") or "")
if failure_text:
    record["failure_text"] = failure_text
result = normalize_text(classified.get("result") or "")
if result:
    record["result"] = result
run_state = normalize_text(classified.get("run_state") or "")
if run_state:
    record["run_state"] = run_state

store["incidents"].append(record)
store["incident_count"] = int(store.get("incident_count") or 0) + 1
store["incident_counts"][incident_type] = int(store["incident_counts"].get(incident_type) or 0) + 1
store["severity_counts"][severity] = int(store["severity_counts"].get(severity) or 0) + 1
store["updated_at"] = timestamp
store["last_incident_at"] = timestamp
store["last_incident_type"] = incident_type
store["last_incident_failure_kind"] = failure_kind
store["last_incident_severity"] = severity
store["last_incident"] = {
    "run_id": record["run_id"],
    "project": record["project"],
    "task": record["task"],
    "provider": record["provider"],
    "incident_type": incident_type,
    "failure_kind": failure_kind,
    "severity": severity,
    "trigger_flags": trigger_flags,
}

metrics["incident_records"] = int(metrics.get("incident_records") or 0) + 1
if severity == "critical":
    metrics["incident_critical_records"] = int(metrics.get("incident_critical_records") or 0) + 1
if trigger_flags["notify"]:
    metrics["incident_notification_records"] = int(metrics.get("incident_notification_records") or 0) + 1
metrics["last_incident_at"] = timestamp
metrics["last_incident_type"] = incident_type
metrics["last_incident_failure_kind"] = failure_kind
metrics["last_incident_severity"] = severity

write_json(incident_path, store)
write_json(metrics_file_path, metrics)
PY
}

record_retry_failure_event() {
  local task_id="${1:-}"
  local project_name="${2:-}"
  local attempt="${3:-0}"
  local failed_step_index="${4:-0}"
  local classification="${5:-unknown}"
  local timestamp="${6:-$(now_utc)}"
  local error_text="${7:-}"
  local enriched_text="${8:-}"
  local failed_step="${9:-}"
  local evaluator_reason="${10:-}"

  [ -n "$task_id" ] || return 0
  [ -n "$project_name" ] || return 0

  ensure_runtime_dirs
  local registry_file
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$RETRY_ANALYSIS_LOG" "$task_id" "$project_name" "$attempt" "$failed_step_index" "$classification" "$timestamp" "$error_text" "$enriched_text" "$failed_step" "$evaluator_reason" "$registry_file" <<'PY'
import json
import re
import sys
from pathlib import Path

path = sys.argv[1]
task_id = sys.argv[2]
project_name = sys.argv[3]
attempt = sys.argv[4]
failed_step_index = sys.argv[5]
classification = sys.argv[6]
timestamp = sys.argv[7]
error_text = sys.argv[8] if len(sys.argv) > 8 else ""
enriched_text = sys.argv[9] if len(sys.argv) > 9 else ""
failed_step = sys.argv[10] if len(sys.argv) > 10 else ""
evaluator_reason = sys.argv[11] if len(sys.argv) > 11 else ""
registry_path = Path(sys.argv[12]) if len(sys.argv) > 12 and sys.argv[12] else None

def normalize_int(value: str) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def normalize_text(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_list(value: object, *, limit: int = 3) -> list[str]:
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


def normalize_project(value: object) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", normalize_text(value).lower()))


def read_retry_task_context(path: Path | None, project: str, target_task_id: str) -> dict:
    if path is None or not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    if not isinstance(tasks, list):
        return {}

    project_key = normalize_project(project)
    target_key = normalize_text(target_task_id).lower()
    selected = None
    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_key = normalize_text(task.get("id")).lower()
        task_project = normalize_project(task.get("project") or task.get("target_project"))
        if task_key != target_key:
            continue
        if project_key and task_project and task_project != project_key:
            continue
        selected = task
        break
    if not isinstance(selected, dict):
        return {}

    task_intent = selected.get("task_intent")
    if not isinstance(task_intent, dict):
        execution_brief = selected.get("execution_brief")
        if isinstance(execution_brief, dict):
            task_intent = execution_brief.get("task_intent")
    if not isinstance(task_intent, dict):
        task_intent = {}

    task_shape = selected.get("task_shape")
    if not isinstance(task_shape, dict):
        task_shape = {}

    context = {}
    objective = normalize_text(task_intent.get("objective") or selected.get("title"))
    if objective:
        context["objective"] = objective
    context_hint = normalize_text(task_intent.get("context_hint"))
    if context_hint:
        context["context_hint"] = context_hint
    affected_files = normalize_list(task_intent.get("affected_files"))
    if affected_files:
        context["affected_files"] = affected_files
    constraints = normalize_list(task_intent.get("constraints"))
    if constraints:
        context["constraints"] = constraints
    success_signals = normalize_list(task_intent.get("success_signals"))
    if success_signals:
        context["success_signals"] = success_signals
    verification_command = normalize_text(task_shape.get("verification_command"))
    if verification_command:
        context["verification_command"] = verification_command
    return context

record = {
    "task_id": task_id,
    "project": project_name,
    "attempt": normalize_int(attempt),
    "failed_step_index": normalize_int(failed_step_index),
    "classification": classification or "unknown",
    "timestamp": timestamp,
}
task_context = read_retry_task_context(registry_path, project_name, task_id)
if task_context:
    record["task_context"] = task_context

# Auto-reclassify unknowns at write time using enriched text
# This prevents the 76% unknown accumulation that was discovered in self-learning audit
if record["classification"] == "unknown":
    structured_context_text = " ".join(
        [
            task_context.get("objective", ""),
            task_context.get("context_hint", ""),
            " ".join(task_context.get("affected_files", [])),
            " ".join(task_context.get("constraints", [])),
            task_context.get("verification_command", ""),
        ]
    )
    combined_text = " ".join([error_text, enriched_text, failed_step, evaluator_reason, structured_context_text]).lower()
    reclassification_patterns = [
        ("timeout", r"timed?\s*out|timeout|deadline exceeded|operation exceeded"),
        ("missing_environment", r"android sdk|jdk.*missing|gradle.*not found|java_home|kotlin.*android|docker.*not found"),
        ("sandbox_restriction", r"sandbox.*perm|blocked by.*policy|permission.*policy|not permitted|npm.*blocked"),
        ("review_rejection", r"review.*rejected|reviewer.*fail|not approved|verification step lacks evidence"),
        ("build_failure", r"build failed|compilation error|compile error|linker error"),
        ("test_failure", r"tests?\s+fail|assert.*fail|expect.*fail"),
        ("step_not_completed", r"step.*not.*complet|did not complete|incomplete.*step|step.*fail"),
        ("model_refusal", r"i cannot|i can't|i'm unable|as an ai|not able to|refus"),
        ("coder_blocked", r"cannot run|cannot execute|unable to run|could not run|coder reported failure"),
        ("empty_output", r"empty.*response|null.*output|no.*output.*produced"),
    ]
    for name, pattern in reclassification_patterns:
        if combined_text.strip() and re.search(pattern, combined_text):
            record["classification"] = name
            record["reclassified_from"] = "unknown"
            record["reclassified_source"] = "write_time_auto"
            break
# Store truncated error text for future reclassification of unknowns
if error_text:
    record["error_text"] = error_text[:500]
# Store enriched context with reviewer and evaluator findings for classification improvement
if enriched_text:
    record["enriched_text"] = enriched_text[:800]
# Store the failed step and evaluator reason for better debugging
if failed_step:
    record["failed_step"] = failed_step[:300]
if evaluator_reason:
    record["evaluator_reason"] = evaluator_reason[:300]

with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
}

clamp_prompt_context() {
  local context="${1-}"
  local limit="${2-}"
  local fallback_limit="${MAX_PROMPT_CONTEXT_CHARS:-4000}"
  local marker
  local keep_len=0

  case "$fallback_limit" in
    ''|*[!0-9]*)
      fallback_limit=4000
      ;;
  esac

  if [ -z "$limit" ]; then
    limit="$fallback_limit"
  fi

  case "$limit" in
    ''|*[!0-9]*)
      limit="$fallback_limit"
      ;;
  esac

  marker=$'\n\n[... middle truncated — kept first and last sections ...]\n\n'
  if [ "${#context}" -le "$limit" ]; then
    printf '%s' "$context"
    return 0
  fi

  if [ "$limit" -eq 0 ]; then
    return 0
  fi

  if [ "${#marker}" -ge "$limit" ]; then
    printf '%s' "${marker:0:limit}"
    return 0
  fi

  # Smart truncation: keep 60% from start, 40% from end
  # This preserves both the task description (start) and the most recent context/instructions (end)
  keep_len=$((limit - ${#marker}))
  local head_len=$(( (keep_len * 60) / 100 ))
  local tail_len=$((keep_len - head_len))
  local tail_start=$(( ${#context} - tail_len ))
  printf '%s%s%s' "${context:0:head_len}" "$marker" "${context:tail_start:tail_len}"
}

TRACKED_HELPER_SCRIPTS=(
  "scripts/lib.sh"
  "scripts/multi-queue.sh"
  "scripts/queue-worker.sh"
  "scripts/strategy-loop.sh"
  "agents/strategy.sh"
  "codex-dashboard/server.js"
)
QUEUE_HOT_RELOAD_REQUEST_FILE="$LOG_DIR/queue-hot-reload.request"

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

runtime_user_home() {
  printf '%s/home\n' "$CODEX_RUNTIME_HOME"
}

helper_runtime_state_file() {
  local runtime_file
  runtime_file="$(helper_runtime_legacy_state_file)"
  case "$runtime_file" in
    *.env)
      printf '%s\n' "${runtime_file%.env}.restart-state.env"
      ;;
    *)
      printf '%s.restart-state\n' "$runtime_file"
      ;;
  esac
}

helper_runtime_legacy_state_file() {
  if [ -n "${AGENTCTL_RUNTIME_FILE:-}" ]; then
    printf '%s\n' "$AGENTCTL_RUNTIME_FILE"
  elif [ -n "${RUNTIME_FILE:-}" ]; then
    printf '%s\n' "$RUNTIME_FILE"
  else
    printf '%s\n' "$LOG_DIR/agentctl-runtime.env"
  fi
}

read_helper_runtime_state_field() {
  local field_name="$1"
  local runtime_file legacy_runtime_file
  runtime_file="$(helper_runtime_state_file)"
  legacy_runtime_file="$(helper_runtime_legacy_state_file)"
  if [ -f "$runtime_file" ]; then
    awk -F= -v key="$field_name" '$1==key { print substr($0, length(key) + 2); exit }' "$runtime_file" 2>/dev/null || true
    return 0
  fi
  awk -F= -v key="$field_name" '$1==key { print substr($0, length(key) + 2); exit }' "$legacy_runtime_file" 2>/dev/null || true
}

persist_helper_runtime_state() {
  local restart_needed="$1"
  local helper_marker="$2"
  local detected_at="${3:-}"
  local queue_poll_seconds="${4:-}"
  local queue_workers="${5:-}"
  local runtime_file temp_file
  runtime_file="$(helper_runtime_state_file)"
  [ -n "$runtime_file" ] || return 0
  temp_file="$(mktemp "$LOG_DIR/agentctl-runtime.tmp.XXXXXX")"
  python3 - "$runtime_file" "$temp_file" "$restart_needed" "$helper_marker" "$detected_at" "$(now_utc)" "$queue_poll_seconds" "$queue_workers" "${QUEUE_POLL_SECONDS:-1}" "${QUEUE_WORKERS:-4}" <<'PY'
from pathlib import Path
import re
import sys

runtime_path = Path(sys.argv[1])
temp_path = Path(sys.argv[2])
restart_needed = sys.argv[3]
helper_marker = sys.argv[4]
detected_at = sys.argv[5]
updated_at = sys.argv[6]
queue_poll_seconds = sys.argv[7]
queue_workers = sys.argv[8]
default_poll_seconds = sys.argv[9]
default_queue_workers = sys.argv[10]


def read_existing(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key] = value
    return values


def clamp_int(raw: str, fallback: str, minimum: int, maximum: int) -> str:
    candidate = str(raw or "").strip()
    if not re.fullmatch(r"[0-9]+", candidate):
        candidate = str(fallback or "").strip()
    try:
        value = int(candidate)
    except ValueError:
        value = minimum
    value = max(minimum, min(maximum, value))
    return str(value)

if restart_needed == "true":
    persisted_detected_at = detected_at or updated_at
else:
    persisted_detected_at = detected_at

existing = read_existing(runtime_path)
persisted_poll_seconds = clamp_int(
    queue_poll_seconds or existing.get("queue_poll_seconds", ""),
    default_poll_seconds,
    1,
    10,
)
persisted_queue_workers = clamp_int(
    queue_workers or existing.get("queue_workers", ""),
    default_queue_workers,
    1,
    4,
)

temp_path.parent.mkdir(parents=True, exist_ok=True)
with temp_path.open("w", encoding="utf-8") as handle:
    for key, value in (
        ("queue_helper_fingerprint", helper_marker),
        ("restart_detected_at", persisted_detected_at),
        ("restart_needed", restart_needed),
        ("queue_poll_seconds", persisted_poll_seconds),
        ("queue_workers", persisted_queue_workers),
        ("updated_at", updated_at),
    ):
        handle.write(f"{key}={value}\n")

temp_path.replace(runtime_path)
PY
}

persist_queue_runtime_config() {
  local queue_poll_seconds="${1:-${QUEUE_POLL_SECONDS:-1}}"
  local queue_workers="${2:-${QUEUE_WORKERS:-4}}"
  local runtime_file temp_file
  runtime_file="$(helper_runtime_state_file)"
  [ -n "$runtime_file" ] || return 0
  temp_file="$(mktemp "$LOG_DIR/agentctl-runtime-config.tmp.XXXXXX")"
  python3 - "$runtime_file" "$temp_file" "$queue_poll_seconds" "$queue_workers" "$(now_utc)" <<'PY'
from pathlib import Path
import re
import sys

runtime_path = Path(sys.argv[1])
temp_path = Path(sys.argv[2])
queue_poll_seconds = sys.argv[3]
queue_workers = sys.argv[4]
updated_at = sys.argv[5]


def read_existing(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key] = value
    return values


def clamp_int(raw: str, fallback: str, minimum: int, maximum: int) -> str:
    candidate = str(raw or "").strip()
    if not re.fullmatch(r"[0-9]+", candidate):
        candidate = str(fallback or "").strip()
    try:
        value = int(candidate)
    except ValueError:
        value = minimum
    value = max(minimum, min(maximum, value))
    return str(value)


existing = read_existing(runtime_path)
existing["queue_poll_seconds"] = clamp_int(queue_poll_seconds, existing.get("queue_poll_seconds", "1"), 1, 10)
existing["queue_workers"] = clamp_int(queue_workers, existing.get("queue_workers", "4"), 1, 4)
existing["updated_at"] = updated_at

temp_path.parent.mkdir(parents=True, exist_ok=True)
with temp_path.open("w", encoding="utf-8") as handle:
    for key in (
        "queue_helper_fingerprint",
        "restart_detected_at",
        "restart_needed",
        "queue_poll_seconds",
        "queue_workers",
        "updated_at",
    ):
        handle.write(f"{key}={existing.get(key, '')}\n")

temp_path.replace(runtime_path)
PY
}

sync_restart_needed_status_from_runtime_state() {
  local persisted_restart_needed persisted_marker state project task last_result note status_restart_needed status_marker
  persisted_restart_needed="$(read_helper_runtime_state_field "restart_needed")"
  persisted_marker="$(read_helper_runtime_state_field "queue_helper_fingerprint")"
  if [ -z "$persisted_restart_needed" ] && [ -z "$persisted_marker" ]; then
    return 0
  fi

  status_restart_needed="$(read_status_field_default "restart_needed" "false")"
  status_marker="$(read_status_field_default "helper_scripts_marker" "")"
  persisted_restart_needed="${persisted_restart_needed:-false}"
  if [ "$status_restart_needed" = "$persisted_restart_needed" ] && [ "$status_marker" = "$persisted_marker" ]; then
    return 0
  fi

  state="$(read_status_field "state")"
  project="$(read_status_field "project")"
  task="$(read_status_field "task")"
  last_result="$(read_status_field "last_result")"
  note="$(read_status_field "note")"
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note" "$persisted_restart_needed" "$persisted_marker"
}

ensure_runtime_dirs() {
  mkdir -p \
    "$LOG_DIR" \
    "$RUNS_DIR" \
    "$MEMORY_DIR" \
    "$LEARNING_DIR" \
    "$QUEUE_DIR" \
    "$PROJECTS_DIR" \
    "$DASHBOARD_DIR" \
    "$QUEUE_RETRY_DIR" \
    "$CODEX_RUNTIME_HOME" \
    "$(runtime_user_home)" \
    "$(runtime_user_home)/.config" \
    "$(runtime_user_home)/.cache" \
    "$(runtime_user_home)/.local/share"
  prune_legacy_retry_aliases
  [ -f "$SYSTEM_LOG" ] || : >"$SYSTEM_LOG"
  [ -f "$TASK_LOG" ] || : >"$TASK_LOG"
  [ -f "$TASK_REGISTRY_FILE" ] || printf '{\n  "tasks": []\n}\n' >"$TASK_REGISTRY_FILE"
  [ -f "$DECISIONS_FILE" ] || printf '# Decisions\n\n' >"$DECISIONS_FILE"
  [ -f "$CONTEXT_FILE" ] || printf '# Context\n\n' >"$CONTEXT_FILE"
  [ -f "$RULES_FILE" ] || printf '# Learned Rules\n\n' >"$RULES_FILE"
  [ -f "$RULES_CANDIDATE_FILE" ] || printf '# Candidate Rules\n\n' >"$RULES_CANDIDATE_FILE"
  [ -f "$PROMPT_RULES_FILE" ] || printf '# Prompt Rules\n\n' >"$PROMPT_RULES_FILE"
  [ -f "$RETRY_ANALYSIS_LOG" ] || : >"$RETRY_ANALYSIS_LOG"
  [ -f "$INCIDENT_LOG_FILE" ] || : >"$INCIDENT_LOG_FILE"
  if [ ! -f "$EXTERNAL_SIGNAL_SOURCES_FILE" ]; then
    cat >"$EXTERNAL_SIGNAL_SOURCES_FILE" <<EOF
{
  "auto_refresh": false,
  "refresh_cooldown_seconds": 21600,
  "freshness_window_seconds": 604800,
  "request_timeout_seconds": 8,
  "sources": [
    {
      "id": "openai-python-releases",
      "label": "OpenAI Python releases",
      "kind": "atom",
      "url": "https://github.com/openai/openai-python/releases.atom",
      "topic": "provider_capabilities",
      "category": "code_quality",
      "task_hint": "Review whether the release changes provider integration, prompting, evaluation, or model/tool usage relevant to Codex Agent System.",
      "max_items": 1
    },
    {
      "id": "playwright-releases",
      "label": "Playwright releases",
      "kind": "atom",
      "url": "https://github.com/microsoft/playwright/releases.atom",
      "topic": "browser_automation",
      "category": "stability",
      "task_hint": "Review whether the release changes dashboard verification, screenshot stability, or browser automation behavior relevant to Codex Agent System.",
      "max_items": 1
    },
    {
      "id": "example-youtube-research",
      "label": "Example YouTube research",
      "kind": "youtube_transcript",
      "enabled": false,
      "url": "https://www.youtube.com/watch?v=example",
      "topic": "agent_research",
      "category": "code_quality",
      "task_hint": "Review whether the video suggests a bounded improvement for planning, evaluation, or agent determinism."
    },
    {
      "id": "example-podcast-research",
      "label": "Example podcast research",
      "kind": "media_transcript",
      "enabled": false,
      "transcript_url": "https://example.com/podcast/transcript.txt",
      "topic": "agent_research",
      "category": "code_quality",
      "task_hint": "Review whether the podcast transcript suggests a bounded improvement for strategy, memory, or evaluation."
    },
    {
      "id": "example-web-search",
      "label": "Example web search",
      "kind": "web_search",
      "enabled": false,
      "query": "AI agent reliability deterministic evaluation",
      "topic": "agent_research",
      "category": "stability",
      "task_hint": "Review whether the search results suggest a bounded reliability improvement for the system.",
      "max_items": 3
    }
  ]
}
EOF
  fi
  [ -f "$EXTERNAL_SIGNALS_FILE" ] || printf '{\n  "updated_at": "",\n  "source_count": 0,\n  "signal_count": 0,\n  "signals": [],\n  "errors": []\n}\n' >"$EXTERNAL_SIGNALS_FILE"
  [ -f "$INCIDENTS_FILE" ] || default_incidents_payload >"$INCIDENTS_FILE"
  [ -f "$ALERTS_FILE" ] || default_alerts_payload >"$ALERTS_FILE"
  if [ ! -f "$METRICS_FILE" ]; then
  cat >"$METRICS_FILE" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 0,
  "incident_records": 0,
  "incident_critical_records": 0,
  "incident_notification_records": 0,
  "last_incident_at": "",
  "last_incident_type": "",
  "last_incident_failure_kind": "",
  "last_incident_severity": "",
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 0,
  "task_registry_pressure_detected": false,
  "task_registry_pressure_primary_surface": "",
  "task_registry_pressure_sources": [],
  "last_task_score": 0,
  "manual_recovery_records": 0,
  "strategy_saturation_detected": false,
  "saturated_failed_tasks": 0,
  "retry_churn_detected": false,
  "queue_starvation_detected": false,
  "pending_approval_blocked_detected": false,
  "first_pass_success_rate": 0,
  "first_pass_success_count": 0,
  "multi_attempt_resolved_count": 0,
  "loop_effort_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "loop_effort_bounded_experiment_detected": false,
  "loop_effort_bounded_experiment_metric_name": "loop_effort_extra_step_attempts",
  "loop_effort_bounded_experiment_extra_step_threshold": 2,
  "loop_effort_bounded_experiment_message": "Bounded loop effort experiment inactive because loop_effort_extra_step_attempts is below 2.",
  "external_signal_status": "missing",
  "external_signal_count": 0,
  "fresh_external_signal_count": 0,
  "external_signal_error_count": 0,
  "external_signal_updated_at": "",
  "latest_external_signal_source": "",
  "latest_external_signal_title": "",
  "latest_external_signal_url": "",
  "latest_external_signal_published_at": ""
}
EOF
  fi
  if [ ! -f "$STATUS_FILE" ]; then
    cat >"$STATUS_FILE" <<EOF
state=idle
project=
task=
last_result=NONE
note=System initialized
restart_needed=false
helper_scripts_marker=
updated_at=$(now_utc)
EOF
  fi
  sync_restart_needed_status_from_runtime_state
}

log_msg() {
  local level="$1"
  local component="$2"
  shift 2
  ensure_runtime_dirs
  local line
  line="[$(now_utc)] [$component] ${level}: $*"
  printf '%s\n' "$line" | tee -a "$SYSTEM_LOG" >&2
}

fail_low_completion_gate() {
  local completion="${1:-}"
  local threshold="${2:-}"
  local reason="${3:-unspecified reason}"

  log_msg ERROR orchestrator "Low-completion gate failed: completion=${completion:-unknown} threshold=${threshold:-unknown} reason=${reason}"
  return 1
}

install_error_trap() {
  local component="$1"
  trap 'rc=$?; log_msg ERROR "'"$component"'" "Command failed at line ${BASH_LINENO[0]:-0} with exit code ${rc}"; exit "$rc"' ERR
}

read_status_field() {
  local field_name="$1"
  awk -F= -v key="$field_name" '$1==key { print substr($0, length(key) + 2); exit }' "$STATUS_FILE" 2>/dev/null || true
}

read_status_field_default() {
  local field_name="$1"
  local default_value="${2:-}"
  local value
  value="$(read_status_field "$field_name")"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

prune_legacy_retry_aliases() {
  local retry_file
  [ -d "$QUEUE_RETRY_DIR" ] || return 0
  for retry_file in "$QUEUE_RETRY_DIR"/*__*.retry; do
    [ -e "$retry_file" ] || continue
    rm -f "$retry_file"
  done
}

helper_scripts_marker() {
  python3 - "$ROOT_DIR" "${TRACKED_HELPER_SCRIPTS[@]}" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [pathlib.Path(path) for path in sys.argv[2:]]
digest = hashlib.sha256()

for relative_path in paths:
    target = root / relative_path
    digest.update(relative_path.as_posix().encode("utf-8"))
    digest.update(b"\0")
    if target.is_file():
        digest.update(target.read_bytes())
    else:
        digest.update(b"missing")
    digest.update(b"\0")

print(digest.hexdigest())
PY
}

write_status_with_restart_state() {
  local state="$1"
  local project="$2"
  local task="$3"
  local last_result="$4"
  local note="$5"
  local restart_needed="${6:-$(read_status_field_default "restart_needed" "false")}"
  local helper_marker="${7:-$(read_status_field_default "helper_scripts_marker" "")}"
  cat >"$STATUS_FILE" <<EOF
state=$state
project=$project
task=$task
last_result=$last_result
note=$note
restart_needed=$restart_needed
helper_scripts_marker=$helper_marker
updated_at=$(now_utc)
EOF
}

write_status() {
  local state="$1"
  local project="$2"
  local task="$3"
  local last_result="${4:-UNKNOWN}"
  local note="${5:-}"
  ensure_runtime_dirs
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note"
}

clear_restart_needed_status() {
  local state project task last_result note current_marker
  ensure_runtime_dirs
  state="$(read_status_field "state")"
  project="$(read_status_field "project")"
  task="$(read_status_field "task")"
  last_result="$(read_status_field "last_result")"
  note="$(read_status_field "note")"
  current_marker="$(helper_scripts_marker)"
  persist_helper_runtime_state "false" "$current_marker" ""
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note" "false" "$current_marker"
}

helper_scripts_reload_required() {
  local persisted_marker current_marker
  ensure_runtime_dirs
  persisted_marker="$(read_helper_runtime_state_field "queue_helper_fingerprint")"
  if [ -z "$persisted_marker" ]; then
    persisted_marker="$(read_status_field_default "helper_scripts_marker" "")"
  fi
  current_marker="$(helper_scripts_marker)"
  [ "$persisted_marker" != "$current_marker" ]
}

process_helper_reload_required() {
  local process_marker="${1:-}"
  local current_marker
  ensure_runtime_dirs
  current_marker="$(helper_scripts_marker)"
  [ "$process_marker" != "$current_marker" ]
}

update_restart_needed_status_for_helper_scripts() {
  local persisted_marker current_marker runtime_marker state project task last_result note detected_at
  ensure_runtime_dirs
  persisted_marker="$(read_helper_runtime_state_field "queue_helper_fingerprint")"
  if [ -z "$persisted_marker" ]; then
    persisted_marker="$(read_status_field_default "helper_scripts_marker" "")"
  fi
  current_marker="$(helper_scripts_marker)"
  if [ "$persisted_marker" = "$current_marker" ]; then
    return 0
  fi
  runtime_marker="${persisted_marker:-$current_marker}"

  state="$(read_status_field "state")"
  project="$(read_status_field "project")"
  task="$(read_status_field "task")"
  last_result="$(read_status_field "last_result")"
  note="$(read_status_field "note")"
  detected_at="$(read_helper_runtime_state_field "restart_detected_at")"
  if [ -z "$detected_at" ] || [ "$persisted_marker" != "$current_marker" ]; then
    detected_at="$(now_utc)"
  fi
  persist_helper_runtime_state "true" "$runtime_marker" "$detected_at"
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note" "true" "$runtime_marker"
}

request_queue_hot_reload() {
  ensure_runtime_dirs
  cat >"$QUEUE_HOT_RELOAD_REQUEST_FILE" <<EOF
requested_at=$(now_utc)
reason=${1:-manual_reload}
EOF
}

clear_queue_hot_reload_request() {
  rm -f "$QUEUE_HOT_RELOAD_REQUEST_FILE"
}

queue_hot_reload_requested() {
  [ -f "$QUEUE_HOT_RELOAD_REQUEST_FILE" ]
}

update_agentctl_runtime_helper_fingerprint() {
  local current_marker
  local restart_needed detected_at
  current_marker="$(helper_scripts_marker)"
  restart_needed="$(read_helper_runtime_state_field "restart_needed")"
  detected_at="$(read_helper_runtime_state_field "restart_detected_at")"
  persist_helper_runtime_state "${restart_needed:-false}" "$current_marker" "$detected_at"
}

finalize_queue_hot_reload() {
  update_agentctl_runtime_helper_fingerprint || true
  clear_restart_needed_status
  clear_queue_hot_reload_request
}

trim_text() {
  printf '%s' "$1" | awk '{$1=$1; print}'
}

append_task_log_record() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local result="${3:-UNKNOWN}"
  local attempts="${4:-0}"
  local score="${5:-0}"
  local branch="${6:-}"
  local pr_url="${7:-}"
  local run_id="${8:-}"
  local duration="${9:-0}"
  local provider="${10:-}"
  local failure_kind="${11:-}"
  local total_step_attempts="${12:-0}"
  local task_id="${13:-}"
  local failed_step_index="${14:-0}"
  local failed_step_text="${15:-}"
  local normalized_failure_kind="$failure_kind"

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0

  ensure_runtime_dirs

  if failure_kind_needs_reclassification "$normalized_failure_kind" && [ -n "$(trim_text "$failed_step_text")" ]; then
    local classified_failure_kind=""
    classified_failure_kind="$(classify_retry_failure "$failed_step_text")"
    if [ -n "$(trim_text "$classified_failure_kind")" ] && [ "$classified_failure_kind" != "unknown" ]; then
      normalized_failure_kind="$classified_failure_kind"
    fi
  fi

  python3 - "$TASK_LOG" "$project_name" "$queue_task" "$result" "$attempts" "$score" "$branch" "$pr_url" "$run_id" "$duration" "$provider" "$normalized_failure_kind" "$total_step_attempts" "$task_id" "$failed_step_index" "$failed_step_text" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

(
    path,
    project,
    task,
    result,
    attempts,
    score,
    branch,
    pr_url,
    run_id,
    duration,
    provider,
    failure_kind,
    total_step_attempts,
    task_id,
    failed_step_index,
    failed_step_text,
) = sys.argv[1:]


def normalize_int(value: str) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def normalize_text(value: str) -> str:
    return " ".join(str(value or "").split())

record = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "project": project,
    "task": task,
    "provider": provider,
    "result": result,
    "attempts": int(attempts or 0),
    "score": int(score or 0),
    "branch": branch,
    "pr_url": pr_url,
    "run_id": run_id,
    "duration_seconds": int(duration or 0),
    "total_step_attempts": normalize_int(total_step_attempts),
}
if failure_kind:
    record["failure_kind"] = failure_kind
if task_id:
    record["task_id"] = task_id
normalized_failed_step_index = normalize_int(failed_step_index)
normalized_failed_step_text = normalize_text(failed_step_text)
if normalized_failed_step_index > 0:
    record["failed_step_index"] = normalized_failed_step_index
if normalized_failed_step_text:
    record["failed_step"] = normalized_failed_step_text

with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

safe_read_file() {
  local file_path="$1"
  if [ -f "$file_path" ]; then
    cat "$file_path"
  fi
}

safe_tail() {
  local line_count="$1"
  local file_path="$2"
  tail -n "$line_count" "$file_path" 2>/dev/null || true
}

safe_tail_structured_logs() {
  local line_count="$1"
  local file_path="$2"
  grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$file_path" 2>/dev/null | tail -n "$line_count" || true
}

normalize_task() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

project_state_dir() {
  printf '%s/%s\n' "$PROJECTS_DIR" "$1"
}

project_metadata_file() {
  printf '%s/project.json\n' "$(project_state_dir "$1")"
}

read_project_metadata_field_raw() {
  local project_name="$1"
  local field_name="$2"
  local metadata_file
  metadata_file="$(project_metadata_file "$project_name")"
  [ -f "$metadata_file" ] || return 0

  python3 - "$metadata_file" "$field_name" <<'PY'
import json
import sys

path, field_name = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    payload = {}

value = str(payload.get(field_name) or "").strip()
if value:
    print(value)
PY
}

read_project_data_breach_monitor_metadata() {
  local project_name="$1"
  local metadata_file
  metadata_file="$(project_metadata_file "$project_name")"

  python3 - "$metadata_file" <<'PY'
import json
import shlex
import sys

path = sys.argv[1]

def normalize(value, fallback, *, lower=False):
    text = str(value or "").strip()
    if not text:
        text = fallback
    if lower:
        text = text.lower()
    return text

payload = {}
if path:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        payload = {}

monitor = payload.get("monitors")
if not isinstance(monitor, dict):
    monitor = {}
monitor = monitor.get("data_breach")
if not isinstance(monitor, dict):
    monitor = {}

status = normalize(monitor.get("status"), "unknown", lower=True)
target = normalize(monitor.get("target"), "unknown")
traffic_light = normalize(monitor.get("traffic_light"), "yellow", lower=True)

print(f"status={shlex.quote(status)}")
print(f"target={shlex.quote(target)}")
print(f"traffic_light={shlex.quote(traffic_light)}")
PY
}

configured_project_path() {
  local project_name="$1"
  local metadata_field="$2"
  local fallback_path="$3"
  local configured_path
  configured_path="$(read_project_metadata_field_raw "$project_name" "$metadata_field")"
  if [ -n "$configured_path" ]; then
    printf '%s\n' "$configured_path"
    return 0
  fi
  printf '%s\n' "$fallback_path"
}

project_memory_file() {
  local project_name="$1"
  configured_project_path "$project_name" "memory_file" "$(project_state_dir "$project_name")/memory.md"
}

project_spec_file() {
  local project_name="$1"
  configured_project_path "$project_name" "spec_file" "$(project_state_dir "$project_name")/spec.md"
}

project_policy_file() {
  local project_name="$1"
  configured_project_path "$project_name" "policy_file" "$(project_state_dir "$project_name")/policy.json"
}

project_task_registry_file() {
  local project_name="$1"
  configured_project_path "$project_name" "task_registry_file" "$TASK_REGISTRY_FILE"
}

project_automation_id() {
  local project_name="$1"
  read_project_metadata_field_raw "$project_name" "automation_id"
}

task_registry_file_for_project() {
  local project_name="${1:-}"
  if [ -n "$project_name" ]; then
    project_task_registry_file "$project_name"
    return 0
  fi
  printf '%s\n' "$TASK_REGISTRY_FILE"
}

project_task_registry_status_count() {
  local project_name="${1:-}"
  shift || true
  local registry_file
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$@" <<'PY'
import json
import re
import sys

registry_path = sys.argv[1]
project_name = sys.argv[2]
statuses = {str(value or "").strip().lower() for value in sys.argv[3:] if str(value or "").strip()}


def normalize_project(value: str) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


if not statuses:
    print("0")
    raise SystemExit(0)

try:
    with open(registry_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    print("-1")
    raise SystemExit(0)

tasks = payload.get("tasks")
if not isinstance(tasks, list):
    print("-1")
    raise SystemExit(0)

project_key = normalize_project(project_name)
count = 0
for task in tasks:
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if project_key and task_project != project_key:
        continue
    if str(task.get("status") or "").strip().lower() in statuses:
        count += 1

print(count)
PY
}

project_task_registry_pressure_state() {
  local project_name="${1:-}"
  local metrics_file="${2:-$METRICS_FILE}"
  local registry_file
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$metrics_file" "$project_name" "$registry_file" <<'PY'
import json
import os
import re
import sys

TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000

metrics_path = sys.argv[1]
project_name = sys.argv[2]
registry_file = sys.argv[3]


def normalize_project(value: str) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def safe_int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def emit(global_detected: bool, effective_detected: bool, reason: str, global_bytes: int, local_bytes: int, dominant_project: str) -> None:
    print(
        "\t".join(
            (
                "true" if global_detected else "false",
                "true" if effective_detected else "false",
                reason,
                str(max(global_bytes, 0)),
                str(max(local_bytes, 0)),
                dominant_project,
            )
        )
    )


try:
    with open(metrics_path, "r", encoding="utf-8") as handle:
        metrics = json.load(handle)
except Exception:
    emit(False, False, "metrics_unavailable", 0, 0, "")
    raise SystemExit(0)

if not isinstance(metrics, dict):
    emit(False, False, "metrics_unavailable", 0, 0, "")
    raise SystemExit(0)

project_key = normalize_project(project_name)
global_bytes = max(
    safe_int(
        metrics.get("task_registry_payload_bytes")
        if metrics.get("task_registry_payload_bytes") is not None
        else metrics.get("task_registry_pressure_bytes")
    ),
    0,
)
global_detected = (
    metrics.get("task_registry_pressure_detected") is True
    or global_bytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD
)

sources = metrics.get("task_registry_pressure_sources")
if not isinstance(sources, list):
    sources = []

dominant_project = ""
dominant_bytes = -1
local_bytes = 0

for entry in sources:
    if not isinstance(entry, dict):
        continue
    source_project = str(entry.get("project") or "").strip()
    source_project_key = normalize_project(source_project)
    payload_bytes = max(safe_int(entry.get("payload_bytes")), 0)
    if payload_bytes > dominant_bytes:
        dominant_project = source_project
        dominant_bytes = payload_bytes
    if source_project_key == project_key and payload_bytes > local_bytes:
        local_bytes = payload_bytes

if local_bytes <= 0 and registry_file:
    try:
        local_bytes = max(int(os.path.getsize(registry_file)), 0)
    except OSError:
        local_bytes = 0

if not global_detected:
    emit(False, False, "not_detected", global_bytes, local_bytes, dominant_project)
    raise SystemExit(0)

dominant_project_key = normalize_project(dominant_project)
if dominant_project_key and dominant_project_key != project_key and local_bytes < TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD:
    emit(True, False, "cross_project_registry_pressure", global_bytes, local_bytes, dominant_project)
    raise SystemExit(0)

reason = "local_registry_pressure"
if dominant_project_key and dominant_project_key != project_key:
    reason = "shared_registry_pressure"

emit(True, True, reason, global_bytes, local_bytes, dominant_project)
PY
}

project_automation_memory_dir() {
  printf '%s/automation-memory\n' "$(project_state_dir "$1")"
}

project_strategy_health_state() {
  local project_name="$1"
  local metrics_file="${2:-$METRICS_FILE}"
  local registry_file
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$metrics_file" "$project_name" "$registry_file" "$TASK_LOG" "$ROOT_DIR/scripts" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
project_name = sys.argv[2]
registry_file = Path(sys.argv[3]) if len(sys.argv) > 3 and str(sys.argv[3]).strip() else None
task_log_path = Path(sys.argv[4])
scripts_dir = Path(sys.argv[5])
if str(scripts_dir) not in sys.path:
    sys.path.insert(0, str(scripts_dir))

try:
    from task_metrics import build_loop_effort_signal, build_persisted_board_health_signals
except Exception:
    build_loop_effort_signal = None
    build_persisted_board_health_signals = None


def normalize_project(value: object) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def read_json(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def emit(
    success_rate: float,
    total_tasks: int,
    retry_churn: bool,
    loop_effort: bool,
    global_success_rate: float,
    global_total_tasks: int,
    global_retry_churn: bool,
    global_loop_effort: bool,
    scope: str,
) -> None:
    def fmt_rate(value: float) -> str:
        return f"{round(value, 2):.2f}".rstrip("0").rstrip(".") or "0"

    print(
        "\t".join(
            (
                fmt_rate(success_rate),
                str(max(total_tasks, 0)),
                "true" if retry_churn else "false",
                "true" if loop_effort else "false",
                fmt_rate(global_success_rate),
                str(max(global_total_tasks, 0)),
                "true" if global_retry_churn else "false",
                "true" if global_loop_effort else "false",
                scope,
            )
        )
    )


project_key = normalize_project(project_name)
metrics = read_json(metrics_path)
global_success_rate = round(safe_float(metrics.get("success_rate")), 2)
global_total_tasks = max(safe_int(metrics.get("total_tasks")), 0)
global_retry_churn = metrics.get("retry_churn_detected") is True
global_loop_effort = metrics.get("loop_effort_detected") is True

project_tasks: list[dict[str, object]] = []
registry_loaded = False
if registry_file and registry_file.exists():
    registry_payload = read_json(registry_file)
    tasks = registry_payload.get("tasks")
    if isinstance(tasks, list):
        registry_loaded = True
        project_tasks = [
            task
            for task in tasks
            if isinstance(task, dict)
            and normalize_project(task.get("project") or task.get("target_project") or project_name) == project_key
        ]

project_records: list[dict[str, object]] = []
task_log_loaded = False
if task_log_path.exists():
    task_log_loaded = True
    for raw_line in task_log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue
        if not isinstance(record, dict):
            continue
        if normalize_project(record.get("project") or record.get("target_project") or project_name) != project_key:
            continue
        result = str(record.get("result") or "").strip().upper()
        if result not in {"SUCCESS", "FAILURE"}:
            continue
        project_records.append(record)

project_total_tasks = len(project_records)
project_success_rate = round(
    sum(1 for record in project_records if str(record.get("result") or "").strip().upper() == "SUCCESS")
    / project_total_tasks,
    2,
) if project_total_tasks else 0.0

project_retry_churn = False
project_loop_effort = False
if registry_loaded and build_persisted_board_health_signals is not None:
    try:
        project_retry_churn = bool(build_persisted_board_health_signals(project_tasks).get("retry_churn_detected"))
    except Exception:
        project_retry_churn = False
if registry_loaded and build_loop_effort_signal is not None:
    try:
        project_loop_effort = bool(build_loop_effort_signal(project_tasks).get("detected"))
    except Exception:
        project_loop_effort = False

if registry_loaded or task_log_loaded:
    emit(
        project_success_rate if task_log_loaded else global_success_rate,
        project_total_tasks if task_log_loaded else global_total_tasks,
        project_retry_churn if registry_loaded else global_retry_churn,
        project_loop_effort if registry_loaded else global_loop_effort,
        global_success_rate,
        global_total_tasks,
        global_retry_churn,
        global_loop_effort,
        "project_local",
    )
else:
    emit(
        global_success_rate,
        global_total_tasks,
        global_retry_churn,
        global_loop_effort,
        global_success_rate,
        global_total_tasks,
        global_retry_churn,
        global_loop_effort,
        "metrics_fallback",
    )
PY
}

project_automation_memory_file() {
  local project_name="$1"
  local automation_id="$2"
  printf '%s/%s.md\n' "$(project_automation_memory_dir "$project_name")" "$automation_id"
}

automation_memory_dir() {
  local automation_id="$1"
  local codex_home="${CODEX_HOME:-}"
  if [ -z "$codex_home" ] && [ -n "${HOME:-}" ]; then
    codex_home="$HOME/.codex"
  fi
  [ -n "$codex_home" ] || return 1
  [ -n "$automation_id" ] || return 1
  printf '%s/automations/%s\n' "$codex_home" "$automation_id"
}

automation_memory_file() {
  local automation_id="$1"
  local memory_dir
  memory_dir="$(automation_memory_dir "$automation_id")" || return 1
  printf '%s/memory.md\n' "$memory_dir"
}

automation_memory_entry_limit() {
  local raw_limit="${AUTOMATION_MEMORY_MAX_ENTRIES:-256}"
  case "$raw_limit" in
    ''|*[!0-9]*)
      printf '256\n'
      ;;
    *)
      if [ "$raw_limit" -lt 1 ]; then
        printf '1\n'
      else
        printf '%s\n' "$raw_limit"
      fi
      ;;
  esac
}

automation_memory_summary_with_sync_status() {
  local summary_line="$1"
  local sync_pending="${2:-true}"

  [ -n "$summary_line" ] || return 1

  python3 - "$summary_line" "$sync_pending" <<'PY'
import re
import sys

summary_line = sys.argv[1].strip()
sync_pending = "true" if sys.argv[2].strip().lower() == "true" else "false"

normalized = re.sub(
    r'([;|])?\s*external_sync_pending=(?:true|false)\s*$',
    '',
    summary_line,
    flags=re.IGNORECASE,
).rstrip()

if normalized:
    print(f"{normalized} | external_sync_pending={sync_pending}")
else:
    print(f"external_sync_pending={sync_pending}")
PY
}

initialize_automation_memory_file() {
  local memory_file="$1"
  local project_name="$2"
  local automation_id="$3"

  [ -n "$memory_file" ] || return 1
  [ -n "$project_name" ] || return 1
  [ -n "$automation_id" ] || return 1

  mkdir -p "$(dirname "$memory_file")"
  if [ ! -f "$memory_file" ]; then
    cat >"$memory_file" <<EOF
# Automation Memory

project: $project_name
automation_id: $automation_id

EOF
  fi
}

sync_automation_memory_entries_to_file() {
  local target_file="$1"
  local peer_file="$2"
  local project_name="$3"
  local automation_id="$4"
  local summary_line="${5:-}"
  local entry_limit="${6:-$(automation_memory_entry_limit)}"

  [ -n "$target_file" ] || return 1
  [ -n "$project_name" ] || return 1
  [ -n "$automation_id" ] || return 1

  python3 - "$target_file" "$peer_file" "$project_name" "$automation_id" "$summary_line" "$entry_limit" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import re
import sys

target_path = Path(sys.argv[1])
peer_raw = sys.argv[2].strip()
peer_path = Path(peer_raw) if peer_raw else None
project_name = sys.argv[3]
automation_id = sys.argv[4]
summary_line = sys.argv[5].strip()
try:
    entry_limit = max(int(sys.argv[6]), 1)
except (TypeError, ValueError):
    entry_limit = 256

LEADING_TIMESTAMP_RE = re.compile(r"^-\s+(\d{4}-\d{2}-\d{2}T[^\s|]+)")
FIELD_TIMESTAMP_RE = re.compile(r"\btimestamp=(\d{4}-\d{2}-\d{2}T[^\s|]+)")


def canonical_key(line: str) -> str:
    normalized = re.sub(
        r'([;|])?\s*external_sync_pending=(?:true|false)\s*$',
        '',
        line.strip(),
        flags=re.IGNORECASE,
    ).rstrip()
    return normalized or line.strip()


def parse_timestamp(text):
    normalized = text.strip()
    if not normalized:
        return None
    if normalized.endswith("Z"):
        normalized = f"{normalized[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def extract_timestamp(line):
    for pattern in (LEADING_TIMESTAMP_RE, FIELD_TIMESTAMP_RE):
        match = pattern.search(line)
        if not match:
            continue
        parsed = parse_timestamp(match.group(1))
        if parsed is not None:
            return (1, parsed.isoformat())
    return (0, "")


def merge_entries(existing, path, sequence):
    if path is None or not path.exists():
        return sequence
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if line.startswith("- "):
            existing[canonical_key(line)] = {
                "line": line,
                "timestamp": extract_timestamp(line),
                "sequence": sequence,
            }
            sequence += 1
    return sequence


entries: dict[str, dict[str, object]] = {}
sequence = 0
sequence = merge_entries(entries, target_path, sequence)
sequence = merge_entries(entries, peer_path, sequence)
if summary_line:
    entries[canonical_key(summary_line)] = {
        "line": summary_line,
        "timestamp": extract_timestamp(summary_line),
        "sequence": sequence,
    }

ordered_entries = sorted(
    entries.values(),
    key=lambda entry: (
        entry.get("timestamp") or (0, ""),
        int(entry.get("sequence", 0)),
    ),
)
if len(ordered_entries) > entry_limit:
    ordered_entries = ordered_entries[-entry_limit:]

target_path.parent.mkdir(parents=True, exist_ok=True)
with target_path.open("w", encoding="utf-8") as handle:
    handle.write("# Automation Memory\n\n")
    handle.write(f"project: {project_name}\n")
    handle.write(f"automation_id: {automation_id}\n\n")
    for entry in ordered_entries:
        handle.write(f"{entry['line']}\n")
PY
}

sync_automation_memory_to_external_if_available() {
  local project_name="$1"
  local automation_id="$2"
  local summary_line="${3:-}"
  local external_file
  local mirror_file

  AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING=true

  [ -n "$project_name" ] || return 1
  [ -n "$automation_id" ] || return 1

  mirror_file="$(project_automation_memory_file "$project_name" "$automation_id")"
  if [ ! -f "$mirror_file" ] && [ -z "$summary_line" ]; then
    return 1
  fi

  if external_file="$(automation_memory_file "$automation_id" 2>/dev/null)"; then
    if initialize_automation_memory_file "$external_file" "$project_name" "$automation_id" 2>/dev/null; then
      if sync_automation_memory_entries_to_file "$external_file" "$mirror_file" "$project_name" "$automation_id" "$summary_line" 2>/dev/null; then
        sync_automation_memory_entries_to_file "$mirror_file" "$external_file" "$project_name" "$automation_id" "$summary_line" >/dev/null 2>&1 || true
        AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING=false
        return 0
      fi
    fi
  fi

  return 1
}

resolve_automation_memory_read_file() {
  local project_name="$1"
  local automation_id="$2"
  local external_file=""
  local mirror_file=""
  local hydrate_external_from_mirror=false

  AUTOMATION_MEMORY_RESOLVED_FILE=""
  AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING=true
  AUTOMATION_MEMORY_EXTERNAL_HYDRATED=false
  AUTOMATION_MEMORY_RESOLVED_SOURCE=none

  [ -n "$project_name" ] || return 1
  [ -n "$automation_id" ] || return 1

  mirror_file="$(project_automation_memory_file "$project_name" "$automation_id")"
  external_file="$(automation_memory_file "$automation_id" 2>/dev/null || true)"

  if [ -n "$external_file" ]; then
    if [ ! -f "$external_file" ] && [ -f "$mirror_file" ]; then
      hydrate_external_from_mirror=true
    fi
    if initialize_automation_memory_file "$external_file" "$project_name" "$automation_id" 2>/dev/null; then
      if [ -f "$mirror_file" ]; then
        if sync_automation_memory_entries_to_file "$external_file" "$mirror_file" "$project_name" "$automation_id" "" 2>/dev/null; then
          sync_automation_memory_entries_to_file "$mirror_file" "$external_file" "$project_name" "$automation_id" "" >/dev/null 2>&1 || true
          if [ "$hydrate_external_from_mirror" = true ]; then
            AUTOMATION_MEMORY_EXTERNAL_HYDRATED=true
          fi
        fi
      fi

      AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING=false
      AUTOMATION_MEMORY_RESOLVED_SOURCE=external
      AUTOMATION_MEMORY_RESOLVED_FILE="$external_file"
      printf '%s\n' "$external_file"
      return 0
    fi
  fi

  if [ -f "$mirror_file" ]; then
    AUTOMATION_MEMORY_RESOLVED_SOURCE=mirror
    AUTOMATION_MEMORY_RESOLVED_FILE="$mirror_file"
    printf '%s\n' "$mirror_file"
    return 0
  fi

  return 1
}

append_automation_memory_mirror() {
  local project_name="$1"
  local automation_id="$2"
  local summary_line="$3"
  local memory_file

  [ -n "$project_name" ] || return 0
  [ -n "$automation_id" ] || return 0
  [ -n "$summary_line" ] || return 0

  ensure_project_state "$project_name"
  memory_file="$(project_automation_memory_file "$project_name" "$automation_id")"
  initialize_automation_memory_file "$memory_file" "$project_name" "$automation_id"
  sync_automation_memory_entries_to_file "$memory_file" "" "$project_name" "$automation_id" "$summary_line" "$(automation_memory_entry_limit)"
}

append_automation_memory_entry() {
  local project_name="$1"
  local automation_id="$2"
  local summary_line="$3"
  local pending_summary
  local synced_summary

  AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING=true

  [ -n "$project_name" ] || return 0
  [ -n "$automation_id" ] || return 0
  [ -n "$summary_line" ] || return 0

  pending_summary="$(automation_memory_summary_with_sync_status "$summary_line" true)" || return 1
  append_automation_memory_mirror "$project_name" "$automation_id" "$pending_summary"

  synced_summary="$(automation_memory_summary_with_sync_status "$summary_line" false)" || return 1
  if sync_automation_memory_to_external_if_available "$project_name" "$automation_id" "$synced_summary"; then
    return 0
  fi
}

read_automation_memory_context() {
  local project_name="${1:-}"
  local line_count="${2:-8}"
  local automation_id=""
  local memory_file=""

  [ -n "$project_name" ] || return 0
  automation_id="$(project_automation_id "$project_name")"
  [ -n "$automation_id" ] || return 0

  if resolve_automation_memory_read_file "$project_name" "$automation_id" >/dev/null 2>&1; then
    memory_file="${AUTOMATION_MEMORY_RESOLVED_FILE:-}"
  fi

  [ -n "$memory_file" ] || return 0
  [ -f "$memory_file" ] || return 0

  printf '%s\n' "# Automation Memory (recent)"
  tail -n "$line_count" "$memory_file" 2>/dev/null || true
  printf '\n'
}

default_project_workspace() {
  local project_name="$1"
  if [ "$project_name" = "codex-agent-system" ]; then
    printf '%s\n' "$ROOT_DIR"
    return 0
  fi
  printf '%s/%s\n' "$PROJECTS_DIR" "$project_name"
}

default_project_repo_url() {
  local project_name="$1"
  if [ "$project_name" = "codex-agent-system" ]; then
    printf '%s\n' "https://github.com/push2main/codex-agent-system/"
    return 0
  fi
  printf '\n'
}

default_project_automation_id() {
  local project_name="$1"
  if [ "$project_name" = "codex-agent-system" ]; then
    printf '%s\n' "push2main-codex-agent-system"
    return 0
  fi
  printf '\n'
}

write_project_metadata() {
  local metadata_file="$1"
  local project_name="$2"
  local workspace="$3"
  local repo_url="$4"
  local memory_file="$5"
  local spec_file="$6"
  local policy_file="$7"
  local task_registry_file="$8"
  local automation_id="${9:-}"

  python3 - "$metadata_file" "$project_name" "$workspace" "$repo_url" "$memory_file" "$spec_file" "$policy_file" "$task_registry_file" "$automation_id" <<'PY'
import json
import os
import sys

path, project, workspace, repo_url, memory_file, spec_file, policy_file, task_registry_file, automation_id = sys.argv[1:]
payload = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            existing = json.load(handle)
        if isinstance(existing, dict):
            payload = existing
    except Exception:
        payload = {}

payload.update({
    "project": project,
    "project_id": project,
    "workspace": workspace,
    "repo_url": repo_url,
    "memory_file": memory_file,
    "spec_file": spec_file,
    "policy_file": policy_file,
    "task_registry_file": task_registry_file,
})
if automation_id.strip():
    payload["automation_id"] = automation_id.strip()
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

ensure_project_state() {
  local project_name="$1"
  local project_dir metadata_file memory_file spec_file policy_file task_registry_file workspace repo_url automation_id
  project_dir="$(project_state_dir "$project_name")"
  metadata_file="$(project_metadata_file "$project_name")"
  memory_file="$(project_memory_file "$project_name")"
  spec_file="$(project_spec_file "$project_name")"
  policy_file="$(project_policy_file "$project_name")"
  task_registry_file="$(project_task_registry_file "$project_name")"
  workspace="$(default_project_workspace "$project_name")"
  repo_url="$(default_project_repo_url "$project_name")"
  automation_id="$(read_project_metadata_field_raw "$project_name" "automation_id")"
  if [ -z "$automation_id" ]; then
    automation_id="$(default_project_automation_id "$project_name")"
  fi

  mkdir -p "$project_dir"

  if [ "$project_name" = "codex-agent-system" ] || [ ! -f "$metadata_file" ]; then
    write_project_metadata "$metadata_file" "$project_name" "$workspace" "$repo_url" "$memory_file" "$spec_file" "$policy_file" "$task_registry_file" "$automation_id"
  fi

  if [ ! -f "$memory_file" ] && [[ "$memory_file" == "$project_dir/"* ]]; then
    cat >"$memory_file" <<EOF
# Project Memory

project: $project_name
workspace: $workspace
repo_url: $repo_url

EOF
  fi

  if [ ! -f "$spec_file" ] && [[ "$spec_file" == "$project_dir/"* ]]; then
    cat >"$spec_file" <<EOF
# Project Spec

project: $project_name

## Goal

Document the product scope, technical constraints, and first safe milestones for this project.

## Constraints

- Keep changes small and reversible
- Prefer deterministic verification
- Add project-specific rules before broad feature work
EOF
  fi

  if [ ! -f "$policy_file" ] && [[ "$policy_file" == "$project_dir/"* ]]; then
    cat >"$policy_file" <<EOF
{
  "project": "$project_name",
  "risk_profile": "standard",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF
  fi
}

read_project_metadata_field() {
  read_project_metadata_field_raw "$1" "$2"
}

resolve_project_workspace() {
  local project_name="$1"
  local workspace
  ensure_project_state "$project_name"
  workspace="$(read_project_metadata_field "$project_name" "workspace")"
  if [ -n "$workspace" ]; then
    printf '%s\n' "$workspace"
    return 0
  fi
  default_project_workspace "$project_name"
}

queue_task_count() {
  local total=0
  local file
  shopt -s nullglob
  for file in "$QUEUE_DIR"/*.txt; do
    local count
    count="$(awk 'NF { count += 1 } END { print count + 0 }' "$file")"
    total=$((total + count))
  done
  shopt -u nullglob
  printf '%s\n' "$total"
}

dedupe_queue_file() {
  local queue_file="$1"
  [ -f "$queue_file" ] || return 0

  local before_count after_count temp_file
  before_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$queue_file")"
  temp_file="$(mktemp)"
  awk '
    NF {
      original=$0
      cleaned=tolower($0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", original)
      gsub(/[[:space:]]+/, " ", cleaned)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cleaned)
      if (!seen[cleaned]++) {
        print original
      }
    }
  ' "$queue_file" >"$temp_file"
  mv "$temp_file" "$queue_file"

  after_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$queue_file")"
  if [ "$after_count" -lt "$before_count" ]; then
    log_msg WARN queue "Removed $((before_count - after_count)) duplicate task(s) from $(basename "$queue_file")"
  fi
}

task_exists_anywhere() {
  local project_name="${1:-}"
  local task_norm="$2"
  local file registry_file
  registry_file="$(task_registry_file_for_project "$project_name")"

  reconcile_running_registry_tasks_before_planning >/dev/null 2>&1 || true

  shopt -s nullglob
  for file in "$QUEUE_DIR"/*.txt; do
    if [ -n "$project_name" ] && [ "$(basename "$file" .txt)" != "$project_name" ]; then
      continue
    fi
    while IFS= read -r line; do
      [ -n "$(trim_text "$line")" ] || continue
      if [ "$(normalize_task "$line")" = "$task_norm" ]; then
        shopt -u nullglob
        return 0
      fi
    done <"$file"
  done
  shopt -u nullglob

  if [ -f "$STATUS_FILE" ]; then
    local current_project current_task
    current_project="$(awk -F= '$1=="project" { print $2 }' "$STATUS_FILE" 2>/dev/null || true)"
    current_task="$(awk -F= '$1=="task" { print $2 }' "$STATUS_FILE" 2>/dev/null || true)"
    if [ -n "$current_task" ] && [ "$(normalize_task "$current_task")" = "$task_norm" ]; then
      if [ -z "$project_name" ] || [ "$current_project" = "$project_name" ]; then
        return 0
      fi
    fi
  fi

  if [ -f "$registry_file" ]; then
    if python3 - "$registry_file" "$project_name" "$task_norm" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


path, project_name, task_norm = sys.argv[1:]


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(1)

tasks = payload.get("tasks") if isinstance(payload, dict) else []
if not isinstance(tasks, list):
    raise SystemExit(1)

project_filter = normalize_project(project_name)
for task in tasks:
    if not isinstance(task, dict):
        continue
    status = str(task.get("status") or "").strip().lower()
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_state = str(execution.get("state") or "").strip().lower()
    if status not in {"approved", "running"} and execution_state not in {"running", "retrying"}:
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if project_filter and task_project != project_filter:
        continue
    if normalize_task(task_execution_text(task)) == task_norm:
        raise SystemExit(0)

raise SystemExit(1)
PY
    then
      shopt -u nullglob
      return 0
    fi
  fi
  return 1
}

enforce_queue_safety() {
  local project_name="$1"
  local task="$2"
  local task_norm total
  task_norm="$(normalize_task "$task")"
  total="$(queue_task_count)"

  if [ "$total" -ge "$QUEUE_LIMIT" ]; then
    printf 'QUEUE_LIMIT_EXCEEDED\n'
    return 1
  fi
  if task_exists_anywhere "$project_name" "$task_norm"; then
    printf 'DUPLICATE_TASK\n'
    return 1
  fi
  return 0
}

resolve_task_timeout_seconds() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local base_timeout="${3:-$TASK_TIMEOUT_SECONDS}"
  local registry_file

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$base_timeout" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any

path, project_name, queue_task, base_timeout = sys.argv[1:]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_task(value: Any) -> str:
    return normalize_text(value).lower()


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def clamp_timeout(value: Any, fallback: int = 300) -> int:
    candidate = normalize_text(value)
    if not re.fullmatch(r"[0-9]+", candidate):
        candidate = str(fallback)
    try:
        resolved = int(candidate)
    except ValueError:
        resolved = fallback
    return max(60, min(1200, resolved))


def read_tasks(file_path: str) -> list[dict[str, Any]]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return tasks if isinstance(tasks, list) else []


project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
status_rank = {"running": 5, "approved": 4, "pending_approval": 3, "completed": 2, "failed": 1}
selected: dict[str, Any] | None = None
selected_rank: tuple[int, str, str, int] | None = None

for index, task in enumerate(read_tasks(path)):
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        status_rank.get(str(task.get("status") or "").strip().lower(), 0),
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected = task

timeout_seconds = clamp_timeout(base_timeout)
if not isinstance(selected, dict):
    print(timeout_seconds)
    raise SystemExit(0)

effort = int(selected.get("effort") or 0)
category = normalize_text(selected.get("category")).lower()
task_intent = selected.get("task_intent") if isinstance(selected.get("task_intent"), dict) else {}
provider_selection = selected.get("provider_selection") if isinstance(selected.get("provider_selection"), dict) else {}
source = normalize_text(provider_selection.get("source") or task_intent.get("source")).lower()

# Iteration 8 fix: high-effort tasks have highest timeout rates (85%+).
# Escalating their budget from 420→600-900 just wastes more worker time.
# Cap at 480s for effort>=3 (enough for 3 steps + verification at 120s each).
# Only manual_assessment tasks with effort>=3 get 540s (curated, higher signal).
if effort >= 4:
    timeout_seconds = max(timeout_seconds, 480)
elif effort >= 3:
    timeout_seconds = max(timeout_seconds, 480)
elif effort >= 2 and category in {"ui", "learning", "project"}:
    timeout_seconds = max(timeout_seconds, 420)

if source == "manual_assessment" and effort >= 3:
    timeout_seconds = max(timeout_seconds, 540)

print(clamp_timeout(timeout_seconds))
PY
}

resolve_task_step_bounds() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local default_min="${3:-2}"
  local default_max="${4:-6}"
  local registry_file

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$default_min" "$default_max" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any

path, project_name, queue_task, default_min, default_max = sys.argv[1:]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_task(value: Any) -> str:
    return normalize_text(value).lower()


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def clamp_step_count(value: Any, fallback: int, minimum: int = 1, maximum: int = 6) -> int:
    candidate = normalize_text(value)
    if not re.fullmatch(r"[0-9]+", candidate):
        candidate = str(fallback)
    try:
        resolved = int(candidate)
    except ValueError:
        resolved = fallback
    return max(minimum, min(maximum, resolved))


def read_tasks(file_path: str) -> list[dict[str, Any]]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return tasks if isinstance(tasks, list) else []


project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
status_rank = {"running": 5, "approved": 4, "pending_approval": 3, "completed": 2, "failed": 1}
selected: dict[str, Any] | None = None
selected_rank: tuple[int, str, str, int] | None = None

for index, task in enumerate(read_tasks(path)):
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        status_rank.get(str(task.get("status") or "").strip().lower(), 0),
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected = task

min_steps = clamp_step_count(default_min, 2)
max_steps = clamp_step_count(default_max, 6)
if min_steps > max_steps:
    min_steps = max_steps

if isinstance(selected, dict):
    effort = int(selected.get("effort") or 0)
    category = normalize_text(selected.get("category")).lower()
    task_intent = selected.get("task_intent") if isinstance(selected.get("task_intent"), dict) else {}
    provider_selection = selected.get("provider_selection") if isinstance(selected.get("provider_selection"), dict) else {}
    source = normalize_text(provider_selection.get("source") or task_intent.get("source")).lower()

    if effort <= 2:
        min_steps = 2
        max_steps = min(max_steps, 3)
    elif effort == 3:
        min_steps = max(min_steps, 2)
        max_steps = min(max_steps, 4)
    elif effort >= 4:
        max_steps = min(max_steps, 5)

    if category in {"ui", "learning"} and effort <= 2:
        max_steps = min(max_steps, 3)
    if source == "manual_assessment" and effort >= 3:
        max_steps = min(max_steps, 4)

if min_steps > max_steps:
    min_steps = max_steps

print(min_steps)
print(max_steps)
PY
}

next_task_from_queue() {
  local queue_file="$1"
  local registry_file

  if command -v emit_active_worker_leases >/dev/null 2>&1; then
    emit_active_worker_leases | reconcile_running_registry_tasks_to_active_leases >/dev/null 2>&1 || true
  fi

  registry_file="$(task_registry_file_for_project "$(basename "$queue_file" .txt)")"

  python3 - "$queue_file" "$registry_file" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

queue_file = Path(sys.argv[1])
registry_file = Path(sys.argv[2])
project_name = queue_file.stem


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def read_registry() -> list[dict[str, Any]]:
    try:
        payload = json.loads(registry_file.read_text(encoding="utf-8"))
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return tasks if isinstance(tasks, list) else []


try:
    queue_lines = [line.strip() for line in queue_file.read_text(encoding="utf-8").splitlines() if line.strip()]
except Exception:
    queue_lines = []

if not queue_lines:
    raise SystemExit(0)

registry = read_registry()
registry_by_task: dict[str, dict[str, Any]] = {}
running_heavy_manual_tasks = 0
for task in registry:
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != normalize_project(project_name):
        continue
    registry_by_task[normalize_task(task_execution_text(task))] = task
    if str(task.get("status") or "").strip().lower() != "running":
        continue
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    source = str(provider_selection.get("source") or task_intent.get("source") or "").strip().lower()
    effort_value = int(task.get("effort") or 99)
    if source == "manual_assessment" and effort_value >= 3:
        running_heavy_manual_tasks += 1


def source_rank(task: dict[str, Any] | None) -> int:
    if not isinstance(task, dict):
        return 4
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    source = str(task_intent.get("source") or "").strip().lower()
    if source in {"manual_board_task", "dashboard_backlog"}:
        return 0
    if source in {"strategy_seed", "strategy_followup", "strategy_loop"}:
        return 1
    if source in {"recovered_registry", "recovered_task_log"}:
        return 2
    if source == "dashboard_prompt_intake":
        return 3
    return 2


def breadth_penalty(task: dict[str, Any] | None, line: str) -> int:
    text = normalize_task(line)
    if isinstance(task, dict):
        text = normalize_task(
            " ".join(
                str(value or "")
                for value in (
                    task.get("title"),
                    task.get("reason"),
                    (task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else "",
                )
            )
        )

    broad_markers = (
        "analyze",
        "analyse",
        "identify",
        "generate",
        "prioritize",
        "vergleich",
        "vergleiche",
        "leite davon ein design ab",
        "compare with",
        "research",
    )
    if any(marker in text for marker in broad_markers):
        return 1
    if "http://" in text or "https://" in text:
        return 1
    if len(text) > 120:
        return 1
    return 0


def retry_penalty(task: dict[str, Any] | None) -> int:
    if not isinstance(task, dict):
        return 0
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    state = str(execution.get("state") or "").strip().lower()
    attempt = int(execution.get("attempt") or 0)
    if state == "retrying" or attempt > 0:
        return 1
    return 0


def heavy_manual_penalty(task: dict[str, Any] | None) -> int:
    if not isinstance(task, dict):
        return 0
    if running_heavy_manual_tasks <= 0:
        return 0
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    source = str(provider_selection.get("source") or task_intent.get("source") or "").strip().lower()
    effort_value = int(task.get("effort") or 99)
    status = str(task.get("status") or "").strip().lower()
    if status != "running" and source == "manual_assessment" and effort_value >= 3:
        return 1
    return 0


def sort_key(index: int, line: str) -> tuple[Any, ...]:
    task = registry_by_task.get(normalize_task(line))
    if not isinstance(task, dict):
        return (5, 1, 0, 99, 99, 999.0, -1.0, index)
    impact = int(task.get("impact") or 0)
    effort = int(task.get("effort") or 99)
    score = float(task.get("score") or 0.0)
    confidence = float(task.get("confidence") or 0.0)
    return (
        source_rank(task),
        breadth_penalty(task, line),
        heavy_manual_penalty(task),
        retry_penalty(task),
        -impact,
        effort,
        -score,
        -confidence,
        index,
    )


best_index, best_line = min(enumerate(queue_lines), key=lambda item: sort_key(item[0], item[1]))
print(best_line)
PY
}

reconcile_running_registry_tasks_before_planning() {
  ensure_runtime_dirs

  if command -v emit_active_worker_leases >/dev/null 2>&1; then
    emit_active_worker_leases | reconcile_running_registry_tasks_to_active_leases >/dev/null 2>&1 || true
    return 0
  fi

  python3 - "$STATUS_FILE" "$TASK_REGISTRY_FILE" <<'PY' | reconcile_running_registry_tasks_to_active_leases >/dev/null 2>&1 || true
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

status_path = Path(sys.argv[1])
registry_path = Path(sys.argv[2])


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


status_fields: dict[str, str] = {}
try:
    for raw_line in status_path.read_text(encoding="utf-8").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        status_fields[str(key).strip()] = str(value).strip()
except Exception:
    status_fields = {}

status_state = str(status_fields.get("state") or "").strip().lower()
status_project = normalize_project(status_fields.get("project") or "")
status_task_key = normalize_task(status_fields.get("task") or "")

if status_state not in {"running", "retrying"} or not status_project or not status_task_key:
    raise SystemExit(0)

try:
    payload = json.loads(registry_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

tasks = payload.get("tasks") if isinstance(payload, dict) else []
if not isinstance(tasks, list):
    raise SystemExit(0)

for task in tasks:
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != status_project:
        continue
    if normalize_task(task_execution_text(task)) != status_task_key:
        continue
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    lease_id = str(execution.get("lease_id") or "").strip()
    lane = str(execution.get("lane") or "").strip()
    if not lease_id:
        continue
    print(f"{lane}\t{lease_id}\t{status_project}\t{task_execution_text(task)}")
    break
PY
}

remove_first_task_from_queue() {
  local queue_file="$1"
  local target_task="${2:-}"
  local temp_file
  temp_file="$(mktemp)"
  if [ -n "$target_task" ]; then
    python3 - "$queue_file" "$temp_file" "$target_task" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

queue_file = Path(sys.argv[1])
temp_file = Path(sys.argv[2])
target_task = sys.argv[3]


def normalize_task(value: str) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


removed = False
target_key = normalize_task(target_task)
kept: list[str] = []
for line in queue_file.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if not removed and stripped and normalize_task(stripped) == target_key:
        removed = True
        continue
    kept.append(line)

temp_file.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
PY
  else
    awk '
      BEGIN { removed=0 }
      {
        if (!removed && NF) {
          removed=1
          next
        }
        print
      }
    ' "$queue_file" >"$temp_file"
  fi
  mv "$temp_file" "$queue_file"
}

reconcile_approved_registry_tasks_to_queue() {
  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$QUEUE_DIR" "$STATUS_FILE" "$METRICS_FILE" "$(project_policy_file "codex-agent-system")" "${MAX_AGENT_RETRIES:-2}" "$PROJECTS_DIR" "$TASK_LOG" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

registry_path = Path(sys.argv[1])
queue_dir = Path(sys.argv[2])
status_path = Path(sys.argv[3])
metrics_path = Path(sys.argv[4])
policy_path = Path(sys.argv[5])
default_max_retries = max(1, int(sys.argv[6] or "2"))
projects_dir = Path(sys.argv[7]) if len(sys.argv) > 7 else None
task_log_path = Path(sys.argv[8]) if len(sys.argv) > 8 and str(sys.argv[8]).strip() else registry_path.with_name("tasks.log")

BUFFER_TASK_TITLE = "Keep an executable system-work buffer when the queue drains under low completion rate"
BUFFER_TASK_TITLE_PREFIX = BUFFER_TASK_TITLE[:80]
BUFFER_TASK_SOURCE_ID = "strategy::queue-drain-completion"
BUFFER_TASK_SOURCE_TITLE = "Queue drain completion anomaly"
BUFFER_TASK_CATEGORY = "stability"
BUFFER_TASK_IMPACT = 8
BUFFER_TASK_EFFORT = 2
BUFFER_TASK_CONFIDENCE = 0.85
BUFFER_TASK_SCORE = 6.12
ENTERPRISE_ACTIONABLE_TARGET = 3
RECENT_COMPLETION_RATE_THRESHOLD = 0.25
BUFFER_TASK_RESOLUTION_COOLDOWN_SECONDS = 1800
DEFAULT_PROVIDER = "codex"
STRATEGY_SATURATED_FAILURE_THRESHOLD = 2
ZOMBIE_FAILURE_THRESHOLD = 5


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def read_registry() -> list[dict[str, Any]]:
    all_tasks: list[dict[str, Any]] = []
    local_task_count: int = 0
    seen_paths: set[str] = set()
    # Read central registry
    try:
        resolved = str(registry_path.resolve())
        seen_paths.add(resolved)
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
        tasks = payload.get("tasks") if isinstance(payload, dict) else []
        if isinstance(tasks, list):
            all_tasks.extend(tasks)
            local_task_count = len(tasks)
    except Exception:
        pass
    # Read project-specific registries (e.g. superheld/.codex-agent/tasks.json)
    # Iteration 11 fix: tag cross-project tasks with _source_project so that
    # queue rehydration places them into the correct project queue instead of
    # defaulting to "codex-agent-system".
    # Iteration 12 fix: mark cross-project tasks with _cross_project=True so that
    # write_registry can exclude them. Previously, write_registry(tasks) wrote ALL
    # tasks (local + cross-project) back to the local registry, causing infinite
    # growth (~600 tasks/minute, 142MB+ registry file).
    if projects_dir and projects_dir.is_dir():
        for project_dir in projects_dir.iterdir():
            if not project_dir.is_dir():
                continue
            project_json = project_dir / "project.json"
            if not project_json.exists():
                continue
            try:
                meta = json.loads(project_json.read_text(encoding="utf-8"))
                source_project = str(meta.get("project") or meta.get("project_id") or project_dir.name).strip()
                extra_registry = str(meta.get("task_registry_file") or "").strip()
                if not extra_registry:
                    continue
                extra_path = Path(extra_registry)
                resolved_extra = str(extra_path.resolve())
                if resolved_extra in seen_paths or not extra_path.exists():
                    continue
                seen_paths.add(resolved_extra)
                extra_payload = json.loads(extra_path.read_text(encoding="utf-8"))
                extra_tasks = extra_payload.get("tasks") if isinstance(extra_payload, dict) else []
                if isinstance(extra_tasks, list):
                    for t in extra_tasks:
                        if isinstance(t, dict):
                            if source_project:
                                t.setdefault("_source_project", source_project)
                            t["_cross_project"] = True
                    all_tasks.extend(extra_tasks)
            except Exception:
                continue
    return all_tasks


def read_queue_entries() -> set[tuple[str, str]]:
    entries: set[tuple[str, str]] = set()
    if not queue_dir.exists():
        return entries
    for queue_file in queue_dir.glob("*.txt"):
        project = normalize_project(queue_file.stem)
        try:
            lines = queue_file.read_text(encoding="utf-8").splitlines()
        except Exception:
            continue
        for line in lines:
            task = normalize_task(line)
            if task:
                entries.add((project, task))
    return entries


def read_running_status() -> tuple[str, str]:
    if not status_path.exists():
        return ("", "")
    values: dict[str, str] = {}
    for line in status_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    state = str(values.get("state") or "").strip().lower()
    if state not in {"running", "retrying", "queued"}:
        return ("", "")
    return (normalize_project(values.get("project") or ""), normalize_task(values.get("task") or ""))


def read_metrics() -> dict[str, Any]:
    try:
        payload = json.loads(metrics_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def read_policy() -> dict[str, Any]:
    try:
        payload = json.loads(policy_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def read_task_log_failure_counts() -> dict[tuple[str, str], int]:
    counts: dict[tuple[str, str], int] = {}
    if not task_log_path.exists():
        return counts
    try:
        lines = task_log_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return counts

    for raw_line in lines:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            record = json.loads(raw_line)
        except Exception:
            continue
        if not isinstance(record, dict):
            continue
        if normalize_task(record.get("result")) != "failure":
            continue
        project_key = normalize_project(record.get("project") or "codex-agent-system")
        task_key = normalize_task(record.get("task"))[:80]
        if not task_key:
            continue
        counts[(project_key, task_key)] = counts.get((project_key, task_key), 0) + 1

    return counts


def write_registry(tasks: list[dict[str, Any]]) -> None:
    # Iteration 12 fix: ONLY write local tasks back to the local registry.
    # Cross-project tasks (tagged with _cross_project=True by read_registry)
    # must NOT be written to the local registry — doing so caused infinite
    # growth: each reconcile cycle re-injected all superheld tasks (~1500+)
    # into the local file, growing it by ~600 tasks/minute to 142MB+.
    local_tasks = [t for t in tasks if not (isinstance(t, dict) and t.get("_cross_project"))]
    # Clean up internal marker from local tasks before persisting
    for t in local_tasks:
        if isinstance(t, dict):
            t.pop("_cross_project", None)
    payload = {"tasks": local_tasks}
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=registry_path.parent, encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, registry_path)


def next_task_registry_id(tasks: list[dict[str, Any]], title: str) -> str:
    max_number = 0
    for task in tasks:
        if not isinstance(task, dict):
            continue
        match = re.match(r"^task-(\d+)-", str(task.get("id") or "").strip())
        if match:
            max_number = max(max_number, int(match.group(1)))
    slug = re.sub(r"[^a-z0-9]+", "-", title.strip().lower()).strip("-")[:40] or "task"
    return f"task-{max_number + 1:03d}-{slug}"


def build_buffer_task(tasks: list[dict[str, Any]], project: str) -> dict[str, Any]:
    transition_at = now_utc()
    return {
        "id": next_task_registry_id(tasks, BUFFER_TASK_TITLE),
        "title": BUFFER_TASK_TITLE,
        "impact": BUFFER_TASK_IMPACT,
        "effort": BUFFER_TASK_EFFORT,
        "confidence": BUFFER_TASK_CONFIDENCE,
        "category": BUFFER_TASK_CATEGORY,
        "project": project,
        "reason": "A self-improving system should not sit idle when completion remains weak. If executable work drains while outcomes stay poor, strategy must seed bounded corrective work immediately.",
        "score": BUFFER_TASK_SCORE,
        "execution_provider": DEFAULT_PROVIDER,
        "provider_selection": {
            "selected": DEFAULT_PROVIDER,
            "source": "default",
            "reason": "Default provider is Codex when no explicit Claude hint is present.",
            "updated_at": transition_at,
        },
        "status": "approved",
        "task_intent": {
            "source": "strategy_anomaly",
            "objective": BUFFER_TASK_TITLE,
            "project": project,
            "category": BUFFER_TASK_CATEGORY,
            "context_hint": "Queue drain completion anomaly",
        },
        "source_task_id": BUFFER_TASK_SOURCE_ID,
        "root_source_task_id": BUFFER_TASK_SOURCE_ID,
        "original_failed_root_id": BUFFER_TASK_SOURCE_ID,
        "related_source_task_ids": [BUFFER_TASK_SOURCE_ID],
        "strategy_template": "queue_drain_completion_guard",
        "strategy_depth": 0,
        "created_at": transition_at,
        "updated_at": transition_at,
        "approved_at": transition_at,
        "queue_handoff": {
            "status": "queued",
            "project": project,
            "task": BUFFER_TASK_TITLE,
            "approved_at": transition_at,
        },
        "execution": {
            "state": "approved",
            "attempt": 0,
            "max_retries": min(default_max_retries, 2),
            "provider": DEFAULT_PROVIDER,
            "result": "FAILURE",
            "updated_at": transition_at,
            "will_retry": True,
        },
        "history": [
            {
                "at": transition_at,
                "action": "create",
                "from_status": "",
                "to_status": "approved",
                "project": project,
                "queue_task": BUFFER_TASK_TITLE,
                "note": "Task was auto-approved from deterministic runtime anomaly analysis and enqueued immediately.",
            }
        ],
    }


def buffer_task_event_timestamp(task: dict[str, Any]) -> str:
    for key in ("completed_at", "failed_at", "updated_at", "created_at"):
        value = str(task.get(key) or "").strip()
        if value:
            return value
    return ""


def buffer_task_matches_equivalent(task: dict[str, Any], project: str) -> bool:
    buffer_task_key = normalize_task(BUFFER_TASK_TITLE)
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project:
        return False
    source_task_id = str(task.get("source_task_id") or "").strip()
    root_source_task_id = str(task.get("root_source_task_id") or "").strip()
    original_failed_root_id = str(task.get("original_failed_root_id") or "").strip()
    strategy_template = str(task.get("strategy_template") or "").strip()
    return (
        strategy_template == "queue_drain_completion_guard"
        or source_task_id == BUFFER_TASK_SOURCE_ID
        or root_source_task_id == BUFFER_TASK_SOURCE_ID
        or original_failed_root_id == BUFFER_TASK_SOURCE_ID
        or normalize_task(task_execution_text(task)) == buffer_task_key
    )


def buffer_task_failed_equivalent_count(tasks: list[dict[str, Any]], project: str) -> int:
    equivalent_tasks = [
        task for task in tasks if isinstance(task, dict) and buffer_task_matches_equivalent(task, project)
    ]
    latest_success_at = max(
        (
            buffer_task_event_timestamp(task)
            for task in equivalent_tasks
            if str(task.get("status") or "").strip().lower() == "completed"
        ),
        default="",
    )
    failed_count = 0
    for task in equivalent_tasks:
        if str(task.get("status") or "").strip().lower() != "failed":
            continue
        failed_at = buffer_task_event_timestamp(task)
        if latest_success_at and failed_at and failed_at <= latest_success_at:
            continue
        failed_count += 1
    return failed_count


def buffer_task_latest_success_at(tasks: list[dict[str, Any]], project: str) -> str:
    return max(
        (
            buffer_task_event_timestamp(task)
            for task in tasks
            if isinstance(task, dict)
            and buffer_task_matches_equivalent(task, project)
            and str(task.get("status") or "").strip().lower() == "completed"
        ),
        default="",
    )


def buffer_task_is_zombie_shelved(task: dict[str, Any]) -> bool:
    if str(task.get("status") or "").strip().lower() != "shelved":
        return False

    history = task.get("history") if isinstance(task.get("history"), list) else []
    for entry in reversed(history):
        if not isinstance(entry, dict):
            continue
        if str(entry.get("to_status") or "").strip().lower() != "shelved":
            continue
        if str(entry.get("action") or "").strip().lower() == "zombie_guard":
            return True
        note = normalize_task(entry.get("note"))
        if "zombie guard" in note or "prior failures exceed threshold" in note:
            return True

    return "zombie guard" in normalize_task(task.get("shelved_reason"))


def buffer_task_failed_or_blocked_equivalent_count(tasks: list[dict[str, Any]], project: str) -> int:
    equivalent_tasks = [
        task for task in tasks if isinstance(task, dict) and buffer_task_matches_equivalent(task, project)
    ]
    latest_success_at = buffer_task_latest_success_at(tasks, project)
    failure_count = 0
    for task in equivalent_tasks:
        status = str(task.get("status") or "").strip().lower()
        if status != "failed" and not buffer_task_is_zombie_shelved(task):
            continue
        failed_at = buffer_task_event_timestamp(task)
        if latest_success_at and failed_at and failed_at <= latest_success_at:
            continue
        failure_count += 1
    return failure_count


def buffer_task_recent_resolved_equivalent(tasks: list[dict[str, Any]], project: str) -> dict[str, Any] | None:
    latest_task: dict[str, Any] | None = None
    latest_resolved_at: datetime | None = None

    for task in tasks:
        if not isinstance(task, dict) or not buffer_task_matches_equivalent(task, project):
            continue
        if str(task.get("status") or "").strip().lower() not in {"completed", "rejected"}:
            continue
        resolved_at = parse_timestamp(buffer_task_event_timestamp(task))
        if resolved_at is None:
            continue
        if latest_resolved_at is None or resolved_at > latest_resolved_at:
            latest_resolved_at = resolved_at
            latest_task = task

    if latest_task is None or latest_resolved_at is None:
        return None

    age_seconds = max((datetime.now(timezone.utc) - latest_resolved_at).total_seconds(), 0)
    if age_seconds >= BUFFER_TASK_RESOLUTION_COOLDOWN_SECONDS:
        return None
    return latest_task


def task_blocks_duplicate(task: dict[str, Any], project: str, task_key: str) -> bool:
    status = str(task.get("status") or "").strip().lower()
    if status not in {"pending_approval", "approved", "running"}:
        return False
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project:
        return False
    if normalize_task(task_execution_text(task)) == task_key:
        return True
    source_task_id = str(task.get("source_task_id") or "").strip()
    root_source_task_id = str(task.get("root_source_task_id") or "").strip()
    original_failed_root_id = str(task.get("original_failed_root_id") or "").strip()
    strategy_template = str(task.get("strategy_template") or "").strip()
    return (
        strategy_template == "queue_drain_completion_guard"
        and (
            source_task_id == BUFFER_TASK_SOURCE_ID
            or root_source_task_id == BUFFER_TASK_SOURCE_ID
            or original_failed_root_id == BUFFER_TASK_SOURCE_ID
        )
    )


def project_has_approved_or_running_work(
    tasks: list[dict[str, Any]],
    project: str,
) -> bool:
    for task in tasks:
        if not isinstance(task, dict):
            continue
        if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project:
            continue
        status = str(task.get("status") or "").strip().lower()
        execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
        execution_state = str(execution.get("state") or "").strip().lower()
        if status in {"approved", "running"} or execution_state in {"running", "retrying"}:
            return True
    return False


def project_has_live_queue_work(
    queue_entries: set[tuple[str, str]],
    running_entry: tuple[str, str],
    project: str,
) -> bool:
    if any(entry_project == project for entry_project, _ in queue_entries):
        return True
    running_project, running_task = running_entry
    return running_project == project and bool(running_task)


def failed_task_matches_title_prefix(task: dict[str, Any], project: str, title_prefix: str) -> bool:
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project:
        return False
    if str(task.get("status") or "").strip().lower() != "failed":
        return False
    return task_execution_text(task)[:80] == title_prefix


def zombie_shelved_task_matches_title_prefix(task: dict[str, Any], project: str, title_prefix: str) -> bool:
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project:
        return False
    if not buffer_task_is_zombie_shelved(task):
        return False
    return task_execution_text(task)[:80] == title_prefix


def task_failure_survives_latest_success(task: dict[str, Any], latest_success_at: str) -> bool:
    failed_at = buffer_task_event_timestamp(task)
    if latest_success_at and failed_at and failed_at <= latest_success_at:
        return False
    return True


def stale_pipeline_auto_approvable(task: dict[str, Any]) -> bool:
    intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    intent_source = normalize_task(intent.get("source"))
    if intent_source == "self-improve":
        return True

    strategy_template = normalize_task(task.get("strategy_template"))
    if strategy_template in {"self_improvement", "bounded_learning_inventory"}:
        return True

    for key in ("source_task_id", "root_source_task_id", "original_failed_root_id"):
        if normalize_task(task.get(key)) == "self-improve":
            return True

    return False


def stale_pipeline_auto_approve_threshold_seconds(task: dict[str, Any], stale_duration_seconds: float) -> int:
    threshold = (
        DEEP_STALE_AUTO_APPROVE_SECONDS
        if stale_duration_seconds > DEEP_STALE_THRESHOLD_SECONDS
        else STALE_PENDING_AUTO_APPROVE_THRESHOLD_SECONDS
    )

    strategy_template = normalize_task(task.get("strategy_template"))
    title = normalize_task(task.get("title") or task_execution_text(task))
    if (
        stale_duration_seconds > DEEP_STALE_THRESHOLD_SECONDS
        and (
            strategy_template == "bounded_learning_inventory"
            or title.startswith("inventory current decision path")
        )
    ):
        return min(threshold, DEEP_STALE_INVENTORY_AUTO_APPROVE_SECONDS)

    return threshold


def stale_pipeline_auto_approve_block_reason(
    task: dict[str, Any],
    task_log_failure_counts: dict[tuple[str, str], int],
) -> str:
    project_key = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    task_key = normalize_task(task_execution_text(task))[:80]
    if not task_key:
        return ""
    failure_count = task_log_failure_counts.get((project_key, task_key), 0)
    if failure_count >= ZOMBIE_FAILURE_THRESHOLD:
        return f"zombie_failure_threshold:{failure_count}"
    return ""


tasks = read_registry()
queue_entries = read_queue_entries()
running_entry = read_running_status()
metrics = read_metrics()
policy = read_policy()
task_log_failure_counts = read_task_log_failure_counts()
changed = False
requeued: list[tuple[str, str]] = []

# Iteration 11 fix: read stale-task blocklist to prevent infinite rehydration
# of tasks that can never be leased (e.g. cross-project tasks in wrong queue).
stale_blocklist: set[tuple[str, str]] = set()
_blocklist_path = registry_path.parent.parent / "codex-logs" / "queue-stale-blocklist.txt"
if _blocklist_path.exists():
    try:
        for _line in _blocklist_path.read_text(encoding="utf-8").splitlines():
            _parts = _line.split("\t", 1)
            if len(_parts) == 2 and _parts[0].strip() and _parts[1].strip():
                stale_blocklist.add((normalize_project(_parts[0]), normalize_task(_parts[1])))
    except Exception:
        pass

current_runnable_count = len(queue_entries) + (1 if running_entry[0] and running_entry[1] else 0)
persisted_success_rate = metrics.get("success_rate", 0)
try:
    persisted_success_rate = float(persisted_success_rate)
except (TypeError, ValueError):
    persisted_success_rate = 0.0

buffer_project = normalize_project("codex-agent-system")
buffer_task_key = normalize_task(BUFFER_TASK_TITLE)
buffer_duplicate = any(task_blocks_duplicate(task, buffer_project, buffer_task_key) for task in tasks if isinstance(task, dict))
buffer_latest_success_at = buffer_task_latest_success_at(tasks, buffer_project)
buffer_failed_equivalent_count = buffer_task_failed_or_blocked_equivalent_count(tasks, buffer_project)
buffer_recent_resolved_equivalent = buffer_task_recent_resolved_equivalent(tasks, buffer_project)
buffer_failed_title_prefix_exists = any(
    (
        failed_task_matches_title_prefix(task, buffer_project, BUFFER_TASK_TITLE_PREFIX)
        or zombie_shelved_task_matches_title_prefix(task, buffer_project, BUFFER_TASK_TITLE_PREFIX)
    )
    and task_failure_survives_latest_success(task, buffer_latest_success_at)
    for task in tasks
    if isinstance(task, dict)
)
project_queue_drained = (
    not project_has_approved_or_running_work(tasks, buffer_project)
    and not project_has_live_queue_work(queue_entries, running_entry, buffer_project)
)
policy_allows_automatic_queue_seeding = policy.get("auto_approve_allowed") is not False
low_completion_drain_detected = metrics.get("low_completion_drain_detected") is True
legacy_low_completion_window = current_runnable_count < ENTERPRISE_ACTIONABLE_TARGET and persisted_success_rate <= RECENT_COMPLETION_RATE_THRESHOLD
# Iteration 12 fix: also check for shelved equivalents to prevent infinite
# create-shelve cycle. Previously, buffer_duplicate only checked pending_approval/
# approved/running status, so shelved buffer tasks didn't block creation of new
# ones, causing ~1 buffer task per 2 seconds that immediately got shelved.
pipeline_stale = metrics.get("pipeline_stale") is True

# ──────────────────────────────────────────────────────────────────────────────
# Iteration 13 fix: AUTO-APPROVE PENDING TASKS DURING PIPELINE STALL
# Problem 44: Self-improve generates tasks → pending_approval → strategy blocks
# new tasks while pending ones exist → no human to approve → permanent deadlock.
# Fix: When pipeline_stale=true and pending tasks have been pending for >3 hours,
# auto-approve the highest-scored self-improve task (max 1 per reconcile cycle
# to stay safe). Human-created backlog must remain pending for explicit review.
# Only fires when policy allows auto-approve AND no approved/running work exists.
# ──────────────────────────────────────────────────────────────────────────────
STALE_PENDING_AUTO_APPROVE_THRESHOLD_SECONDS = 3 * 3600  # 3 hours (normal)
# Iteration 14 fix: when pipeline has been stale for >12 hours, the 3-hour threshold
# is too conservative — the system is deeply stuck and needs faster recovery.
# Reduce to 1 hour in deep-stale mode. The pipeline_stale_since field tells us
# how long the pipeline has been idle.
DEEP_STALE_THRESHOLD_SECONDS = 12 * 3600  # 12 hours
DEEP_STALE_AUTO_APPROVE_SECONDS = 5 * 60  # 5 minutes
DEEP_STALE_INVENTORY_AUTO_APPROVE_SECONDS = 60  # 1 minute for bounded inventories only

_stale_since = parse_timestamp(metrics.get("pipeline_stale_since"))
_stale_duration_seconds = max((datetime.now(timezone.utc) - _stale_since).total_seconds(), 0) if _stale_since else 0

_has_active_work = project_has_approved_or_running_work(tasks, buffer_project)
# Iteration 16 fix: diagnostic logging for auto-approval. Previously there was
# no way to know if auto-approval was reached, skipped, or failed.
import sys as _sys
if pipeline_stale and policy_allows_automatic_queue_seeding and not _has_active_work:
    print(f"[auto-approve] Conditions met: pipeline_stale={pipeline_stale}, policy_allows={policy_allows_automatic_queue_seeding}, no_active_work={not _has_active_work}", file=_sys.stderr)
    stale_pending_candidates: list[tuple[float, int, dict[str, Any]]] = []
    for idx, task in enumerate(tasks):
        if not isinstance(task, dict):
            continue
        if str(task.get("status") or "").strip().lower() != "pending_approval":
            continue
        if normalize_project(task.get("project") or "codex-agent-system") != buffer_project:
            continue
        if not stale_pipeline_auto_approvable(task):
            continue
        block_reason = stale_pipeline_auto_approve_block_reason(task, task_log_failure_counts)
        if block_reason:
            print(
                f"[auto-approve] Skipping blocked candidate: {task_execution_text(task)} ({block_reason})",
                file=_sys.stderr,
            )
            continue
        created_at = parse_timestamp(task.get("created_at"))
        if created_at is None:
            continue
        age_seconds = max((datetime.now(timezone.utc) - created_at).total_seconds(), 0)
        auto_approve_threshold = stale_pipeline_auto_approve_threshold_seconds(task, _stale_duration_seconds)
        if age_seconds < auto_approve_threshold:
            continue
        score = 0.0
        try:
            score = float(task.get("score") or 0)
        except (TypeError, ValueError):
            pass
        stale_pending_candidates.append((score, idx, task, age_seconds, auto_approve_threshold))

    if stale_pending_candidates:
        # Pick highest-scored candidate
        stale_pending_candidates.sort(key=lambda x: (-x[0], x[1]))
        _, best_idx, best_task, best_age_seconds, best_threshold = stale_pending_candidates[0]
        print(f"[auto-approve] Approving: {best_task.get('title')} (score={best_task.get('score')}, age={int(best_age_seconds)}s, threshold={int(best_threshold)}s)", file=_sys.stderr)
        transition_at = now_utc()
        best_task["status"] = "approved"
        best_task["updated_at"] = transition_at
        best_task["approved_at"] = transition_at
        if isinstance(best_task.get("execution"), dict):
            best_task["execution"]["state"] = "approved"
            best_task["execution"]["updated_at"] = transition_at
        history = best_task.get("history") if isinstance(best_task.get("history"), list) else []
        history.append({
            "at": transition_at,
            "action": "auto_approve_stale_pipeline",
            "from_status": "pending_approval",
            "to_status": "approved",
            "project": buffer_project,
            "queue_task": task_execution_text(best_task),
            "note": f"Auto-approved self-improve task (threshold: {int(best_threshold)}s, stale_duration: {int(_stale_duration_seconds)}s). Task was pending for {int(best_age_seconds)}s. Score: {best_task.get('score')}.",
        })
        best_task["history"] = history
        changed = True

buffer_shelved_equivalent_count = sum(
    1 for task in tasks
    if isinstance(task, dict)
    and buffer_task_matches_equivalent(task, buffer_project)
    and str(task.get("status") or "").strip().lower() == "shelved"
)

if (
    policy_allows_automatic_queue_seeding
    and not buffer_duplicate
    and buffer_recent_resolved_equivalent is None
    and not buffer_failed_title_prefix_exists
    and not pipeline_stale
    and buffer_shelved_equivalent_count < 3
    and (
        (low_completion_drain_detected and project_queue_drained)
        or (legacy_low_completion_window and buffer_failed_equivalent_count < STRATEGY_SATURATED_FAILURE_THRESHOLD)
    )
):
    tasks.append(build_buffer_task(tasks, buffer_project))
    changed = True

for task in tasks:
    if not isinstance(task, dict):
        continue
    status = str(task.get("status") or "").strip().lower()
    if status != "approved":
        continue

    # Iteration 14 fix: NEVER rehydrate cross-project tasks into ANY queue.
    # These tasks belong to registries on inaccessible host paths (e.g. superheld).
    # The queue worker cannot lease them (registry lookup fails), so they create an
    # infinite rehydrate→fail-lease→remove→rehydrate cycle every hot reload.
    # The iteration 11 stale blocklist approach had subtle matching issues; this is
    # the definitive fix — cross-project tasks are read-only in this context.
    if task.get("_cross_project"):
        continue

    queue_handoff = task.get("queue_handoff") if isinstance(task.get("queue_handoff"), dict) else {}
    queue_handoff_status = str(queue_handoff.get("status") or "").strip().lower()
    # "already_queued" only describes approval-time queue state; if the live queue later
    # drains or loses that entry, the approved task still needs deterministic rehydration.
    if queue_handoff_status and queue_handoff_status not in {"queued", "already_queued"}:
        continue

    # Iteration 11 fix: use _source_project (injected by read_registry for cross-project
    # tasks) as a fallback BEFORE the "codex-agent-system" default. This prevents superheld
    # tasks (which may lack an explicit "project" field) from being placed into the
    # codex-agent-system queue, which causes an infinite rehydrate-remove loop.
    project = normalize_project(task.get("project") or task.get("target_project") or queue_handoff.get("project") or task.get("_source_project") or "codex-agent-system")
    queue_task = task_execution_text(task)
    task_key = normalize_task(queue_task)
    if not project or not task_key:
        continue
    if (project, task_key) in queue_entries or (project, task_key) == running_entry:
        continue
    # Iteration 11: skip tasks that were previously removed as stale (no
    # actionable registry record). Without this check, these tasks would be
    # re-added every loop iteration, creating an infinite cycle.
    if (project, task_key) in stale_blocklist:
        continue

    # Pre-flight environment check: skip tasks that require sandbox-blocked tools
    _task_lower = queue_task.lower()
    _sandbox_blocked = False
    _sandbox_patterns = [
        (r"(run|execute|verify).*gradlew|gradlew.*(build|assemble|compile)|assembledebug|compiledebugkotlin", "gradle_sandbox"),
        (r"(run|execute|verify).*xcodebuild|xcodebuild.*(build|test|archive)", "xcode_sandbox"),
    ]
    for _pat, _blocker in _sandbox_patterns:
        if __import__("re").search(_pat, _task_lower):
            _sandbox_blocked = True
            # Auto-shelve the task instead of queueing it
            task["status"] = "shelved"
            task["shelved_reason"] = f"auto-shelved: sandbox blocks {_blocker}"
            changed = True
            break
    if _sandbox_blocked:
        continue

    queue_file = queue_dir / f"{project}.txt"
    queue_file.parent.mkdir(parents=True, exist_ok=True)
    with queue_file.open("a", encoding="utf-8") as handle:
        handle.write(f"{queue_task}\n")
    queue_entries.add((project, task_key))
    requeued.append((project, queue_task))

if changed:
    write_registry(tasks)

for project, task in requeued:
    print(f"{project}\t{task}")
PY
}

reconcile_running_registry_tasks_to_active_leases() {
  ensure_runtime_dirs

  local active_leases_file
  active_leases_file="$(mktemp "$LOG_DIR/queue-active-leases.XXXXXX")"
  cat >"$active_leases_file"

  python3 - "$TASK_REGISTRY_FILE" "$QUEUE_DIR" "$QUEUE_RETRY_DIR" "$active_leases_file" "${MAX_AGENT_RETRIES:-2}" "${TASK_LOG:-$MEMORY_DIR/tasks.log}" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

registry_path = Path(sys.argv[1])
queue_dir = Path(sys.argv[2])
retry_dir = Path(sys.argv[3])
active_leases_path = Path(sys.argv[4])
default_max_retries = max(1, int(sys.argv[5] or "2"))
task_log_path = Path(sys.argv[6])


def now_dt() -> datetime:
    return datetime.now(timezone.utc)


def now_utc() -> str:
    return now_dt().strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def normalize_text(value: Any) -> str:
    return str(value or "").strip()


def normalize_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def first_non_empty_text(*values: Any) -> str:
    for value in values:
        candidate = normalize_text(value)
        if candidate:
            return candidate
    return ""


def read_registry() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        payload = {"tasks": []}
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    if not isinstance(tasks, list):
        tasks = []
        payload = {"tasks": tasks}
    return payload, tasks


def write_registry(payload: dict[str, Any]) -> None:
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=registry_path.parent, encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, registry_path)


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_result(value: Any) -> str:
    return str(value or "").strip().upper()


def queue_contains(project: str, task_text: str) -> bool:
    queue_file = queue_dir / f"{project}.txt"
    if not queue_file.exists():
        return False
    task_key = normalize_task(task_text)
    return any(normalize_task(line) == task_key for line in queue_file.read_text(encoding="utf-8").splitlines())


def append_queue(project: str, task_text: str) -> None:
    queue_file = queue_dir / f"{project}.txt"
    queue_file.parent.mkdir(parents=True, exist_ok=True)
    with queue_file.open("a", encoding="utf-8") as handle:
        handle.write(f"{task_text}\n")


def legacy_retry_file(project: str, task_text: str) -> Path:
    normalized_task = re.sub(r"[^a-z0-9_.-]+", "_", normalize_task(task_text)).strip("_")
    normalized_task = normalized_task or "task"
    return retry_dir / f"{project}__{normalized_task}.retry"


def retry_file(project: str, task_text: str) -> Path:
    retry_key = hashlib.sha256(f"{project}::{task_text}".encode("utf-8")).hexdigest()
    return retry_dir / f"{retry_key}.retry"


def set_retry_count(project: str, task_text: str, attempt: int) -> None:
    retry_path = retry_file(project, task_text)
    retry_path.parent.mkdir(parents=True, exist_ok=True)
    retry_path.write_text(f"{attempt}\n", encoding="utf-8")
    legacy_retry_file(project, task_text).unlink(missing_ok=True)


def clear_retry_count(project: str, task_text: str) -> None:
    retry_file(project, task_text).unlink(missing_ok=True)
    legacy_retry_file(project, task_text).unlink(missing_ok=True)


def load_task_log_records(file_path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        with file_path.open("r", encoding="utf-8") as handle:
            for raw_line in handle:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    record = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    records.append(record)
    except Exception:
        return []
    return records


def build_history_entry(*, at: str, action: str, to_status: str, project: str, queue_task: str, note: str, lane: str) -> dict[str, Any]:
    return {
        "at": at,
        "action": action,
        "from_status": "running",
        "to_status": to_status,
        "project": project,
        "queue_task": queue_task,
        "note": note,
        "lane": lane,
    }


def active_lease_matches(lease_id: str, project: str, task_text: str, active_leases: dict[str, tuple[str, str, str]]) -> bool:
    active_entry = active_leases.get(lease_id)
    if active_entry is None:
        return False
    _lane, active_project, active_task = active_entry
    return active_project == project and active_task == normalize_task(task_text)


def has_live_claimed_lease_state(execution: dict[str, Any]) -> bool:
    if str(execution.get("lease_state") or "").strip().lower() != "claimed":
        return False
    lease_expires_at = parse_timestamp(execution.get("lease_expires_at"))
    if lease_expires_at is None:
        return False
    return lease_expires_at > now_dt()


def late_terminal_outcome_for_task(task: dict[str, Any], project: str, task_text: str) -> str:
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    task_id = normalize_identifier(task.get("id"))
    lease_claimed_at = parse_timestamp(execution.get("lease_claimed_at"))

    result_text = normalize_result(execution_context.get("result"))
    execution_updated_at = parse_timestamp(execution_context.get("updated_at"))
    if lease_claimed_at and execution_updated_at and execution_updated_at < lease_claimed_at:
        result_text = ""

    if result_text == "SUCCESS":
        step_count = int(execution_context.get("step_count") or 0)
        completed_steps = int(execution_context.get("completed_steps") or 0)
        if step_count > 0 and completed_steps >= step_count:
            return "SUCCESS"
        result_text = ""

    if result_text == "FAILURE":
        return "FAILURE"

    matching_records: list[tuple[datetime, str]] = []
    for record in load_task_log_records(task_log_path):
        if normalize_project(record.get("project") or "") != project:
            continue
        record_task_id = normalize_identifier(record.get("task_id"))
        if task_id and record_task_id and record_task_id != task_id:
            continue
        if normalize_task(record.get("task")) != normalize_task(task_text):
            continue
        record_timestamp = parse_timestamp(record.get("timestamp"))
        if record_timestamp is None:
            continue
        if lease_claimed_at and record_timestamp < lease_claimed_at:
            continue
        record_result = normalize_result(record.get("result"))
        if record_result not in {"SUCCESS", "FAILURE"}:
            continue
        matching_records.append((record_timestamp, record_result))

    if matching_records:
        matching_records.sort(key=lambda item: item[0], reverse=True)
        return matching_records[0][1]

    return ""


payload, tasks = read_registry()
active_leases: dict[str, tuple[str, str, str]] = {}
if active_leases_path.exists():
    for raw_line in active_leases_path.read_text(encoding="utf-8").splitlines():
        lane, lease_id, project_name, task_name = (raw_line.split("\t", 3) + ["", "", "", ""])[:4]
        normalized_lease_id = str(lease_id or "").strip()
        if not normalized_lease_id:
            continue
        active_leases[normalized_lease_id] = (
            str(lane or "").strip(),
            normalize_project(project_name),
            normalize_task(task_name),
        )

transition_at = now_utc()
changed = False
actions: list[tuple[str, str, str]] = []

for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    if str(task.get("status") or "").strip().lower() != "running":
        continue

    project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    queue_task = task_execution_text(task)
    if not project or not queue_task:
        continue

    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    lease_state = str(execution.get("lease_state") or "").strip().lower()
    lease_id = str(execution.get("lease_id") or "").strip()
    lane = str(execution.get("lane") or "").strip()
    if lease_state == "claimed" and lease_id and active_lease_matches(lease_id, project, queue_task, active_leases):
        continue
    if has_live_claimed_lease_state(execution):
        continue

    late_terminal_outcome = late_terminal_outcome_for_task(task, project, queue_task)
    if late_terminal_outcome == "SUCCESS":
        next_task = dict(task)
        next_execution = dict(execution)
        history = next_task.get("history")
        if not isinstance(history, list):
            history = []
        next_task["status"] = "completed"
        next_task["updated_at"] = transition_at
        next_task["completed_at"] = str(next_task.get("completed_at") or transition_at)
        next_execution["state"] = "completed"
        next_execution["result"] = "SUCCESS"
        next_execution["will_retry"] = False
        next_execution["updated_at"] = transition_at
        next_execution["lease_state"] = "released"
        next_execution["lease_released_at"] = transition_at
        next_task["execution"] = next_execution
        history.append(
            build_history_entry(
                at=transition_at,
                action="execute_success",
                to_status="completed",
                project=project,
                queue_task=queue_task,
                note="Preserved completed task because late success evidence existed after the worker lease disappeared.",
                lane=lane,
            )
        )
        next_task["history"] = history[-20:]
        tasks[index] = next_task
        clear_retry_count(project, queue_task)
        changed = True
        actions.append((project, queue_task, "preserved completed task from late success evidence"))
        continue
    late_failure_evidence = late_terminal_outcome == "FAILURE"

    attempt = int(execution.get("attempt") or 0)
    max_retries = int(execution.get("max_retries") or default_max_retries or 2)
    next_task = dict(task)
    next_execution = dict(execution)
    next_execution["max_retries"] = max_retries
    next_execution["updated_at"] = transition_at
    next_execution["lease_state"] = "released"
    next_execution["lease_released_at"] = transition_at
    next_execution["result"] = "FAILURE"

    history = next_task.get("history")
    if not isinstance(history, list):
        history = []

    if attempt < max_retries:
        next_task["status"] = "approved"
        next_task["updated_at"] = transition_at
        next_task["last_retry_at"] = transition_at
        next_execution["state"] = "retrying"
        next_execution["will_retry"] = True
        next_task["execution"] = next_execution
        history.append(
            build_history_entry(
                at=transition_at,
                action="execute_reconcile",
                to_status="approved",
                project=project,
                queue_task=queue_task,
                note=(
                    "Reconciled running task back to approved after late failure evidence arrived."
                    if late_failure_evidence
                    else "Reconciled running task without a live worker lease back to approved."
                ),
                lane=lane,
            )
        )
        next_task["history"] = history[-20:]
        if not queue_contains(project, queue_task):
            append_queue(project, queue_task)
            action_reason = (
                "requeued task after late failure evidence"
                if late_failure_evidence
                else "requeued missing live worker lease"
            )
        else:
            action_reason = (
                "reset running task after late failure evidence"
                if late_failure_evidence
                else "reset running task without a live worker lease"
            )
        set_retry_count(project, queue_task, attempt)
    else:
        next_task["status"] = "failed"
        next_task["updated_at"] = transition_at
        next_task["failed_at"] = transition_at
        next_execution["state"] = "failed"
        next_execution["will_retry"] = False
        next_task["execution"] = next_execution
        history.append(
            build_history_entry(
                at=transition_at,
                action="execute_reconcile",
                to_status="failed",
                project=project,
                queue_task=queue_task,
                note=(
                    "Marked running task as failed after late failure evidence arrived and queue retries were exhausted."
                    if late_failure_evidence
                    else "Marked running task as failed because no live worker lease matched and queue retries were exhausted."
                ),
                lane=lane,
            )
        )
        next_task["history"] = history[-20:]
        clear_retry_count(project, queue_task)
        action_reason = (
            "failed task after late failure evidence with exhausted retries"
            if late_failure_evidence
            else "failed missing live worker lease after exhausted retries"
        )

    tasks[index] = next_task
    changed = True
    actions.append((project, queue_task, action_reason))

if changed:
    payload["tasks"] = tasks
    write_registry(payload)

for project, task_text, reason in actions:
    print(f"{project}\t{task_text}\t{reason}")
PY

  rm -f "$active_leases_file"
}

reclaim_stale_running_registry_tasks() {
  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$QUEUE_DIR" "$QUEUE_RETRY_DIR" "$STATUS_FILE" "${STALE_RUNNING_TASK_SECONDS:-900}" "${MAX_AGENT_RETRIES:-2}" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

registry_path = Path(sys.argv[1])
queue_dir = Path(sys.argv[2])
retry_dir = Path(sys.argv[3])
status_path = Path(sys.argv[4])
stale_seconds = max(60, int(sys.argv[5] or "900"))
default_max_retries = 2


def now_dt() -> datetime:
    return datetime.now(timezone.utc)


def now_utc() -> str:
    return now_dt().strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def normalize_text(value: Any) -> str:
    return str(value or "").strip()


def normalize_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def first_non_empty_text(*values: Any) -> str:
    for value in values:
        candidate = normalize_text(value)
        if candidate:
            return candidate
    return ""


def read_registry() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        payload = {"tasks": []}
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    if not isinstance(tasks, list):
        tasks = []
        payload = {"tasks": tasks}
    return payload, tasks


def write_registry(payload: dict[str, Any]) -> None:
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=registry_path.parent, encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, registry_path)


def read_status_entry() -> tuple[str, str]:
    if not status_path.exists():
        return ("", "")
    values: dict[str, str] = {}
    for line in status_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    state = str(values.get("state") or "").strip().lower()
    if state not in {"running", "retrying", "queued"}:
        return ("", "")
    return (normalize_project(values.get("project") or ""), normalize_task(values.get("task") or ""))


def queue_contains(project: str, task_text: str) -> bool:
    queue_file = queue_dir / f"{project}.txt"
    if not queue_file.exists():
      return False
    task_key = normalize_task(task_text)
    return any(normalize_task(line) == task_key for line in queue_file.read_text(encoding="utf-8").splitlines())


def append_queue(project: str, task_text: str) -> None:
    queue_file = queue_dir / f"{project}.txt"
    queue_file.parent.mkdir(parents=True, exist_ok=True)
    with queue_file.open("a", encoding="utf-8") as handle:
        handle.write(f"{task_text}\n")


def legacy_retry_file(project: str, task_text: str) -> Path:
    normalized_task = re.sub(r"[^a-z0-9_.-]+", "_", normalize_task(task_text)).strip("_")
    normalized_task = normalized_task or "task"
    return retry_dir / f"{project}__{normalized_task}.retry"


def retry_file(project: str, task_text: str) -> Path:
    retry_key = hashlib.sha256(f"{project}::{task_text}".encode("utf-8")).hexdigest()
    return retry_dir / f"{retry_key}.retry"


def set_retry_count(project: str, task_text: str, attempt: int) -> None:
    retry_path = retry_file(project, task_text)
    retry_path.parent.mkdir(parents=True, exist_ok=True)
    retry_path.write_text(f"{attempt}\n", encoding="utf-8")
    legacy_retry_file(project, task_text).unlink(missing_ok=True)


def clear_retry_count(project: str, task_text: str) -> None:
    retry_file(project, task_text).unlink(missing_ok=True)
    legacy_retry_file(project, task_text).unlink(missing_ok=True)


payload, tasks = read_registry()
active_status = read_status_entry()
now = now_dt()
actions: list[tuple[str, str, str]] = []

for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    if str(task.get("status") or "").strip().lower() != "running":
        continue

    project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    queue_task = task_execution_text(task)
    if not project or not queue_task:
        continue
    if (project, normalize_task(queue_task)) == active_status:
        continue

    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    lane = str(execution.get("lane") or "").strip()
    lease_state = str(execution.get("lease_state") or "").strip().lower()
    stale_claimed_lease = False
    if lane and lease_state == "claimed":
        lease_expires_at = parse_utc(execution.get("lease_expires_at"))
        if lease_expires_at is not None and lease_expires_at <= now:
            stale_claimed_lease = True
        else:
            continue

    updated_at = parse_utc(task.get("updated_at") or execution.get("updated_at") or (task.get("history") or [{}])[-1].get("at"))
    if not stale_claimed_lease and (updated_at is None or (now - updated_at).total_seconds() < stale_seconds):
        continue

    attempt = int(execution.get("attempt") or 0)
    max_retries = default_max_retries
    transition_at = now_utc()
    next_task = dict(task)
    next_execution = dict(execution)
    next_execution["max_retries"] = max_retries
    next_execution["updated_at"] = transition_at
    next_execution["lease_state"] = "released"
    next_execution["lease_released_at"] = transition_at
    next_execution["result"] = "FAILURE"

    history = task.get("history")
    if not isinstance(history, list):
        history = []

    if attempt < max_retries:
        next_task["status"] = "approved"
        next_task["updated_at"] = transition_at
        next_task["last_retry_at"] = transition_at
        next_execution["state"] = "retrying"
        next_execution["will_retry"] = True
        next_task["execution"] = next_execution
        history.append(
            {
                "at": transition_at,
                "action": "execute_reclaim",
                "from_status": "running",
                "to_status": "approved",
                "project": project,
                "queue_task": queue_task,
                "note": "Recovered stale running task without an active queue lane; task was requeued.",
            }
        )
        set_retry_count(project, queue_task, attempt)
        if not queue_contains(project, queue_task):
            append_queue(project, queue_task)
        actions.append((project, queue_task, "requeued stale running task"))
    else:
        next_task["status"] = "failed"
        next_task["updated_at"] = transition_at
        next_task["failed_at"] = transition_at
        next_execution["state"] = "failed"
        next_execution["will_retry"] = False
        # Propagate failure_kind so metrics and learning loops can classify this failure
        if not next_execution.get("failure_kind"):
            next_execution["failure_kind"] = "stale_task_timeout"
        next_task["execution"] = next_execution
        existing_execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
        existing_failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
        failure_kind = first_non_empty_text(
            next_execution.get("failure_kind"),
            existing_failure_context.get("failure_kind"),
            existing_execution_context.get("failure_kind"),
            "stale_task_timeout",
        )
        failed_step_text = first_non_empty_text(
            existing_failure_context.get("failed_step"),
            existing_execution_context.get("failed_step"),
            "Recovered stale running task without an active queue lane after retries were exhausted.",
        )
        failed_step_index = max(
            normalize_int(existing_failure_context.get("failed_step_index")),
            normalize_int(existing_execution_context.get("failed_step_index")),
            0,
        )
        repaired_execution_context = dict(existing_execution_context)
        run_id = first_non_empty_text(
            repaired_execution_context.get("run_id"),
            existing_failure_context.get("run_id"),
        )
        if run_id:
            repaired_execution_context["run_id"] = run_id
        provider_text = first_non_empty_text(
            repaired_execution_context.get("provider"),
            next_execution.get("provider"),
            task.get("execution_provider"),
            existing_failure_context.get("provider"),
        )
        if provider_text:
            repaired_execution_context["provider"] = provider_text
        repaired_execution_context["result"] = "FAILURE"
        repaired_execution_context["attempts"] = max(
            attempt,
            normalize_int(repaired_execution_context.get("attempts")),
            normalize_int(existing_failure_context.get("attempts")),
        )
        repaired_execution_context["failed_step_index"] = failed_step_index
        repaired_execution_context["failed_step"] = failed_step_text
        repaired_execution_context["updated_at"] = transition_at
        task_id = first_non_empty_text(
            task.get("id"),
            repaired_execution_context.get("task_id"),
            existing_failure_context.get("task_id"),
        )
        if task_id:
            repaired_execution_context["task_id"] = task_id
        failed_root_id = first_non_empty_text(
            task.get("original_failed_root_id"),
            repaired_execution_context.get("original_failed_root_id"),
            existing_failure_context.get("original_failed_root_id"),
            task.get("id"),
        )
        if failed_root_id:
            repaired_execution_context["original_failed_root_id"] = failed_root_id
        if failure_kind:
            repaired_execution_context["failure_kind"] = failure_kind
        next_task["execution_context"] = repaired_execution_context
        next_task["failure_context"] = {
            "run_id": run_id,
            "attempts": repaired_execution_context["attempts"],
            "failed_step_index": failed_step_index,
            "failed_step": failed_step_text,
            "timestamp": transition_at,
            "provider": provider_text,
            "task_id": task_id,
            "original_failed_root_id": failed_root_id,
            "failure_kind": failure_kind,
        }
        # Also set top-level last_failure_kind for chronic-failure detection in strategy-loop
        if not next_task.get("last_failure_kind"):
            next_task["last_failure_kind"] = next_execution.get("failure_kind", "stale_task_timeout")
        history.append(
            {
                "at": transition_at,
                "action": "execute_stale_failure",
                "from_status": "running",
                "to_status": "failed",
                "project": project,
                "queue_task": queue_task,
                "note": "Recovered stale running task without an active queue lane after retries were exhausted.",
            }
        )
        clear_retry_count(project, queue_task)
        actions.append((project, queue_task, "marked stale running task as failed"))

    next_task["history"] = history[-20:]
    tasks[index] = next_task

if actions:
    payload["tasks"] = tasks
    write_registry(payload)

for action in actions:
    print("\t".join(action))
PY
}

prune_invalid_actionable_registry_tasks() {
  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$QUEUE_DIR" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

registry_path = Path(sys.argv[1])
queue_dir = Path(sys.argv[2])
root_dir = Path(sys.argv[3])


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def sanitize_task_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def task_execution_text(task: dict[str, Any]) -> str:
    execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {}
    queue_handoff = task.get("queue_handoff") if isinstance(task.get("queue_handoff"), dict) else {}
    return sanitize_task_text(
        execution_brief.get("queue_task")
        or queue_handoff.get("task")
        or task.get("execution_task")
        or task.get("title")
        or ""
    )


def prompt_intake_malformed_reason(task: dict[str, Any]) -> str:
    prompt_intake = task.get("prompt_intake") if isinstance(task.get("prompt_intake"), dict) else {}
    if str(prompt_intake.get("source") or "").strip() != "dashboard_prompt_intake":
        return ""
    title = sanitize_task_text(task.get("title"))
    prompt_excerpt = sanitize_task_text(prompt_intake.get("prompt_excerpt"))
    meta_prompt = bool(re.search(r"^(you are|role:|goal:|core principles|system behavior)\b", prompt_excerpt, re.IGNORECASE))
    meta_tail_words = re.findall(
        r"[a-z0-9]+",
        re.sub(r"^(analyze|identify|generate|prioritize|review|inspect)\s+", "", title, flags=re.IGNORECASE).lower(),
    )
    generic_meta_tail = bool(meta_tail_words) and all(
        word
        in {
            "and",
            "or",
            "the",
            "a",
            "an",
            "its",
            "itself",
            "system",
            "systems",
            "project",
            "projects",
            "connected",
            "weakness",
            "weaknesses",
            "opportunity",
            "opportunities",
            "improvement",
            "improvements",
            "task",
            "tasks",
            "priority",
            "priorities",
            "analysis",
            "work",
            "backlog",
        }
        for word in meta_tail_words
    )
    if len(title) > 180:
        return "Prompt-intake task is too long to be a safe actionable item."
    if re.search(r"^(you are|role:|goal:|core principles|system behavior)\b", title, re.IGNORECASE):
        return "Prompt-intake task still contains prompt framing instead of actionable work."
    if re.search(r"(---|#\s|(?:^|\s)\*\s|core principles|system behavior|operate under human supervision)", title, re.IGNORECASE):
        return "Prompt-intake task still contains prompt-spec formatting or policy text."
    if meta_prompt and re.search(r"^(analyze|identify|generate|prioritize|review|inspect)\b", title, re.IGNORECASE) and generic_meta_tail:
        return "Prompt-intake task is still a generic planning/meta step instead of project-specific executable work."
    if re.search(r"\b\d+$", title) and re.search(r"\b1[\.\)]\s|\b2[\.\)]\s|\b3[\.\)]\s", prompt_excerpt):
        return "Prompt-intake task still contains numbered-list spillover from the source prompt."
    return ""


def satisfied_file_creation_reason(task: dict[str, Any]) -> str:
    title = sanitize_task_text(task.get("title"))
    match = re.search(r"`([^`]+)`", title)
    if not match:
      return ""
    candidate_path = match.group(1).strip()
    if not candidate_path or candidate_path.startswith("/"):
      return ""
    if not re.search(r"\b(add|create|write|store)\b", title, re.IGNORECASE):
      return ""
    target = root_dir / candidate_path
    if target.exists():
      return f"Target artifact already exists at {candidate_path}."
    return ""


def append_history(task: dict[str, Any], entry: dict[str, Any]) -> list[dict[str, Any]]:
    history = task.get("history")
    if not isinstance(history, list):
        history = []
    return [*history[-19:], entry]


def write_registry(tasks: list[dict[str, Any]]) -> None:
    payload = {"tasks": tasks}
    registry_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def remove_queue_entry(project: str, task_text: str) -> None:
    queue_file = queue_dir / f"{project}.txt"
    if not queue_file.exists():
        return
    normalized_target = normalize_task(task_text)
    kept: list[str] = []
    for line in queue_file.read_text(encoding="utf-8").splitlines():
        if normalize_task(line) == normalized_target:
            continue
        kept.append(line)
    queue_file.write_text(("\n".join(kept) + ("\n" if kept else "")), encoding="utf-8")


try:
    payload = json.loads(registry_path.read_text(encoding="utf-8"))
except Exception:
    payload = {"tasks": []}
tasks = payload.get("tasks") if isinstance(payload, dict) else []
tasks = tasks if isinstance(tasks, list) else []

actions: list[tuple[str, str, str]] = []
for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    status = str(task.get("status") or "").strip().lower()
    if status not in {"pending_approval", "approved"}:
        continue
    title = task_execution_text(task)
    project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    reason = prompt_intake_malformed_reason(task) or satisfied_file_creation_reason(task)
    if not reason:
        continue

    transition_at = now_utc()
    next_task = dict(task)
    next_task["status"] = "rejected"
    next_task["rejected_at"] = transition_at
    next_task["updated_at"] = transition_at
    next_task["history"] = append_history(
        next_task,
        {
            "at": transition_at,
            "action": "reject",
            "from_status": status,
            "to_status": "rejected",
            "project": project,
            "queue_task": title,
            "note": f"Task was rejected by backlog hygiene: {reason}",
        },
    )
    tasks[index] = next_task
    remove_queue_entry(project, title)
    actions.append((project, title, reason))

if actions:
    write_registry(tasks)

for project, title, reason in actions:
    print(f"{project}\t{title}\t{reason}")
PY
}

relative_path() {
  python3 - "$1" "$2" <<'PY'
import os
import sys

print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))
PY
}

require_command() {
  local component="$1"
  local binary="$2"
  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi
  log_msg ERROR "$component" "Required command is not available: $binary"
  return 1
}

normalize_provider_name() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1; print}')"
  case "$value" in
    codex|claude) printf '%s\n' "$value" ;;
    *) printf '\n' ;;
  esac
}

provider_exec_reset_state() {
  AGENT_EXEC_PROVIDER=""
  AGENT_EXEC_PROVIDER_REASON=""
  AGENT_EXEC_PROVIDER_FATAL=0
}

agent_exec_metadata_file() {
  local output_file="${1:-}"
  [ -n "$output_file" ] || return 1
  printf '%s.provider.json\n' "$output_file"
}

clear_agent_exec_metadata() {
  local output_file="${1:-}"
  local metadata_file
  metadata_file="$(agent_exec_metadata_file "$output_file" 2>/dev/null || true)"
  [ -n "$metadata_file" ] || return 0
  rm -f "$metadata_file" 2>/dev/null || true
}

write_agent_exec_metadata() {
  local output_file="${1:-}"
  local provider="${2:-}"
  local initial_provider="${3:-}"
  local fatal="${4:-false}"
  local reason="${5:-}"
  local metadata_file

  metadata_file="$(agent_exec_metadata_file "$output_file" 2>/dev/null || true)"
  [ -n "$metadata_file" ] || return 0

  mkdir -p "$(dirname "$metadata_file")"
  jq -cn \
    --arg provider "$(normalize_provider_name "$provider")" \
    --arg initial_provider "$(normalize_provider_name "$initial_provider")" \
    --arg reason "$reason" \
    --argjson fatal "$( [ "$fatal" = "true" ] && printf 'true' || printf 'false' )" \
    '{provider:$provider,initial_provider:$initial_provider,reason:$reason,fatal:$fatal}' >"$metadata_file"
}

read_agent_exec_metadata_field() {
  local output_file="${1:-}"
  local field="${2:-}"
  local metadata_file

  metadata_file="$(agent_exec_metadata_file "$output_file" 2>/dev/null || true)"
  [ -n "$metadata_file" ] || return 0
  [ -f "$metadata_file" ] || return 0

  jq -r --arg field "$field" '.[$field] // ""' "$metadata_file" 2>/dev/null || true
}

mark_provider_unavailable() {
  AGENT_EXEC_PROVIDER="$(normalize_provider_name "${1:-}")"
  AGENT_EXEC_PROVIDER_REASON="$(trim_text "${2:-Provider is unavailable.}")"
  AGENT_EXEC_PROVIDER_FATAL=1
}

provider_exec_requires_abort() {
  [ "${AGENT_EXEC_PROVIDER_FATAL:-0}" = "1" ]
}

current_exec_provider() {
  printf '%s\n' "${AGENT_EXEC_PROVIDER:-}"
}

provider_exec_failure_reason() {
  printf '%s\n' "${AGENT_EXEC_PROVIDER_REASON:-}"
}

agent_json_schema() {
  cat <<'EOF'
{"type":"object","properties":{"status":{"type":"string"},"message":{"type":"string"},"data":{"type":"object"}},"required":["status","message","data"]}
EOF
}

compute_provider_stats() {
  local task_log="${TASK_LOG:-$MEMORY_DIR/tasks.log}"
  local stats_file="$LEARNING_DIR/provider-stats.json"
  local registry_file="${TASK_REGISTRY_FILE:-$MEMORY_DIR/tasks.json}"
  python3 - "$task_log" "$stats_file" "$registry_file" <<'PY'
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

task_log_path = Path(sys.argv[1])
stats_path = Path(sys.argv[2])
registry_path = Path(sys.argv[3])

if not task_log_path.exists():
    task_log_path.parent.mkdir(parents=True, exist_ok=True)
    task_log_path.write_text("", encoding="utf-8")


def infer_category(task_text: str) -> str:
    text = task_text.lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for category, keywords in categories:
        if any(kw in text for kw in keywords):
            return category
    return "general"


records: list[dict] = []
for line in task_log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        records.append(json.loads(line))
    except (json.JSONDecodeError, ValueError):
        continue

registry_records_by_run: dict[str, dict] = {}
if registry_path.exists():
    try:
        registry_payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        registry_payload = {}
    tasks = registry_payload.get("tasks") if isinstance(registry_payload, dict) else []
    if isinstance(tasks, list):
        for task in tasks:
            if not isinstance(task, dict):
                continue
            execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
            execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
            failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
            provider = str(
                execution_context.get("provider")
                or failure_context.get("provider")
                or execution.get("provider")
                or task.get("execution_provider")
                or ""
            ).strip().lower()
            if provider not in {"codex", "claude"}:
                continue
            run_id = str(
                execution_context.get("run_id")
                or failure_context.get("run_id")
                or execution.get("run_id")
                or ""
            ).strip()
            if not run_id:
                continue
            result = str(
                execution_context.get("result")
                or failure_context.get("result")
                or execution.get("result")
                or ("SUCCESS" if str(task.get("status") or "").strip().lower() == "completed" else "")
                or ("FAILURE" if str(task.get("status") or "").strip().lower() == "failed" else "")
            ).strip().upper()
            attempts = int(
                execution_context.get("attempts")
                or failure_context.get("attempts")
                or execution.get("attempt")
                or 0
            )
            registry_records_by_run[run_id] = {
                "timestamp": str(task.get("updated_at") or task.get("created_at") or ""),
                "project": str(task.get("project") or task.get("target_project") or "codex-agent-system"),
                "task": str(task.get("execution_task") or task.get("title") or ""),
                "provider": provider,
                "result": result,
                "attempts": attempts,
                "total_step_attempts": int(execution_context.get("total_step_attempts") or attempts),
                "score": int(execution_context.get("score") or 0),
                "branch": "",
                "pr_url": "",
                "run_id": run_id,
                "duration_seconds": int(execution_context.get("duration_seconds") or 0),
            }

seen_run_ids: set[str] = set()
for record in records:
    run_id = str(record.get("run_id", "") or "").strip()
    provider = str(record.get("provider", "") or "").strip().lower()
    recovery = registry_records_by_run.get(run_id) if run_id else None
    if provider not in {"codex", "claude"} and isinstance(recovery, dict):
        record["provider"] = recovery["provider"]
    if run_id:
        seen_run_ids.add(run_id)

for run_id, recovery in registry_records_by_run.items():
    if run_id in seen_run_ids:
        continue
    records.append(recovery)

# provider -> category -> {success, total, attempts_sum, total_step_attempts_sum}
stats: dict[str, dict[str, dict]] = defaultdict(
    lambda: defaultdict(lambda: {"success": 0, "total": 0, "attempts_sum": 0, "total_step_attempts_sum": 0})
)

for rec in records:
    provider = str(rec.get("provider", "") or "").strip().lower()
    if provider not in ("codex", "claude"):
        provider = "codex"
    task_text = str(rec.get("task", ""))
    category = infer_category(task_text)
    result = str(rec.get("result", "")).upper()
    bucket = stats[provider][category]
    attempts = int(rec.get("attempts", 0) or 0)
    total_step_attempts = int(rec.get("total_step_attempts", attempts) or attempts)
    if total_step_attempts < attempts:
        total_step_attempts = attempts
    bucket["total"] += 1
    bucket["attempts_sum"] += attempts
    bucket["total_step_attempts_sum"] += total_step_attempts
    if result == "SUCCESS":
        bucket["success"] += 1

output: dict = {}
for provider, categories in sorted(stats.items()):
    provider_out: dict = {}
    for category, bucket in sorted(categories.items()):
        total = bucket["total"]
        avg_attempts = round(bucket["attempts_sum"] / total, 2) if total > 0 else 0.0
        avg_total_step_attempts = round(bucket["total_step_attempts_sum"] / total, 2) if total > 0 else 0.0
        provider_out[category] = {
            "success_rate": round(bucket["success"] / total, 4) if total > 0 else 0.0,
            "avg_attempts": avg_attempts,
            "avg_total_step_attempts": avg_total_step_attempts,
            "avg_extra_step_attempts": round(max(avg_total_step_attempts - avg_attempts, 0.0), 2),
            "task_count": total,
        }
    output[provider] = provider_out

stats_path.parent.mkdir(parents=True, exist_ok=True)
stats_path.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  update_provider_routing_rules || true
}

score_provider_for_category() {
  local task_text="${1:-}"
  local stats_file="$LEARNING_DIR/provider-stats.json"

  if [ ! -f "$stats_file" ]; then
    return 0
  fi

  python3 - "$stats_file" "$task_text" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

stats_path = Path(sys.argv[1])
task_text = sys.argv[2]

# --- infer_category (same logic as compute_provider_stats) ---
def infer_category(text: str) -> str:
    text = text.lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for category, keywords in categories:
        if any(kw in text for kw in keywords):
            return category
    return "general"


try:
    stats = json.loads(stats_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

if not isinstance(stats, dict) or not stats:
    raise SystemExit(0)

category = infer_category(task_text)

# Gather per-provider scores for this category
candidates: list[tuple[str, float, int, float]] = []  # (provider, success_rate, task_count, avg_total_step_attempts)
for provider, categories_map in stats.items():
    if not isinstance(categories_map, dict):
        continue
    entry = categories_map.get(category)
    if not isinstance(entry, dict):
        continue
    task_count = int(entry.get("task_count", 0))
    success_rate = float(entry.get("success_rate", 0.0))
    avg_total_step_attempts = float(entry.get("avg_total_step_attempts", entry.get("avg_attempts", 0.0)) or 0.0)
    candidates.append((provider, success_rate, task_count, avg_total_step_attempts))

# Require at least one provider with >= 3 historical tasks for this category
qualified = [(p, sr, tc, avg_total) for p, sr, tc, avg_total in candidates if tc >= 3]
if not qualified:
    raise SystemExit(0)

# Sort by success_rate descending, then task_count descending, then lower aggregate loop effort
qualified.sort(key=lambda x: (-x[1], -x[2], x[3], x[0]))

best_provider, best_rate, best_count, best_avg_total = qualified[0]

# Compute confidence: high if clear winner, medium if marginal
confidence = "high"
if len(qualified) >= 2:
    runner_up_rate = qualified[1][1]
    runner_up_avg_total = qualified[1][3]
    delta = best_rate - runner_up_rate
    if delta < 0.15:
        effort_delta = runner_up_avg_total - best_avg_total
        confidence = "medium" if effort_delta >= 1.0 else "low"
    elif delta < 0.30:
        confidence = "medium"

# Output: provider, confidence, reason (one per line)
reason = (
    f"{best_provider} has {best_rate:.0%} success over {best_count} tasks "
    f"in category '{category}' with {best_avg_total:.2f} avg total step attempts "
    f"(confidence: {confidence})"
)
print(best_provider)
print(confidence)
print(reason)
PY
}

resolve_task_provider_info() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local registry_file

  if [ -n "${QUEUE_TASK_PROVIDER_OVERRIDE:-}" ] && \
     [ "$(normalize_provider_name "${QUEUE_TASK_PROVIDER_OVERRIDE:-}")" != "" ] && \
     [ "$(normalize_task "${QUEUE_TASK_PROJECT_OVERRIDE:-}")" = "$(normalize_task "${project_name:-}")" ] && \
     [ "$(normalize_task "${QUEUE_TASK_TEXT_OVERRIDE:-}")" = "$(normalize_task "${queue_task:-}")" ]; then
    printf '%s\n' "$(normalize_provider_name "${QUEUE_TASK_PROVIDER_OVERRIDE:-}")"
    printf '%s\n' "${QUEUE_TASK_PROVIDER_REASON_OVERRIDE:-Queue lane selected a provider override for this task.}"
    printf '%s\n' "${QUEUE_TASK_PROVIDER_SOURCE_OVERRIDE:-queue_lane_override}"
    return 0
  fi

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$LEARNING_DIR/provider-stats.json" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from typing import Any


path, project_name, queue_task, stats_path = sys.argv[1:]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_task(value: Any) -> str:
    return normalize_text(value).lower()


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_provider(value: Any) -> str:
    candidate = str(value or "").strip().lower()
    return candidate if candidate in {"codex", "claude"} else ""


def infer_category(text: str) -> str:
    lowered = normalize_text(text).lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll", "iphone", "ipad", "tablet")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for category, keywords in categories:
        if any(keyword in lowered for keyword in keywords):
            return category
    return "general"


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


def infer_provider(title: Any, reason: Any, task_intent: Any) -> tuple[str, str, str]:
    intent = task_intent if isinstance(task_intent, dict) else {}
    combined = " ".join(
        normalize_text(value)
        for value in (
            title,
            reason,
            intent.get("objective"),
            intent.get("context_hint"),
            " ".join(intent.get("constraints") or []),
            " ".join(intent.get("success_signals") or []),
        )
        if normalize_text(value)
    ).lower()

    if "claude" in combined or "anthropic" in combined:
        return ("claude", "Task text explicitly references Claude or Anthropic.", "keyword")
    return ("codex", "Default provider is Codex when no explicit Claude hint is present.", "default")


def task_result(task: dict[str, Any]) -> str:
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    status = str(task.get("status") or "").strip().lower()
    result = str(
        execution_context.get("result")
        or failure_context.get("result")
        or execution.get("result")
        or ("SUCCESS" if status == "completed" else "")
        or ("FAILURE" if status == "failed" else "")
    ).strip().upper()
    return result


def task_score(task: dict[str, Any]) -> int:
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    raw_value = (
        execution_context.get("score")
        or failure_context.get("score")
        or execution.get("score")
        or task.get("score")
        or 0
    )
    try:
        return int(float(raw_value))
    except (TypeError, ValueError):
        return 0


def task_failed_step(task: dict[str, Any]) -> str:
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    return normalize_task(
        failure_context.get("failed_step")
        or execution_context.get("failed_step")
        or execution.get("current_step")
        or ""
    )


def task_provider(task: dict[str, Any]) -> str:
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    return normalize_provider(
        execution_context.get("provider")
        or failure_context.get("provider")
        or execution.get("provider")
        or task.get("execution_provider")
        or provider_selection.get("selected")
    )


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = normalize_text(task.get("original_failed_root_id"))
    if direct:
        return direct
    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = normalize_text(context.get("original_failed_root_id"))
        if candidate:
            return candidate
    return normalize_text(task.get("id"))


def pinned_provider_choice(task: dict[str, Any]) -> tuple[str, str, str] | None:
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    explicit = normalize_provider(task.get("execution_provider") or provider_selection.get("selected"))
    source = normalize_text(provider_selection.get("source")).lower()
    if not explicit:
        return None
    if not provider_selection:
        return (
            explicit,
            f"Provider is pinned on the task: {explicit}.",
            "task_registry",
        )
    if source in {"input", "manual_assessment", "task_registry"}:
        reason = normalize_text(provider_selection.get("reason")) or f"Provider is pinned on the task: {explicit}."
        return (explicit, reason, source or "task_registry")
    return None


def execution_learning_provider(selected_task: dict[str, Any], all_tasks: list[dict[str, Any]]) -> tuple[str, str, str] | None:
    project = normalize_project(selected_task.get("project") or selected_task.get("target_project") or project_name)
    selected_id = normalize_text(selected_task.get("id"))
    selected_title = normalize_task(task_execution_text(selected_task))
    selected_source_task_id = normalize_text(selected_task.get("source_task_id"))
    selected_root_id = original_failed_root_id(selected_task)
    selected_failed_step = task_failed_step(selected_task)
    selected_provider = task_provider(selected_task)
    if selected_provider not in {"codex", "claude"}:
        selected_provider = ""

    signal_counts: dict[str, dict[str, int]] = {
        "codex": {"failures": 0, "low_scores": 0, "failed_step_matches": 0, "title_matches": 0, "root_matches": 0},
        "claude": {"failures": 0, "low_scores": 0, "failed_step_matches": 0, "title_matches": 0, "root_matches": 0},
    }

    for task in all_tasks:
        if not isinstance(task, dict):
            continue
        if normalize_project(task.get("project") or task.get("target_project") or project_name) != project:
            continue
        if selected_id and normalize_text(task.get("id")) == selected_id:
            continue

        provider = task_provider(task)
        if provider not in {"codex", "claude"}:
            continue

        title_match = bool(selected_title) and normalize_task(task_execution_text(task)) == selected_title
        root_match = bool(selected_root_id) and original_failed_root_id(task) == selected_root_id
        source_match = bool(selected_source_task_id) and normalize_text(task.get("id")) == selected_source_task_id
        failed_step_match = bool(selected_failed_step) and task_failed_step(task) == selected_failed_step
        if not any((title_match, root_match, source_match, failed_step_match)):
            continue

        result = task_result(task)
        score = task_score(task)
        bucket = signal_counts[provider]
        if result == "FAILURE":
            bucket["failures"] += 1
        if score > 0 and score <= 3:
            bucket["low_scores"] += 1
        if title_match:
            bucket["title_matches"] += 1
        if root_match or source_match:
            bucket["root_matches"] += 1
        if failed_step_match:
            bucket["failed_step_matches"] += 1

    reroute_from = ""
    for provider_name in ("codex", "claude"):
        signals = signal_counts[provider_name]
        lineage_matches = signals["failed_step_matches"] + signals["root_matches"]
        should_reroute = (
            lineage_matches >= 1
            and (
                signals["failures"] >= 2
                or (
                    signals["failures"] >= 1
                    and signals["low_scores"] >= 1
                )
            )
        )
        if should_reroute:
            reroute_from = provider_name
            break

    if not reroute_from:
        return None

    alternative = "claude" if reroute_from == "codex" else "codex"
    if selected_provider and selected_provider != reroute_from:
        return None

    signals = signal_counts[reroute_from]
    reasons: list[str] = [f"{signals['failures']} matching failure(s)"]
    if signals["low_scores"] > 0:
        reasons.append(f"{signals['low_scores']} low-score run(s)")
    if signals["failed_step_matches"] > 0:
        reasons.append(f"{signals['failed_step_matches']} failed-step match(es)")
    if signals["root_matches"] > 0:
        reasons.append(f"{signals['root_matches']} parent/root match(es)")
    return (
        alternative,
        f"Execution learning rerouted from {reroute_from} to {alternative} using persisted task history ({', '.join(reasons)}).",
        "execution_learning",
    )


def learned_provider(title: Any, reason: Any, task_intent: Any) -> tuple[str, str, str] | None:
    combined = " ".join(
        normalize_text(value)
        for value in (
            title,
            reason,
            (task_intent or {}).get("objective") if isinstance(task_intent, dict) else "",
            (task_intent or {}).get("context_hint") if isinstance(task_intent, dict) else "",
        )
        if normalize_text(value)
    ).lower()
    if "claude" in combined or "anthropic" in combined or "codex" in combined:
        return None

    try:
        with open(stats_path, "r", encoding="utf-8") as handle:
            stats = json.load(handle)
    except Exception:
        return None
    if not isinstance(stats, dict) or not stats:
        return None

    category = infer_category(combined)
    candidates: list[tuple[str, float, int, float]] = []
    for provider, categories_map in stats.items():
        if not isinstance(categories_map, dict):
            continue
        entry = categories_map.get(category)
        if not isinstance(entry, dict):
            continue
        task_count = int(entry.get("task_count", 0) or 0)
        success_rate = float(entry.get("success_rate", 0.0) or 0.0)
        avg_total_step_attempts = float(entry.get("avg_total_step_attempts", entry.get("avg_attempts", 0.0)) or 0.0)
        candidates.append((normalize_provider(provider), success_rate, task_count, avg_total_step_attempts))

    qualified = [
        (provider, success_rate, task_count, avg_total_step_attempts)
        for provider, success_rate, task_count, avg_total_step_attempts in candidates
        if provider and task_count >= 3
    ]
    if not qualified:
        return None

    qualified.sort(key=lambda item: (-item[1], -item[2], item[3], item[0]))
    best_provider, best_rate, best_count, best_avg_total = qualified[0]
    confidence = "high"
    if len(qualified) >= 2:
        delta = best_rate - qualified[1][1]
        if delta < 0.15:
            effort_delta = qualified[1][3] - best_avg_total
            confidence = "medium" if effort_delta >= 1.0 else "low"
        elif delta < 0.30:
            confidence = "medium"

    if confidence == "low":
        return None

    return (
        best_provider,
        (
            f"Learned routing selected {best_provider} for category '{category}' from provider history "
            f"({best_rate:.0%} success over {best_count} tasks, {best_avg_total:.2f} avg total step attempts, "
            f"confidence: {confidence})."
        ),
        "learned",
    )


def read_tasks(file_path: str) -> list[dict[str, Any]]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return tasks if isinstance(tasks, list) else []


project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
status_rank = {"running": 5, "approved": 4, "pending_approval": 3, "completed": 2, "failed": 1}
selected: dict[str, Any] | None = None
selected_rank: tuple[int, str, str, int] | None = None

for index, task in enumerate(read_tasks(path)):
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        status_rank.get(str(task.get("status") or "").strip().lower(), 0),
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected = task

if isinstance(selected, dict):
    pinned = pinned_provider_choice(selected)
    if pinned is not None:
        provider, reason, source = pinned
        print(provider)
        print(reason)
        print(source)
        raise SystemExit(0)
    learned_from_execution = execution_learning_provider(selected, read_tasks(path))
    if learned_from_execution is not None:
        provider, reason, source = learned_from_execution
        print(provider)
        print(reason)
        print(source)
        raise SystemExit(0)
    # --- Routing-rule lookup stage ---
    try:
        routing_path = os.path.join(os.path.dirname(stats_path), "provider-routing.json")
        with open(routing_path, "r", encoding="utf-8") as rf:
            routing_data = json.load(rf)
        routing_rules = routing_data.get("rules") if isinstance(routing_data, dict) else []
        if isinstance(routing_rules, list):
            task_text = " ".join(
                normalize_text(v)
                for v in (
                    selected.get("title"),
                    selected.get("reason"),
                    (selected.get("task_intent") or {}).get("objective") if isinstance(selected.get("task_intent"), dict) else "",
                )
                if normalize_text(v)
            )
            task_category = infer_category(task_text)
            for rule in routing_rules:
                if not isinstance(rule, dict):
                    continue
                if rule.get("category") == task_category and rule.get("enabled") is True:
                    rule_provider = normalize_provider(rule.get("provider"))
                    if rule_provider:
                        rule_reason = normalize_text(rule.get("reason")) or f"Routing rule matched category '{task_category}'."
                        print(rule_provider)
                        print(rule_reason)
                        print("routing_rule")
                        raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass
    # --- End routing-rule lookup ---
    learned = learned_provider(selected.get("title"), selected.get("reason"), selected.get("task_intent"))
    if learned is not None:
        provider, reason, source = learned
        print(provider)
        print(reason)
        print(source)
        raise SystemExit(0)
    provider, reason, source = infer_provider(selected.get("title"), selected.get("reason"), selected.get("task_intent"))
    print(provider)
    print(reason)
    print(source)
    raise SystemExit(0)

provider, reason, source = infer_provider(queue_task, "", {})
print(provider)
print(reason)
print(source)
PY
}

task_supports_bounded_claude_overflow() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local registry_file

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any

path, project_name, queue_task = sys.argv[1:]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_task(value: Any) -> str:
    return normalize_text(value).lower()


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def read_tasks(file_path: str) -> list[dict[str, Any]]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return tasks if isinstance(tasks, list) else []


project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
selected: dict[str, Any] | None = None
selected_rank: tuple[int, str, str, int] | None = None
status_rank = {"running": 5, "approved": 4, "pending_approval": 3, "completed": 2, "failed": 1}

for index, task in enumerate(read_tasks(path)):
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        status_rank.get(str(task.get("status") or "").strip().lower(), 0),
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected = task

if not isinstance(selected, dict):
    raise SystemExit(1)

provider_selection = selected.get("provider_selection") if isinstance(selected.get("provider_selection"), dict) else {}
selection_source = normalize_text(provider_selection.get("source")).lower()
category = normalize_text(selected.get("category")).lower()
effort = int(selected.get("effort") or 99)
confidence = float(selected.get("confidence") or 0.0)

if (
    selection_source == "default"
    and category in {"ui", "code_quality"}
    and effort <= 2
    and confidence >= 0.8
):
    print("1")
    raise SystemExit(0)

print("0")
PY
}

select_balanced_queue_provider_info() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local base_provider="${3:-}"
  local base_reason="${4:-}"
  local base_source="${5:-}"
  local codex_active="${6:-0}"
  local claude_active="${7:-0}"

  base_provider="$(normalize_provider_name "$base_provider")"
  [ -n "$base_provider" ] || base_provider="codex"

  if [ "$base_provider" = "codex" ] && \
     [ "${claude_active:-0}" -lt "${codex_active:-0}" ] 2>/dev/null && \
     [ "$(task_supports_bounded_claude_overflow "$project_name" "$queue_task" 2>/dev/null || printf '0')" = "1" ]; then
    printf '%s\n' "claude"
    printf '%s\n' "Provider load balancing shifted this small default-routed task to Claude because Codex lanes are busier right now."
    printf '%s\n' "load_balance_overflow"
    return 0
  fi

  printf '%s\n%s\n%s\n' "$base_provider" "$base_reason" "$base_source"
}

select_queue_provider_for_lane() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local lane="${3:-}"
  local base_provider_info base_provider base_reason base_source

  base_provider_info="$(resolve_task_provider_info "$project_name" "$queue_task")"
  base_provider="$(printf '%s\n' "$base_provider_info" | sed -n '1p')"
  base_reason="$(printf '%s\n' "$base_provider_info" | sed -n '2p')"
  base_source="$(printf '%s\n' "$base_provider_info" | sed -n '3p')"
  base_provider="$(normalize_provider_name "$base_provider")"
  [ -n "$base_provider" ] || base_provider="codex"

  if { [ "$lane" != "lane-2" ] && [ "$lane" != "lane-3" ] && [ "$lane" != "lane-4" ]; } || [ "$base_provider" != "codex" ]; then
    printf '%s\n%s\n%s\n' "$base_provider" "${base_reason:-Selected provider for queue execution.}" "${base_source:-default}"
    return 0
  fi

  if [ "$(task_supports_bounded_claude_overflow "$project_name" "$queue_task" 2>/dev/null || printf '0')" = "1" ]; then
    printf '%s\n' "claude"
    printf '%s\n' "A secondary worker lane is using bounded Claude overflow for a small default-routed task so Codex and Claude stay busy in parallel."
    printf '%s\n' "lane_overflow"
    return 0
  fi

  printf '%s\n%s\n%s\n' "$base_provider" "$base_reason" "$base_source"
}

extract_claude_auth_failure_reason() {
  local raw_log_file="$1"
  python3 - "$raw_log_file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

content = path.read_text(encoding="utf-8", errors="ignore")
patterns = [
    "Failed to authenticate",
    "authentication_error",
    "OAuth token has expired",
    "Please obtain a new token or refresh your existing token",
    "401",
]

for pattern in patterns:
    if pattern in content:
        for line in content.splitlines():
            candidate = line.strip()
            if candidate:
                print(candidate[:400])
                raise SystemExit(0)
        print(pattern)
        raise SystemExit(0)
PY
}

write_json_file() {
  local output_file="$1"
  local status="$2"
  local message="$3"
  local data_json="${4:-null}"
  require_command json jq
  mkdir -p "$(dirname "$output_file")"
  jq -cn \
    --arg status "$status" \
    --arg message "$message" \
    --argjson data "$data_json" \
    '{status:$status,message:$message,data:$data}' >"$output_file"
}

print_json_file() {
  local file_path="$1"
  cat "$file_path"
}

json_get() {
  local file_path="$1"
  local filter="$2"
  jq -er "$filter" "$file_path"
}

validate_agent_json() {
  local file_path="$1"
  jq -e '
    type == "object" and
    (.status | type == "string") and
    (.message | type == "string") and
    (.data | type == "object")
  ' "$file_path" >/dev/null 2>&1
}

extract_bullet_rules_json() {
  local input_file="$1"
  local max_rules="${2:-5}"

  if [ ! -f "$input_file" ]; then
    printf '[]\n'
    return 0
  fi

  awk -v max_rules="$max_rules" '
    BEGIN { count=0 }
    /^- / {
      rule=$0
      sub(/^- /, "", rule)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rule)
      if (length(rule) == 0) next
      if (!seen[rule]++) {
        print rule
        count += 1
      }
      if (count >= max_rules) exit
    }
  ' "$input_file" | jq -R . | jq -s '.'
}

write_rules_markdown_file() {
  local title="$1"
  local output_file="$2"
  local rules_json="${3:-[]}"

  require_command json jq
  mkdir -p "$(dirname "$output_file")"
  jq -r --arg title "$title" '
    [$title, ""] + (map("- " + .)) + [""]
    | .[]
  ' <<<"$rules_json" >"$output_file"
}

git_repo_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

generate_task_branch() {
  printf 'codex/%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$RANDOM"
}

ensure_task_branch() {
  local project_dir="$1"
  local repo_root
  repo_root="$(git_repo_root "$project_dir")"
  [ -n "$repo_root" ] || return 0

  local branch
  branch="$(generate_task_branch)"
  if git -C "$repo_root" switch -c "$branch" >/dev/null 2>&1; then
    log_msg INFO git "Switched to branch $branch"
    printf '%s\n' "$branch"
    return 0
  fi

  if git -C "$repo_root" checkout -b "$branch" >/dev/null 2>&1; then
    log_msg INFO git "Switched to branch $branch"
    printf '%s\n' "$branch"
    return 0
  fi

  log_msg WARN git "Failed to create branch $branch"
  return 1
}

unstage_runtime_artifacts() {
  local repo_root="$1"
  local -a runtime_paths=(
    "codex-logs/system.log"
    "codex-logs/runs"
    "codex-logs/codex-home"
    "codex-memory/context.md"
    "codex-memory/decisions.md"
    "codex-memory/tasks.log"
    "codex-memory/memory.db"
    "codex-memory/.hf-cache"
    "status.txt"
  )

  git -C "$repo_root" restore --staged -- "${runtime_paths[@]}" >/dev/null 2>&1 || \
    git -C "$repo_root" reset -q HEAD -- "${runtime_paths[@]}" >/dev/null 2>&1 || true
}

staged_secret_paths() {
  local repo_root="$1"
  git -C "$repo_root" diff --cached --name-only \
    | grep -E '(^|/)(\.env($|\.)|.*\.(pem|key|p12|crt|cer|kdbx)$|id_(rsa|ed25519)|.*secret.*|.*credential.*)' || true
}

has_staged_secret_content() {
  local repo_root="$1"
  git -C "$repo_root" diff --cached --no-ext-diff --unified=0 \
    | grep -E '^\+.*(BEGIN [A-Z ]*PRIVATE KEY|API[_-]?KEY|SECRET|TOKEN|PASSWORD|AWS_SECRET_ACCESS_KEY)' >/dev/null 2>&1
}

commit_project_changes() {
  local project_dir="$1"
  local task="$2"
  local repo_root
  repo_root="$(git_repo_root "$project_dir")"
  [ -n "$repo_root" ] || return 1

  local project_path
  project_path="$(relative_path "$project_dir" "$repo_root")"
  if [ "$project_path" = "." ]; then
    if ! git -C "$repo_root" add -A >/dev/null 2>&1; then
      log_msg WARN git "Failed to stage repository changes in $repo_root"
      return 1
    fi
  else
    if ! git -C "$repo_root" add -A -- "$project_path" >/dev/null 2>&1; then
      log_msg WARN git "Failed to stage project changes for $project_path"
      return 1
    fi
  fi

  unstage_runtime_artifacts "$repo_root"

  local secret_paths
  secret_paths="$(staged_secret_paths "$repo_root")"
  if [ -n "$secret_paths" ]; then
    log_msg ERROR git "Refusing to commit staged sensitive file(s): $(printf '%s' "$secret_paths" | tr '\n' ' ')"
    return 1
  fi

  if has_staged_secret_content "$repo_root"; then
    log_msg ERROR git "Refusing to commit staged content that looks like a secret"
    return 1
  fi

  if git -C "$repo_root" diff --cached --quiet; then
    log_msg INFO git "No staged changes detected for $project_path"
    return 1
  fi

  local commit_message
  commit_message="improve: $(printf '%s' "$task" | tr '\n' ' ' | cut -c1-63)"
  if git -C "$repo_root" commit -m "$commit_message" >/dev/null 2>&1; then
    log_msg INFO git "Created commit: $commit_message"
    return 0
  fi

  log_msg WARN git "Commit failed for $project_path"
  return 1
}

push_branch_and_create_pr() {
  local project_dir="$1"
  local branch="$2"
  local task="$3"
  local repo_root
  repo_root="$(git_repo_root "$project_dir")"
  [ -n "$repo_root" ] || return 0

  if ! git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
    log_msg INFO git "No origin remote configured; skipping push and PR"
    return 0
  fi

  if ! git -C "$repo_root" push -u origin "$branch" >/dev/null 2>&1; then
    log_msg WARN git "Push failed for $branch"
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    log_msg INFO git "gh is not authenticated; skipping PR creation"
    return 0
  fi

  local existing_pr
  existing_pr="$(gh pr list --head "$branch" --json url --jq '.[0].url' 2>/dev/null || true)"
  if [ -n "$existing_pr" ] && [ "$existing_pr" != "null" ]; then
    printf '%s\n' "$existing_pr"
    return 0
  fi

  local default_branch
  default_branch="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
    log_msg INFO git "Default branch unavailable; skipping PR creation"
    return 0
  fi

  local title body pr_url
  title="codex: $(printf '%s' "$task" | tr '\n' ' ' | cut -c1-60)"
  body="Automated change for task:\n\n$task"
  pr_url="$(gh pr create --base "$default_branch" --head "$branch" --title "$title" --body "$body" 2>/dev/null || true)"
  if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
    printf '%s\n' "$pr_url"
    return 0
  fi

  log_msg INFO git "PR creation skipped or failed for $branch"
  return 0
}

notify_ntfy() {
  local title="$1"
  local message="$2"
  local priority="${3:-default}"
  local tags="${4:-robot}"
  local topic="${NTFY_TOPIC:-}"
  local base_url="${NTFY_URL:-https://ntfy.sh}"

  [ -n "$topic" ] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    log_msg WARN notifications "curl is unavailable; notification skipped"
    return 0
  fi

  curl -fsS \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$message" \
    "$base_url/$topic" >/dev/null 2>&1 || log_msg WARN notifications "Failed to send notification to $base_url/$topic"
}

# Truncate a text block to fit within the MAX_PROMPT_CONTEXT_CHARS budget.
# Usage: truncate_context_to_budget "$text" [max_chars]
truncate_context_to_budget() {
  clamp_prompt_context "${1-}" "${2:-$MAX_PROMPT_CONTEXT_CHARS}"
}

read_memory_context() {
  local project_name="${1:-}"
  local task_text="${2:-}"

  # Priority 1: Always load the memory index (core knowledge, max ~200 lines)
  local index_file="$MEMORY_DIR/index.md"
  if [ -f "$index_file" ]; then
    head -n 200 "$index_file"
    printf '\n'
  fi

  # Priority 2: Load relevant topic files based on task keywords
  local topics_dir="$MEMORY_DIR/topics"
  if [ -d "$topics_dir" ] && [ -n "$task_text" ]; then
    local task_lower
    task_lower="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"
    for topic_file in "$topics_dir"/*.md; do
      [ -f "$topic_file" ] || continue
      local topic_name
      topic_name="$(basename "$topic_file" .md)"
      # Match topic name against task keywords
      if printf '%s' "$task_lower" | grep -qiF "$topic_name"; then
        printf '## Memory Topic: %s\n' "$topic_name"
        tail -n 20 "$topic_file"
        printf '\n'
      fi
    done
  fi

  # Priority 3: Project-specific memory
  if [ -n "$project_name" ]; then
    local memory_file spec_file policy_file total_lines
    ensure_project_state "$project_name"
    memory_file="$(project_memory_file "$project_name")"
    spec_file="$(project_spec_file "$project_name")"
    policy_file="$(project_policy_file "$project_name")"
    if [ -f "$memory_file" ]; then
      total_lines="$(wc -l <"$memory_file" 2>/dev/null || printf '0')"
      if [ "$total_lines" -le 40 ]; then
        safe_read_file "$memory_file"
      else
        sed -n '1,6p' "$memory_file"
        printf '\n'
        tail -n 34 "$memory_file" 2>/dev/null || true
      fi
    fi
    printf '\n'
    read_automation_memory_context "$project_name" 8
    if [ -f "$spec_file" ]; then
      printf '%s\n' "# Project Spec"
      sed -n '1,40p' "$spec_file"
      printf '\n'
    fi
    if [ -f "$policy_file" ]; then
      printf '%s\n' "# Project Policy"
      cat "$policy_file"
      printf '\n'
    fi
  fi

  # Priority 4: Recent decisions (audit trail)
  safe_tail 10 "$DECISIONS_FILE"
}

MEMORY_TOPICS_DIR="$MEMORY_DIR/topics"
MEMORY_INDEX_FILE="$MEMORY_DIR/index.md"
SCOPED_RULES_FILE="$MEMORY_DIR/scoped-rules.json"
MAX_MEMORY_INDEX_LINES=200

resolve_relevant_topics() {
  local task_text="${1:-}"
  local task_lower
  task_lower="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"

  local topics=""

  # Keyword-based topic resolution
  if printf '%s' "$task_lower" | grep -qE '(timeout|crash|error|fail|stable|restart|resilient)'; then
    topics="$topics stability.md timeout-patterns.md"
  fi
  if printf '%s' "$task_lower" | grep -qE '(dashboard|ui|mobile|button|display|render|css|html)'; then
    topics="$topics ui.md"
  fi
  if printf '%s' "$task_lower" | grep -qE '(speed|slow|fast|cache|optimize|performance|latency|memory)'; then
    topics="$topics performance.md"
  fi
  if printf '%s' "$task_lower" | grep -qE '(refactor|lint|clean|quality|test|spec|format|style)'; then
    topics="$topics code_quality.md"
  fi
  if printf '%s' "$task_lower" | grep -qE '(queue|worker|lane|poll|dispatch|retry|requeue)'; then
    topics="$topics queue-handling.md"
  fi
  if printf '%s' "$task_lower" | grep -qE '(timeout|deadline|duration|seconds|slow)'; then
    topics="$topics timeout-patterns.md"
  fi

  # Deduplicate
  printf '%s' "$topics" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

load_scoped_rules_for_task() {
  local task_text="${1:-}"
  local project_name="${2:-}"

  [ -f "$SCOPED_RULES_FILE" ] || return 0

  python3 - "$SCOPED_RULES_FILE" "$task_text" <<'PY'
import json, sys, re
from pathlib import Path

rules_path = Path(sys.argv[1])
task_text = sys.argv[2].lower()

try:
    rules = json.loads(rules_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

# Extract file/path references from the task text
path_keywords = re.findall(r'[a-z_-]+\.[a-z]+|[a-z_-]+/[a-z_.-]+', task_text)

matched_rules = []
for entry in rules:
    paths = entry.get("paths", [])
    for pattern in paths:
        # Simple matching: check if any keyword from the task matches the pattern
        pattern_base = pattern.replace("**", "").replace("*", "").replace("/", " ").strip()
        pattern_parts = [p for p in pattern_base.split() if len(p) > 2]
        for part in pattern_parts:
            if part.lower() in task_text:
                matched_rules.extend(entry.get("rules", []))
                break
        for kw in path_keywords:
            if any(p.rstrip("*").rstrip("/") in kw or kw in p for p in paths):
                matched_rules.extend(entry.get("rules", []))
                break

if matched_rules:
    seen = set()
    print("\n## Scoped Rules")
    for rule in matched_rules:
        if rule not in seen:
            seen.add(rule)
            print(f"- {rule}")
PY
}

read_memory_context_with_topics() {
  local project_name="${1:-}"
  local task_text="${2:-}"

  # 1. Always load index (max 200 lines)
  if [ -f "$MEMORY_INDEX_FILE" ]; then
    printf '%s\n' "# Memory Index"
    head -n "$MAX_MEMORY_INDEX_LINES" "$MEMORY_INDEX_FILE"
    printf '\n'
  fi

  # 2. Load relevant topic files based on task keywords
  if [ -d "$MEMORY_TOPICS_DIR" ] && [ -n "$task_text" ]; then
    local topics
    topics="$(resolve_relevant_topics "$task_text")"
    for topic_file in $topics; do
      if [ -f "$MEMORY_TOPICS_DIR/$topic_file" ]; then
        printf '%s\n' "## Topic: $topic_file"
        head -n 30 "$MEMORY_TOPICS_DIR/$topic_file"
        printf '\n'
      fi
    done
  fi

  # 3. Scoped rules for affected paths
  load_scoped_rules_for_task "$task_text" "$project_name"

  # 4. Existing project memory (reduced to last 20 lines instead of 34)
  if [ -n "$project_name" ]; then
    local memory_file spec_file policy_file
    ensure_project_state "$project_name"
    memory_file="$(project_memory_file "$project_name")"
    spec_file="$(project_spec_file "$project_name")"
    policy_file="$(project_policy_file "$project_name")"
    if [ -f "$memory_file" ]; then
      printf '\n%s\n' "# Project Memory (recent)"
      tail -n 20 "$memory_file" 2>/dev/null || true
    fi
    read_automation_memory_context "$project_name" 6
    if [ -f "$spec_file" ]; then
      printf '\n%s\n' "# Project Spec"
      sed -n '1,40p' "$spec_file"
    fi
    if [ -f "$policy_file" ]; then
      printf '\n%s\n' "# Project Policy"
      cat "$policy_file"
    fi
  fi

  # 5. Recent decisions (reduced from 10 to 5 for space)
  printf '\n%s\n' "# Recent Decisions"
  safe_tail 5 "$DECISIONS_FILE"
}

refresh_memory_index() {
  local rules_file="$RULES_FILE"
  python3 - "$MEMORY_INDEX_FILE" "$rules_file" <<'PY'
import sys
from pathlib import Path

index_path = Path(sys.argv[1])
rules_path = Path(sys.argv[2])

section_order = [
    "## Core Architecture Rules",
    "## Known Failure Patterns",
    "## Operational Rules",
]

section_limits = {
    "## Core Architecture Rules": 5,
    "## Known Failure Patterns": 10,
    "## Operational Rules": 8,
}

defaults = {
    "## Core Architecture Rules": [
        "All agents must return valid JSON with status, message, data fields",
        "Maximum 6 steps per plan, last step must be verification",
        "Never break the system — all changes must be incremental and reversible",
        "Queue workers execute in parallel — avoid file conflicts",
        "Task registry is the single source of truth for task state",
    ],
    "## Known Failure Patterns": [
        "Timeout failures often caused by oversized context or missing dependencies",
        "Retry loops occur when the same approach is repeated without failure analysis",
        "Strategy saturation signals that the system is generating tasks faster than completing them",
        "Registry pressure above 512KB degrades dashboard read performance",
        "Re-approving failed tasks can cause infinite retry churn — track cumulative_attempts across approval cycles",
    ],
    "## Operational Rules": [
        "Shell scripts must pass bash -n before deployment",
        "Python must pass ast.parse before deployment",
        "JSON must pass json.tool before deployment",
        "Classify failures as retriable vs non-retriable before retrying",
        "Non-retriable errors (auth, syntax, missing dependency, missing environment) should not consume retries",
        "Metrics accuracy is the foundation of learning — always refresh after state changes",
    ],
}

skip_markers = (
    "task failed",
    "step 1:",
    "expected:",
    "planner timed out",
    "implement the smallest safe change",
    "inspect only `",
    "error occurred ",
    "(files:",
    "latest completion signal",
    "verify the change:",
)


def stable_line(text: str) -> bool:
    lowered = text.lower()
    if not text or len(text) > 180:
        return False
    if text.startswith("[") or text.startswith("In `"):
        return False
    if any(marker in lowered for marker in skip_markers):
        return False
    return True


sections = {name: [] for name in section_order}
current_section = None
if index_path.exists():
    for raw_line in index_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line in sections:
            current_section = line
            continue
        if current_section not in sections or not line.startswith("- "):
            continue
        text = line[2:].strip()
        if stable_line(text) and text not in sections[current_section]:
            sections[current_section].append(text)

for section_name, fallback_items in defaults.items():
    for item in fallback_items:
        if item not in sections[section_name]:
            sections[section_name].append(item)

learned_rules = []
if rules_path.exists():
    for raw_line in rules_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("- "):
            text = line[2:].strip()
            if text and text not in learned_rules:
                learned_rules.append(text)

parts = [
    "# Codex Agent System — Memory Index",
    "# This file is always loaded into agent context (max 200 lines).",
    "# Detailed learnings are stored in codex-memory/topics/<category>.md",
    "",
]

for section_name in section_order:
    parts.append(section_name)
    for text in sections[section_name][:section_limits[section_name]]:
        parts.append(f"- {text}")
    parts.append("")

parts.append("## Learned Rules")
if learned_rules:
    for text in learned_rules[:5]:
        parts.append(f"- {text}")
else:
    parts.append("- No learned rules recorded yet.")
parts.append("")

index_path.parent.mkdir(parents=True, exist_ok=True)
index_path.write_text("\n".join(parts).rstrip() + "\n", encoding="utf-8")
PY
}

categorize_and_store_learning() {
  local learning_text="${1:-}"
  local category="${2:-code_quality}"

  [ -n "$learning_text" ] || return 0

  local topic_file="$MEMORY_TOPICS_DIR/${category}.md"
  local timestamp
  timestamp="$(now_utc)"

  # Ensure topics directory exists
  mkdir -p "$MEMORY_TOPICS_DIR"

  # Append to topic file
  if [ ! -f "$topic_file" ]; then
    printf '# %s Learnings\n' "$category" >"$topic_file"
  fi
  printf -- '- %s: %s\n' "$timestamp" "$learning_text" >>"$topic_file"

  refresh_memory_index
}

MAX_PROMPT_CONTEXT_CHARS="${MAX_PROMPT_CONTEXT_CHARS:-4000}"

build_dynamic_context() {
  local task="${1:-}"
  local project="${2:-}"
  local budget="$MAX_PROMPT_CONTEXT_CHARS"
  local context=""
  local chunk=""
  local chunk_len=0

  # Priority 1: Core rules (always loaded, ~500 chars)
  if [ -f "$RULES_FILE" ]; then
    chunk="$(safe_tail 20 "$RULES_FILE")"
    chunk_len="${#chunk}"
    if [ "$chunk_len" -gt 0 ] && [ "$chunk_len" -le "$budget" ]; then
      context="${context}${chunk}"$'\n'
      budget=$((budget - chunk_len))
    fi
  fi

  # Priority 2: Memory index (always loaded, ~1500 chars)
  if [ -f "$MEMORY_INDEX_FILE" ]; then
    chunk="$(head -n "$MAX_MEMORY_INDEX_LINES" "$MEMORY_INDEX_FILE")"
    chunk_len="${#chunk}"
    if [ "$chunk_len" -gt 0 ] && [ "$chunk_len" -le "$budget" ]; then
      context="${context}${chunk}"$'\n'
      budget=$((budget - chunk_len))
    fi
  fi

  # Priority 3: Relevant topic files (on-demand, ~2000 chars)
  if [ -d "$MEMORY_TOPICS_DIR" ] && [ -n "$task" ] && [ "$budget" -gt 1000 ]; then
    local topics
    topics="$(resolve_relevant_topics "$task")"
    for topic_file in $topics; do
      if [ -f "$MEMORY_TOPICS_DIR/$topic_file" ] && [ "$budget" -gt 500 ]; then
        chunk="$(printf '## Topic: %s\n' "$topic_file"; head -n 30 "$MEMORY_TOPICS_DIR/$topic_file")"
        chunk_len="${#chunk}"
        if [ "$chunk_len" -le "$budget" ]; then
          context="${context}${chunk}"$'\n'
          budget=$((budget - chunk_len))
        fi
      fi
    done
  fi

  # Priority 4: Scoped rules for this task (~500 chars)
  if [ -f "$SCOPED_RULES_FILE" ] && [ "$budget" -gt 500 ]; then
    chunk="$(load_scoped_rules_for_task "$task" "$project" 2>/dev/null || true)"
    chunk_len="${#chunk}"
    if [ "$chunk_len" -gt 0 ] && [ "$chunk_len" -le "$budget" ]; then
      context="${context}${chunk}"$'\n'
      budget=$((budget - chunk_len))
    fi
  fi

  # Priority 5: Project memory (reduced, ~1000 chars)
  if [ -n "$project" ] && [ "$budget" -gt 500 ]; then
    local memory_file
    ensure_project_state "$project"
    memory_file="$(project_memory_file "$project")"
    if [ -f "$memory_file" ]; then
      local max_project_lines=$((budget / 80))
      [ "$max_project_lines" -gt 30 ] && max_project_lines=30
      chunk="$(printf '# Project Memory\n'; tail -n "$max_project_lines" "$memory_file" 2>/dev/null || true)"
      chunk_len="${#chunk}"
      if [ "$chunk_len" -le "$budget" ]; then
        context="${context}${chunk}"$'\n'
        budget=$((budget - chunk_len))
      fi
    fi
  fi

  # Priority 6: Project spec (first lines, ~1000 chars)
  if [ -n "$project" ] && [ "$budget" -gt 500 ]; then
    local spec_file
    spec_file="$(project_spec_file "$project")"
    if [ -f "$spec_file" ]; then
      local max_spec_lines=$((budget / 80))
      [ "$max_spec_lines" -gt 40 ] && max_spec_lines=40
      chunk="$(printf '# Project Spec\n'; sed -n "1,${max_spec_lines}p" "$spec_file")"
      chunk_len="${#chunk}"
      if [ "$chunk_len" -le "$budget" ]; then
        context="${context}${chunk}"$'\n'
        budget=$((budget - chunk_len))
      fi
    fi
  fi

  # Priority 7: Similar tasks (expensive, only if budget allows, ~3000 chars)
  if [ "$budget" -gt 2000 ] && [ -n "$task" ]; then
    chunk="$(build_similar_task_context "$task" "$project" "" 2>/dev/null | head -c "$budget" || true)"
    chunk_len="${#chunk}"
    if [ "$chunk_len" -gt 0 ] && [ "$chunk_len" -le "$budget" ]; then
      context="${context}${chunk}"$'\n'
      budget=$((budget - chunk_len))
    fi
  fi

  # Priority 8: Source context (rest of budget)
  if [ "$budget" -gt 1000 ] && [ -n "$task" ]; then
    chunk="$(build_prompt_source_context "$task" "" "$project" 2>/dev/null | head -c "$budget" || true)"
    chunk_len="${#chunk}"
    if [ "$chunk_len" -gt 0 ] && [ "$chunk_len" -le "$budget" ]; then
      context="${context}${chunk}"$'\n'
      budget=$((budget - chunk_len))
    fi
  fi

  # Priority 9: Recent decisions (last few, ~300 chars)
  if [ "$budget" -gt 200 ]; then
    local decision_count=5
    [ "$budget" -lt 500 ] && decision_count=3
    chunk="$(printf '# Recent Decisions\n'; safe_tail "$decision_count" "$DECISIONS_FILE")"
    chunk_len="${#chunk}"
    if [ "$chunk_len" -le "$budget" ]; then
      context="${context}${chunk}"$'\n'
    fi
  fi

  printf '%s' "$context"
}

classify_task_complexity() {
  local task="${1:-}"
  local task_lower
  task_lower="$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')"

  # Explore: read-only inspection, search, analysis
  if printf '%s' "$task_lower" | grep -qE '(inspect|check|list|count|search|find|grep|explore|read|analyze|scan|audit)'; then
    if ! printf '%s' "$task_lower" | grep -qE '(fix|implement|add|create|write|refactor|change|update|modify)'; then
      printf 'explore'
      return 0
    fi
  fi

  # Plan: architecture, major redesign, multi-component
  if printf '%s' "$task_lower" | grep -qE '(architect|redesign|refactor major|strategy|plan|design|rethink|overhaul)'; then
    printf 'plan'
    return 0
  fi

  # Verify: run tests, validation, verification
  if printf '%s' "$task_lower" | grep -qE '^(verify|validate|test|run tests|check if|ensure that|confirm)'; then
    printf 'verify'
    return 0
  fi

  # Default: implement
  printf 'implement'
}

resolve_provider_for_step() {
  local task="${1:-}"
  local step_text="${2:-}"
  local step_kind="${3:-implement}"
  local base_provider="${4:-codex}"

  local complexity
  complexity="$(classify_task_complexity "$step_text")"

  # Map complexity to provider preference
  # Note: This returns a provider hint — the actual provider resolution
  # still uses resolve_task_provider_info as before, but this adds granularity.
  case "$complexity" in
    "explore")
      printf '%s' "$base_provider"  # Same provider, lighter model hint
      ;;
    "plan")
      printf '%s' "$base_provider"  # Same provider, heavier model hint
      ;;
    "verify")
      printf '%s' "$base_provider"  # Same provider, lighter model hint
      ;;
    *)
      printf '%s' "$base_provider"
      ;;
  esac
}

resolve_execution_path() {
  local task="${1:-}"
  local complexity
  complexity="$(classify_task_complexity "$task")"

  # Returns a comma-separated list of agent stages to execute.
  # This allows the orchestrator to skip unnecessary stages.
  case "$complexity" in
    "explore")
      # Read-only tasks: planner + coder only, skip reviewer/evaluator
      printf 'planner,coder'
      ;;
    "verify")
      # Verification tasks: planner + coder + evaluator (skip reviewer)
      printf 'planner,coder,evaluator'
      ;;
    "plan")
      # Planning tasks: full pipeline
      printf 'planner,coder,reviewer,evaluator'
      ;;
    "implement"|*)
      # Implementation tasks: full pipeline
      printf 'planner,coder,reviewer,evaluator'
      ;;
  esac
}

resolve_max_retries() {
  local task="${1:-}"
  local default_retries="${MAX_AGENT_RETRIES:-2}"
  local complexity
  complexity="$(classify_task_complexity "$task" 2>/dev/null || printf 'implement')"

  case "$complexity" in
    "explore"|"verify")
      # Simple tasks: fail fast, don't waste retries
      printf '1'
      ;;
    "plan")
      # Planning tasks: 2 retries (complex but deterministic)
      printf '2'
      ;;
    "implement"|*)
      # Implementation tasks: full retries
      printf '%s' "$default_retries"
      ;;
  esac
}

# --- Failure Classification ---
# Classifies failures as retriable or non-retriable to prevent wasted retry attempts.
# Based on MAST taxonomy: specification failures are non-retriable, execution failures are retriable.
# Returns JSON: {"retriable": bool, "category": str, "reason": str}
classify_failure() {
  local failed_step="${1:-}"
  local error_output="${2:-}"
  local attempt="${3:-1}"

  python3 - "$failed_step" "$error_output" "$attempt" <<'PYCLASSIFY'
import json, re, sys

failed_step = sys.argv[1]
error_output = sys.argv[2]
attempt = int(sys.argv[3] or "1")
combined = (failed_step + " " + error_output).lower()

non_retriable = [
    (r"permission denied|access denied|forbidden", "auth_error", "Authentication/permission issue requires manual intervention"),
    (r"no such file or directory.*(config|\.env|secret|credential)", "missing_config", "Missing configuration file requires setup"),
    (r"syntax error|parse error|unexpected token", "syntax_error", "Code syntax error in task specification needs revision"),
    (r"module not found|import error|no module named", "missing_dependency", "Missing dependency requires installation"),
    (r"disk full|no space left|quota exceeded", "resource_exhaustion", "Resource exhaustion requires cleanup"),
    (r"invalid.*flag|unknown.*option|unrecognized.*argument", "invalid_invocation", "Invalid CLI flags need task specification fix"),
    # Sandbox/permission policy restrictions should outrank environment hints when both
    # appear in the same verification transcript (for example Gradle socket bind failures).
    (r"sandbox.*perm|blocked by.*policy|permission.*policy|operation not permitted|socketexception: operation not permitted|not permitted|cannot.*create.*node_modules|npm.*blocked|yarn.*blocked|pnpm.*blocked|blocked by.*permission|command.*blocked|execution.*blocked|requires approval|security.*restrict|sandbox.*block|sandbox.*security|permission.*system.*block", "sandbox_restriction", "Sandbox policy blocks required operation — needs environment config change"),
    # New: environment missing (SDK, JDK, etc.) — never recoverable by retry
    (r"android sdk|sdk.not.found|jdk.*(missing|not found)|java_home.*(not set|missing)|gradle.*(not found|failed to find|could not resolve|plugin.*was not found)|com\.android\.(application|library)|plugin.*com\.android|android.*gradle.*plugin|gradlew.*(not found|no such file)|compilesdk|minsdk|android\s*\{|buildfeatures|compose.*options|kotlin.*android", "missing_environment", "Missing SDK/JDK/Android environment requires manual setup"),
    # New: authentication/API key issues
    (r"api.key.*(invalid|expired|missing)|authentication.*fail|unauthorized|401", "auth_failure", "API key or auth failure requires manual fix"),
    # New: task specification is too vague for coder to act on
    (r"inspect the current project|read the relevant source|target file is unclear", "vague_specification", "Task specification too vague for coder agent"),
    # New: git conflicts that retries won't fix
    (r"merge conflict|cannot lock ref|unable to create.*lock", "git_conflict", "Git conflict requires manual resolution"),
    # Build tool not installed or not on PATH
    (r"(xcodebuild|xcrun|pod|cocoapods|flutter|dart).*(not found|command not found|no such file)", "missing_build_tool", "Required build tool not installed in this environment"),
    # Platform-specific compilation that cannot succeed without native toolchain
    (r"no.*ios.*simulator|no.*android.*emulator|device not found|no.*provisioning.*profile", "missing_platform", "Target platform toolchain/device unavailable"),
    # Task references files that don't exist in the workspace
    (r"\.(kt|swift|java|xml|gradle|py|js|ts|sh).*(not found|does not exist|missing)|file.*(not found|does not exist|missing).*\.(kt|swift|java|xml|gradle|py|js|ts|sh)", "missing_source_file", "Task references source files not present in workspace"),
    # Task plan is impossible given project structure (wrong language, framework, etc.)
    (r"project (has no|does not (have|contain|use))|no.*found in (project|workspace|repo)", "project_mismatch", "Task requirements don't match project structure"),
    # Repeated identical failure text — same error on every attempt indicates structural issue
    (r"identical.*previous.*attempt|same (error|failure|issue) (on|in|as) (previous|prior|last|attempt)", "repeated_identical_failure", "Identical failure across attempts indicates structural issue"),
]

retriable = [
    (r"rate limit|too many requests|429", "rate_limit", "Rate limited", 3),
    (r"timeout|timed out|deadline exceeded", "timeout", "Execution timeout retriable with reduced scope", 2),
    (r"connection refused|network.*unreachable|dns.*resolution", "network_error", "Transient network issue", 1),
    (r"internal server error|502|503|504", "server_error", "Transient server error", 1),
    (r"context.*too.*long|token.*limit|context.*window", "context_overflow", "Context overflow retriable with smaller context", 2),
    (r"empty.*response|null.*output|no.*output", "empty_output", "Empty model output", 1),
    # New: review/evaluation failures are retriable (coder can try different approach)
    (r"review.*(?:rejected|not approved|fail)|reviewer.*(?:rejected|fail)|not approved", "review_rejection", "Review rejected, coder can try different approach", 1),
    (r"evaluation.*fail|evaluator.*fail|score.*(?:below|too low)|quality.*(?:below|insufficient)", "evaluation_failure", "Evaluation failed, can retry with better approach", 1),
    # New: low completion — might recover with more focused approach
    (r"low.completion|completion.*below.*threshold|completion.*stayed.*below", "low_completion", "Low completion, retriable with focused scope", 1),
    # Fallback reviewer cannot validate — coder may try different approach
    (r"fallback.*reviewer.*cannot.*validate|cannot.*validate.*deterministically|bounded retry guidance", "reviewer_indeterminate", "Reviewer could not validate deterministically, retry with clearer output", 1),
    # Generic coder failure — reported it cannot complete the task
    (r"cannot run|cannot execute|unable to (run|execute|complete|verify)|could not (run|execute|verify)|verification (failed|impossible|not possible)", "coder_blocked", "Coder reported inability to complete step", 1),
    # Step produced no meaningful diff or change — coder didn't act
    (r"no changes|no diff|nothing to commit|working tree clean|no files changed|did not produce", "no_change_produced", "Coder step produced no changes", 1),
    # Model refused or could not follow plan
    (r"i('m| am) (unable|not able|sorry)|as an ai|i cannot|apologi[sz]e|beyond (my|the) (capabilit|scope)|outside.*scope", "model_refusal", "Model refused or declared inability", 1),
    # Compilation or build failure (not environment — tool exists but code is wrong)
    (r"compilation? (error|fail)|build fail|type.*error|cannot find symbol|unresolved reference|linker error|undefined reference", "build_failure", "Compilation/build failure in generated code", 1),
    # Test failure (tests ran but assertions failed)
    (r"assert(ion)?.*fail|test.*fail|expect.*but.*(got|received|was)|mismatch|not equal", "test_failure", "Test assertions failed", 1),
]

for pattern, cat, reason in non_retriable:
    if re.search(pattern, combined):
        print(json.dumps({"retriable": False, "category": cat, "reason": reason}))
        raise SystemExit(0)

for pattern, cat, reason, mult in retriable:
    if re.search(pattern, combined):
        print(json.dumps({"retriable": True, "category": cat, "reason": reason, "backoff_multiplier": mult}))
        raise SystemExit(0)

# Heuristic: if combined text is very short or empty, it's likely an infrastructure issue
# (the error was never captured). Mark as infra_silent.
if len(combined.strip()) < 20:
    cat = "infra_silent" if attempt <= 1 else "infra_silent_persistent"
    print(json.dumps({
        "retriable": attempt <= 1,
        "category": cat,
        "reason": "Failure with no error output — likely infrastructure/timeout before output was captured",
        "backoff_multiplier": 1,
    }))
    raise SystemExit(0)

# After attempt 1, mark unknown as non-retriable sooner to avoid wasting retries
if attempt <= 1:
    # Include a fingerprint of the error to help future classification
    snippet = combined[:200].strip()
    print(json.dumps({"retriable": True, "category": "unknown", "reason": f"Unknown failure allowing one retry. Snippet: {snippet}", "backoff_multiplier": 1}))
else:
    print(json.dumps({"retriable": False, "category": "unknown_persistent", "reason": "Same unknown failure after multiple attempts marking non-retriable"}))
PYCLASSIFY
}

# --- Pre-Execution Environment Check ---
# Detects tasks that require unavailable toolchains (Android SDK, Gradle, iOS, etc.)
# BEFORE spending time on planning and coding.  Returns JSON with blocked=true/false
# and the reason if blocked.  Non-destructive: only inspects the task text and
# available commands.
# Error handling: logs warnings on unexpected failures, never crashes the caller.
check_task_environment_requirements() {
  local task_text="${1:-}"
  local project_name="${2:-}"

  python3 - "$task_text" "$project_name" "$ROOT_DIR" <<'PYENVCHECK'
import json
import os
import re
import shutil
import sys
from pathlib import Path

task_text = " ".join((sys.argv[1] if len(sys.argv) > 1 else "").lower().split())
project_name = sys.argv[2] if len(sys.argv) > 2 else ""
root_dir = sys.argv[3] if len(sys.argv) > 3 else ""

# Resolve project directory for checking local wrapper scripts
project_dirs = []
if root_dir and project_name:
    project_dirs.append(os.path.join(root_dir, "projects", project_name))
if root_dir:
    project_dirs.append(root_dir)

def command_available(cmd, wrappers=None):
    """Check PATH and common project-local locations for a command."""
    if shutil.which(cmd) is not None:
        return True
    for alt in (wrappers or []):
        if shutil.which(alt) is not None:
            return True
        # Check project-local wrappers (e.g. ./gradlew in the project root)
        for pdir in project_dirs:
            candidate = os.path.join(pdir, alt)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return True
    return False

# Also check ANDROID_HOME / JAVA_HOME environment variables
android_env_set = bool(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT"))
java_env_set = bool(os.environ.get("JAVA_HOME"))

# Each rule: (task_text_pattern, required_command, wrappers, blocker_name, reason, extra_env_check)
env_rules = [
    # Android / Gradle
    (r"android|gradle|jetpack|compose.*android|kotlin.*multiplatform.*android|kmp.*android|\.apk|assembledebug",
     "gradle", ["gradlew"],
     "android_environment",
     "Task requires Android SDK/Gradle but neither gradle/gradlew found on PATH or in project, and ANDROID_HOME is not set",
     lambda: android_env_set),
    # iOS / Xcode
    (r"\bios\b|xcode|swift.*ui|cocoapods|\.ipa\b|xcworkspace|xcodeproj",
     "xcodebuild", [],
     "ios_environment",
     "Task requires Xcode/iOS toolchain but xcodebuild is not available",
     lambda: False),
    # Flutter
    (r"\bflutter\b|dart.*flutter",
     "flutter", [],
     "flutter_environment",
     "Task requires Flutter SDK but flutter is not on PATH",
     lambda: False),
    # Docker
    (r"\bdocker\b|dockerfile|docker-compose|container",
     "docker", ["podman"],
     "docker_environment",
     "Task requires Docker but docker/podman is not available",
     lambda: False),
]

blocked = False
reason = ""
blocker = ""
docker_delegate = ""  # non-empty when Docker can satisfy the requirement

# Check whether Docker is available for delegation
docker_available = shutil.which("docker") is not None or shutil.which("podman") is not None

# Map of blocker_name -> docker delegate script (relative to scripts/)
_docker_delegates = {
    "android_environment": "run-gradle-docker.sh",
    "sandbox_gradle":      "run-gradle-docker.sh",
}

# Check for previously known sandbox-blocked task patterns.
# If the same task type has repeatedly failed with sandbox_restriction,
# block it proactively to avoid wasting execution cycles.
# HOWEVER: if Docker is available and we have a delegate script, allow
# the task through and flag it for Docker execution.
sandbox_blocked_keywords = [
    # These patterns match tasks that require running build tools that are
    # consistently blocked by sandbox policies in this environment.
    (r"(run|execute|verify).*gradlew|gradlew.*(build|assemble|compile)|assembledebug|compiledebugkotlin",
     "sandbox_gradle", "Gradle execution is blocked by sandbox security policy in this environment"),
    (r"(run|execute|verify).*xcodebuild|xcodebuild.*(build|test|archive)",
     "sandbox_xcode", "Xcode execution is blocked by sandbox security policy in this environment"),
]

for pattern, blocker_name, msg in sandbox_blocked_keywords:
    if re.search(pattern, task_text):
        if docker_available and blocker_name in _docker_delegates:
            docker_delegate = _docker_delegates[blocker_name]
        else:
            blocked = True
            reason = msg
            blocker = blocker_name
        break

if not blocked and not docker_delegate:
    for pattern, cmd, wrappers, blocker_name, msg, extra_check in env_rules:
        if re.search(pattern, task_text):
            if cmd and not command_available(cmd, wrappers) and not extra_check():
                if docker_available and blocker_name in _docker_delegates:
                    docker_delegate = _docker_delegates[blocker_name]
                else:
                    blocked = True
                    reason = msg
                    blocker = blocker_name
                break

print(json.dumps({"blocked": blocked, "blocker": blocker, "reason": reason, "docker_delegate": docker_delegate}))
PYENVCHECK
}

detect_low_signal_self_improve_task() {
  local task_text="${1:-}"
  local project_name="${2:-}"
  local task_id="${3:-}"
  local registry_file

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$METRICS_FILE" "$task_text" "$project_name" "$task_id" <<'PYLOWSIGNAL'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


registry_path = Path(sys.argv[1])
metrics_path = Path(sys.argv[2])
task_text = str(sys.argv[3] or "")
project_name = str(sys.argv[4] or "")
task_id = str(sys.argv[5] or "")


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def safe_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def task_source(task: dict[str, Any]) -> str:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    source = normalize_text(task_intent.get("source") or task.get("source"))
    if source:
        return source
    combined = normalize_text(task.get("title")) + " " + normalize_text(task.get("execution_task"))
    if "[self-improve:" in combined:
        return "self-improve"
    return ""


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


metrics = read_json(metrics_path)
recent_success_rate = safe_float(metrics.get("recent_success_rate"))
success_rate = safe_float(metrics.get("success_rate"))
pipeline_stale = metrics.get("pipeline_stale") is True
self_improve_paused = metrics.get("self_improve_paused") is True
degraded_state = (
    recent_success_rate <= 0.10
    or success_rate <= 0.15
    or pipeline_stale
    or self_improve_paused
)

matched_task: dict[str, Any] | None = None
project_key = normalize_project(project_name) or "codex-agent-system"
task_key = normalize_text(task_text)
target_task_id = normalize_text(task_id)
tasks = read_json(registry_path).get("tasks")
if isinstance(tasks, list):
    for candidate in tasks:
        if not isinstance(candidate, dict):
            continue
        candidate_project = normalize_project(candidate.get("project") or candidate.get("target_project") or "codex-agent-system")
        if project_key and candidate_project != project_key:
            continue
        if target_task_id and normalize_text(candidate.get("id")) == target_task_id:
            matched_task = candidate
            break
        if not target_task_id and task_key:
            title_key = normalize_text(candidate.get("title"))
            execution_key = normalize_text(candidate.get("execution_task"))
            if task_key == title_key or task_key == execution_key:
                matched_task = candidate
                break

if isinstance(matched_task, dict):
    source = task_source(matched_task)
    combined = normalize_text(
        " ".join(
            [
                str(matched_task.get("title") or ""),
                str(matched_task.get("execution_task") or ""),
                str(matched_task.get("reason") or ""),
                str(matched_task.get("experiment") or ""),
            ]
        )
    )
    matched_task_id = str(matched_task.get("id") or "").strip()
else:
    source = "self-improve" if "[self-improve:" in normalize_text(task_text) else ""
    combined = normalize_text(task_text)
    matched_task_id = ""

blocked = source == "self-improve" and degraded_state and is_comment_or_doc_only(combined)
if blocked:
    reason = (
        "Low-signal self-improve task blocked during degraded execution state: "
        "comment/documentation-only work should not consume recovery capacity "
        f"(recent_success_rate={recent_success_rate:.2f}, pipeline_stale={'true' if pipeline_stale else 'false'}, "
        f"self_improve_paused={'true' if self_improve_paused else 'false'})."
    )
else:
    reason = ""

print(
    json.dumps(
        {
            "blocked": blocked,
            "reason": reason,
            "matched_task_id": matched_task_id,
            "source": source,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
)
PYLOWSIGNAL
}

# --- Exponential Backoff with Jitter ---
# Calculates wait time in seconds using exponential backoff + random jitter.
# Prevents thundering herd on failing services.
calculate_retry_backoff() {
  local attempt="${1:-1}"
  local base_seconds="${2:-5}"
  local max_seconds="${3:-120}"
  local multiplier="${4:-1}"

  python3 -c "
import random, sys
attempt, base, cap = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
mult = float(sys.argv[4])
exp = min(base * (2 ** attempt) * mult, cap)
print(int(exp * random.uniform(0.5, 1.0)))
" "$attempt" "$base_seconds" "$max_seconds" "$multiplier"
}

# --- Post-Execution Guard (Flagging Only) ---
# Flags low-scoring tasks for manual review instead of auto-reverting.
# AGENTS.md compliant: No destructive actions, only flagging.
post_execution_guard() {
  local score="${1:-0}"
  local result="${2:-FAILURE}"
  local task_id="${3:-}"

  [ -n "$task_id" ] || return 0

  # Score under 4 despite SUCCESS → flag for manual review
  if [ "$score" -lt 4 ] && [ "$result" = "SUCCESS" ]; then
    log_msg WARN post-guard "Low score ($score) despite SUCCESS — flagging task $task_id for review"
    if command -v update_task_registry_field >/dev/null 2>&1; then
      update_task_registry_field "$task_id" "needs_manual_review" "true" 2>/dev/null || true
      update_task_registry_field "$task_id" "review_reason" "Low evaluator score: $score" 2>/dev/null || true
    fi
    return 0
  fi

  # Score 4-6 → informational warning only
  if [ "$score" -ge 4 ] && [ "$score" -lt 7 ] && [ "$result" = "SUCCESS" ]; then
    log_msg INFO post-guard "Marginal score ($score) for task $task_id — adding review note"
  fi
}

# --- Settings Hierarchy ---
# Resolves a setting with clear precedence:
# 1. Environment variable (CODEX_<KEY>)
# 2. Project-local settings (settings.local.json, gitignored)
# 3. Project-shared settings (project.json)
# 4. Global settings (dashboard-settings.json)
# 5. Default value
resolve_setting() {
  local key="${1:-}"
  local default_value="${2:-}"
  local project_name="${3:-}"

  [ -n "$key" ] || { printf '%s' "$default_value"; return 0; }

  # 1. Environment variable: CODEX_<UPPER_KEY>
  local env_key
  env_key="CODEX_$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')"
  local env_val="${!env_key:-}"
  if [ -n "$env_val" ]; then
    printf '%s' "$env_val"
    return 0
  fi

  # 2. Project-local settings (not committed)
  if [ -n "$project_name" ]; then
    local local_settings="$PROJECTS_DIR/$project_name/settings.local.json"
    if [ -f "$local_settings" ]; then
      local local_val
      local_val="$(jq -r --arg k "$key" '.[$k] // empty' "$local_settings" 2>/dev/null || true)"
      if [ -n "$local_val" ]; then
        printf '%s' "$local_val"
        return 0
      fi
    fi
  fi

  # 3. Project-shared settings (project.json)
  if [ -n "$project_name" ]; then
    local project_config="$PROJECTS_DIR/$project_name/project.json"
    if [ -f "$project_config" ]; then
      local project_val
      project_val="$(jq -r --arg k "$key" '.[$k] // empty' "$project_config" 2>/dev/null || true)"
      if [ -n "$project_val" ]; then
        printf '%s' "$project_val"
        return 0
      fi
    fi
  fi

  # 4. Global settings (dashboard-settings.json)
  local global_settings="$MEMORY_DIR/dashboard-settings.json"
  if [ -f "$global_settings" ]; then
    local global_val
    global_val="$(jq -r --arg k "$key" '.[$k] // empty' "$global_settings" 2>/dev/null || true)"
    if [ -n "$global_val" ]; then
      printf '%s' "$global_val"
      return 0
    fi
  fi

  # 5. Default
  printf '%s' "$default_value"
}

# --- Context Recovery ---
# Refreshes core context mid-execution to prevent context drift in long pipelines.
# Call this between steps when more than half the pipeline is completed.
refresh_core_context_if_needed() {
  local step_index="${1:-0}"
  local total_steps="${2:-1}"
  local memory_file="${3:-}"
  local project_name="${4:-}"
  local task="${5:-}"

  [ -n "$memory_file" ] || return 0

  # Refresh at the midpoint of execution
  local midpoint=$((total_steps / 2))
  if [ "$step_index" -ge "$midpoint" ] && [ "$step_index" -gt 1 ]; then
    # Re-read memory context into the memory file
    if command -v read_memory_context_with_topics >/dev/null 2>&1; then
      read_memory_context_with_topics "$project_name" "$task" >"$memory_file"
    else
      read_memory_context "$project_name" >"$memory_file"
    fi
    log_msg DEBUG context-recovery "Context refreshed at step $step_index/$total_steps"
  fi
}

build_similar_task_context() {
  local task_text="${1:-}"
  local project_name="${2:-}"
  local task_id="${3:-}"
  local registry_file

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$task_text" "$project_name" "$task_id" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


registry_path = Path(sys.argv[1])
task_text = sys.argv[2]
project_name = sys.argv[3].strip().lower()
target_task_id = sys.argv[4].strip().lower()

stopwords = {
    "a",
    "an",
    "and",
    "are",
    "auf",
    "bei",
    "das",
    "dem",
    "den",
    "der",
    "die",
    "ein",
    "eine",
    "for",
    "im",
    "in",
    "ist",
    "mit",
    "oder",
    "task",
    "the",
    "to",
    "ui",
    "und",
}


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return str(task.get("id") or "").strip()


def tokenize(value: Any) -> set[str]:
    tokens: set[str] = set()
    for token in re.findall(r"[a-z0-9_/-]+", str(value or "").lower()):
        if len(token) < 3 or token in stopwords:
            continue
        tokens.add(token)
    return tokens


def read_tasks() -> list[dict[str, Any]]:
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        return []
    # Performance: only consider the 50 most recent terminal tasks + all active
    all_tasks = [t for t in tasks if isinstance(t, dict)]
    active = [t for t in all_tasks if str(t.get("status", "")).strip().lower() in ("running", "approved", "pending_approval")]
    terminal = sorted(
        [t for t in all_tasks if t not in active],
        key=lambda t: str(t.get("updated_at") or t.get("created_at") or ""),
        reverse=True,
    )[:50]
    return active + terminal


def serialize_task(task: dict[str, Any], *, current_task: bool) -> dict[str, Any]:
    return {
        "id": str(task.get("id") or "").strip(),
        "title": str(task.get("title") or "").strip(),
        "status": str(task.get("status") or "").strip(),
        "strategy_template": str(task.get("strategy_template") or "").strip(),
        "updated_at": str(task.get("updated_at") or "").strip(),
        "created_at": str(task.get("created_at") or "").strip(),
        "current_task": current_task,
        "original_failed_root_id": original_failed_root_id(task),
        "reason": str(task.get("reason") or "").strip(),
        "experiment": str(task.get("experiment") or "").strip(),
        "target_files": task.get("target_files") if isinstance(task.get("target_files"), list) else [],
        "task_intent": task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {},
        "task_shape": task.get("task_shape") if isinstance(task.get("task_shape"), dict) else {},
        "execution_brief": task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {},
        "execution_context": task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {},
        "failure_context": task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {},
    }


def canonical_objective(task: dict[str, Any]) -> str:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {}
    brief_intent = execution_brief.get("task_intent") if isinstance(execution_brief.get("task_intent"), dict) else {}
    return normalize_identifier(
        task_intent.get("objective")
        or brief_intent.get("objective")
        or task.get("title")
        or ""
    )


tasks = read_tasks()
selected_exact: dict[str, Any] | None = None
if target_task_id:
    project_key = normalize_project(project_name)
    for task in tasks:
        task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
        if task_project != project_key:
            continue
        if normalize_identifier(task.get("id")) == target_task_id:
            selected_exact = task
            break

query_tokens = tokenize(task_text)
if not query_tokens and not isinstance(selected_exact, dict):
    print("[]")
    raise SystemExit(0)

selected_root_id = original_failed_root_id(selected_exact) if isinstance(selected_exact, dict) else ""
selected_objective = canonical_objective(selected_exact) if isinstance(selected_exact, dict) else ""
selected_template = str(selected_exact.get("strategy_template") or "").strip() if isinstance(selected_exact, dict) else ""

candidates: list[tuple[int, int, int, int, str, str, dict[str, Any]]] = []
for task in tasks:
    if isinstance(selected_exact, dict) and normalize_identifier(task.get("id")) == normalize_identifier(selected_exact.get("id")):
        continue
    status = str(task.get("status") or "").strip().lower()
    if status not in {"completed", "failed", "approved", "rejected"}:
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if project_name and task_project != project_name:
        continue

    corpus = "\n".join(
        [
            str(task.get("title") or ""),
            str(task.get("reason") or ""),
            str(task.get("hypothesis") or ""),
            str(task.get("experiment") or ""),
            str((task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else ""),
            str((task.get("failure_context") or {}).get("failed_step") if isinstance(task.get("failure_context"), dict) else ""),
        ]
    )
    overlap = query_tokens & tokenize(corpus)
    if not overlap:
        continue

    same_root = 1 if selected_root_id and original_failed_root_id(task) == selected_root_id else 0
    same_objective = 1 if selected_objective and canonical_objective(task) == selected_objective else 0
    same_template = 1 if selected_template and str(task.get("strategy_template") or "").strip() == selected_template else 0

    candidates.append(
        (
            same_root,
            same_objective,
            same_template,
            len(overlap),
            str(task.get("updated_at") or task.get("created_at") or ""),
            str(task.get("id") or ""),
            task,
        )
    )

selected: list[dict[str, Any]] = []
if isinstance(selected_exact, dict):
    selected.append(serialize_task(selected_exact, current_task=True))

remaining_slots = max(0, 1 - len(selected))
for _, _, _, _, _, _, task in sorted(candidates, reverse=True)[:remaining_slots]:
    selected.append(serialize_task(task, current_task=False))

print(json.dumps(selected, indent=2))
PY
}

build_prompt_source_context() {
  local task_text="${1:-}"
  local step_text="${2:-}"
  local project_name="${3:-}"

  python3 - "$ROOT_DIR" "$task_text" "$step_text" "$project_name" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path


root = Path(sys.argv[1])
task_text = sys.argv[2]
step_text = sys.argv[3]
project_name = sys.argv[4].strip()
combined = f"{task_text}\n{step_text}".strip()
combined_lower = combined.lower()

stopwords = {
    "a",
    "an",
    "and",
    "are",
    "bei",
    "das",
    "dem",
    "den",
    "der",
    "die",
    "ein",
    "eine",
    "exact",
    "for",
    "genau",
    "into",
    "ist",
    "mit",
    "oder",
    "return",
    "the",
    "und",
    "with",
}

domain_files = [
    (
        "agent",
        ("agent", "claude", "codex", "planner", "dispatch", "prompt", "model", "reasoning", "reviewer", "evaluator", "orchestrator"),
        ("run_codex_exec(", "cmd=(codex -a on-request)"),
        [
            "agents/planner.sh",
            "agents/coder.sh",
            "agents/reviewer.sh",
            "agents/evaluator.sh",
            "agents/orchestrator.sh",
            "scripts/lib.sh",
        ],
    ),
    (
        "ui",
        ("ui", "dashboard", "layout", "route", "component", "mobile", "scroll", "board", "navigation", "menu"),
        ("renderTaskList", "refreshTaskRegistry", "data-task-filter", "task-board", "scroll"),
        [
            "codex-dashboard/index.html",
            "codex-dashboard/server.js",
            "tests/dashboard-task-visibility.sh",
            "tests/system-smoke.sh",
        ],
    ),
    (
        "registry",
        ("approval", "approved", "pending", "queue", "backlog", "registry", "board"),
        ("createTaskRegistryItem(", "transitionTaskRegistryItem(", "queue_handoff", "pending_approval", "approved"),
        [
            "codex-dashboard/server.js",
            "scripts/lib.sh",
            "tests/task-registry-create.sh",
            "tests/system-smoke.sh",
        ],
    ),
]

selected_files: list[str] = []
focus_tokens: list[str] = []
for _, keywords, anchors, files in domain_files:
    if any(keyword in combined_lower for keyword in keywords):
        for anchor in anchors:
            if anchor.lower() not in focus_tokens:
                focus_tokens.append(anchor.lower())
        for file in files:
            if file not in selected_files:
                selected_files.append(file)

project_files: list[str] = []
if project_name:
    project_root = root / "projects" / project_name
    for relative_file in (
        f"projects/{project_name}/project.json",
        f"projects/{project_name}/spec.md",
        f"projects/{project_name}/policy.json",
        f"projects/{project_name}/sources.json",
    ):
        if (root / relative_file).is_file():
            project_files.append(relative_file)

if not selected_files:
    selected_files = [
        "agents/orchestrator.sh",
        "scripts/lib.sh",
        "codex-dashboard/server.js",
    ]

selected_files = [*project_files, *selected_files]

tokens = []
for raw_token in re.findall(r"[a-zA-Z0-9_/-]+", combined_lower):
    if len(raw_token) < 3 or raw_token in stopwords:
        continue
    if raw_token not in tokens:
        tokens.append(raw_token)

if "codex" in combined_lower and "codex" not in tokens:
    tokens.insert(0, "codex")
if "claude" in combined_lower and "claude" not in tokens:
    tokens.insert(0, "claude")

tokens = (focus_tokens + tokens)[:14]


def slice_ranges(lines: list[str], keywords: list[str], primary_keywords: list[str]) -> list[tuple[int, int]]:
    if not lines:
        return []

    def collect_matches(active_keywords: list[str]) -> list[int]:
        matches: list[int] = []
        for index, line in enumerate(lines):
            lower = line.lower()
            if any(keyword in lower for keyword in active_keywords):
                matches.append(index)
            if len(matches) >= 4:
                break
        return matches

    matches = collect_matches(primary_keywords)
    if not matches:
        matches = collect_matches(keywords)

    if not matches:
        return [(0, min(len(lines), 40))]

    ranges: list[tuple[int, int]] = []
    for match in matches:
        start = max(0, match - 6)
        end = min(len(lines), match + 7)
        if ranges and start <= ranges[-1][1]:
            previous_start, previous_end = ranges[-1]
            ranges[-1] = (previous_start, max(previous_end, end))
        else:
            ranges.append((start, end))
    return ranges[:3]


candidate_files: list[tuple[int, str, list[str]]] = []
for relative_file in selected_files:
    path = root / relative_file
    if not path.is_file():
        continue

    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    haystack = "\n".join(lines).lower()
    score = sum(haystack.count(token) for token in tokens) + len(lines) // 400
    if relative_file.endswith("scripts/lib.sh") and any(token in {"codex", "queue", "approval", "agent"} for token in tokens):
        score += 5
    if project_name and relative_file.startswith(f"projects/{project_name}/"):
        score += 25
    candidate_files.append((score, relative_file, lines))

candidate_files.sort(key=lambda item: (-item[0], item[1]))

sections: list[str] = []
for _, relative_file, lines in candidate_files[:2]:
    ranges = slice_ranges(lines, tokens, focus_tokens)
    snippet_lines: list[str] = []
    for start, end in ranges:
        if snippet_lines:
            snippet_lines.append("...")
        for line_no in range(start, end):
            snippet_lines.append(f"{line_no + 1:>4}: {lines[line_no]}")

    if not snippet_lines:
        continue

    sections.append(
        f"FILE {relative_file}\n"
        "```text\n"
        + "\n".join(snippet_lines[:40])
        + "\n```"
    )

if sections:
    print("\n\n".join(sections))
PY
}

build_verification_guidance() {
  local task_text="${1:-}"
  local step_text="${2:-}"
  local project_name="${3:-}"
  local task_id="${4:-}"
  local combined

  if [ -n "$project_name" ] && [ -n "$task_id" ]; then
    local registry_file exact_guidance
    registry_file="$(task_registry_file_for_project "$project_name")"
    exact_guidance="$(python3 - "$registry_file" "$project_name" "$task_id" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


registry_path = Path(sys.argv[1])
project_name = sys.argv[2].strip().lower()
target_task_id = sys.argv[3].strip().lower()


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


try:
    payload = json.loads(registry_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

tasks = payload.get("tasks")
if not isinstance(tasks, list):
    raise SystemExit(0)

for task in tasks:
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != normalize_project(project_name):
        continue
    if normalize_identifier(task.get("id")) != target_task_id:
        continue
    task_shape = task.get("task_shape") if isinstance(task.get("task_shape"), dict) else {}
    command = str(task_shape.get("verification_command") or "").strip()
    if not command:
        raise SystemExit(0)
    print(
        "\n".join(
            [
                "- Prefer the task-specific verification command captured on the approved task:",
                f"  `{command}`",
                "- Do not replace it with a broader generic verification path unless the task shape is empty.",
            ]
        )
    )
    raise SystemExit(0)
PY
)"
    if [ -n "$exact_guidance" ]; then
      printf '%s\n' "$exact_guidance"
      return 0
    fi
  fi

  combined="$(printf '%s\n%s\n' "$task_text" "$step_text" | tr '[:upper:]' '[:lower:]')"

  if [[ "$combined" == *"dashboard"* ]] || [[ "$combined" == *"iphone"* ]] || [[ "$combined" == *"ipad"* ]] || [[ "$combined" == *"tablet"* ]] || [[ "$combined" == *"playwright"* ]] || [[ "$combined" == *"screenshot"* ]]; then
    cat <<'EOF'
- For dashboard UI or screenshot verification, prefer the containerized Playwright path:
  `bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh`
- If the UI change is intentional and updates the golden screenshots, refresh them explicitly with:
  `UPDATE_DASHBOARD_SCREENSHOT_BASELINES=1 bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh`
- Do not claim dashboard UI verification passed without reporting the exact command outcome.
EOF
    return 0
  fi

  printf '%s\n' "- Use one deterministic verification command with a clear pass/fail result."
}

run_memory_index() {
  log_msg INFO memory "Memory index skipped; using decisions tail context only"
  return 0
}

run_memory_query() {
  local _task="${1:-}"
  read_memory_context
}

sync_task_artifacts() {
  require_command memory python3
  ensure_runtime_dirs
  python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASK_REGISTRY_FILE" "$TASK_LOG" "$METRICS_FILE" "$EXTERNAL_SIGNALS_FILE" >/dev/null
}

sync_legacy_queue_mirror() {
  require_command queue python3
  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$ROOT_DIR/codex-queue" "$QUEUE_DIR" <<'PY'
from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path
from typing import Any
import sys


registry_path = Path(sys.argv[1])
legacy_queue_dir = Path(sys.argv[2])
queue_dir = Path(sys.argv[3])


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_key(value: Any) -> str:
    return normalize_text(value).lower()


def normalize_project(value: Any) -> str:
    text = normalize_key(value)
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", text))


def task_execution_text(task: dict[str, Any]) -> str:
    execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {}
    queue_handoff = task.get("queue_handoff") if isinstance(task.get("queue_handoff"), dict) else {}
    return normalize_text(
        execution_brief.get("queue_task")
        or queue_handoff.get("task")
        or task.get("execution_task")
        or task.get("title")
        or ""
    )


def read_registry_tasks(path: Path) -> list[dict[str, Any]]:
    try:
      payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      return []
    if isinstance(payload, dict):
      tasks = payload.get("tasks")
      return tasks if isinstance(tasks, list) else []
    return payload if isinstance(payload, list) else []


def read_queue_lines(path: Path) -> list[str]:
    if not path.exists():
      return []
    try:
      return [normalize_text(line) for line in path.read_text(encoding="utf-8").splitlines() if normalize_text(line)]
    except Exception:
      return []


def write_queue_lines(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=path.parent, encoding="utf-8") as handle:
      if lines:
        handle.write("\n".join(lines) + "\n")
      temp_path = Path(handle.name)
    temp_path.replace(path)


actionable_by_project: dict[str, dict[str, str]] = {}
actionable_ids_by_project: dict[str, set[str]] = {}
for task in read_registry_tasks(registry_path):
    if not isinstance(task, dict):
        continue
    status = normalize_key(task.get("status"))
    if status != "approved":
        continue
    project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    task_text = task_execution_text(task)
    task_id = normalize_key(task.get("id"))
    if not task_text:
        continue
    actionable_by_project.setdefault(project, {})
    actionable_by_project[project].setdefault(normalize_key(task_text), task_text)
    if task_id:
        actionable_ids_by_project.setdefault(project, set()).add(task_id)

if not legacy_queue_dir.exists():
    raise SystemExit(0)

for legacy_file in sorted(legacy_queue_dir.glob("*.txt")):
    project = normalize_project(legacy_file.stem)
    allowed = actionable_by_project.get(project, {})
    raw_lines = read_queue_lines(legacy_file)

    filtered_lines: list[str] = []
    seen: set[str] = set()
    for line in raw_lines:
        key = normalize_key(line)
        canonical = allowed.get(key)
        if not canonical or key in seen:
            continue
        seen.add(key)
        filtered_lines.append(canonical)

    if filtered_lines != raw_lines:
        write_queue_lines(legacy_file, filtered_lines)
        print(f"pruned\t{project}\t{legacy_file.name}\t{len(raw_lines) - len(filtered_lines)}")

    queue_file = queue_dir / legacy_file.name
    live_lines = read_queue_lines(queue_file)
    if not live_lines and filtered_lines:
        write_queue_lines(queue_file, filtered_lines)
        print(f"copied\t{project}\t{legacy_file.name}\t{len(filtered_lines)}")

for legacy_task_file in sorted(legacy_queue_dir.glob("task-*.json")):
    try:
        payload = json.loads(legacy_task_file.read_text(encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(payload, dict):
        continue

    project = normalize_project(payload.get("project") or payload.get("target_project") or "codex-agent-system")
    task_text = normalize_text(payload.get("task") or payload.get("title") or "")
    task_id = normalize_key(payload.get("id"))

    allowed_tasks = actionable_by_project.get(project, {})
    allowed_ids = actionable_ids_by_project.get(project, set())
    if (task_text and normalize_key(task_text) in allowed_tasks) or (task_id and task_id in allowed_ids):
        continue

    try:
        legacy_task_file.unlink()
    except FileNotFoundError:
        pass
PY
}

refresh_external_signals() {
  require_command strategy python3
  ensure_runtime_dirs
  python3 - "$EXTERNAL_SIGNAL_SOURCES_FILE" <<'PY' >/dev/null || return 0
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(1)

raise SystemExit(0 if payload.get("auto_refresh") is True else 1)
PY
  bash "$ROOT_DIR/scripts/run-research-docker.sh" \
    python3 "$ROOT_DIR/scripts/external_signals.py" "$EXTERNAL_SIGNAL_SOURCES_FILE" "$EXTERNAL_SIGNALS_FILE" >/dev/null
}

shared_codex_home() {
  printf '%s\n' "${CODEX_SHARED_HOME:-$HOME/.codex}"
}

shared_codex_auth_file() {
  printf '%s/auth.json\n' "$(shared_codex_home)"
}

runtime_codex_auth_file() {
  printf '%s/auth.json\n' "$CODEX_RUNTIME_HOME"
}

sync_codex_runtime_auth() {
  local source_auth_file runtime_auth_file
  source_auth_file="$(shared_codex_auth_file)"
  runtime_auth_file="$(runtime_codex_auth_file)"

  [ -f "$source_auth_file" ] || return 1

  ensure_runtime_dirs
  if [ -f "$runtime_auth_file" ] && cmp -s "$source_auth_file" "$runtime_auth_file"; then
    chmod 600 "$runtime_auth_file" 2>/dev/null || true
    return 0
  fi

  cp "$source_auth_file" "$runtime_auth_file"
  chmod 600 "$runtime_auth_file"
  log_msg INFO auth "Synced Codex auth into runtime home"
}

codex_auth_failure_file() {
  printf '%s/codex-auth-failure.json\n' "$LOG_DIR"
}

read_codex_auth_failure_reason() {
  local failure_file="$1"
  [ -f "$failure_file" ] || return 1

  python3 - "$failure_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    payload = {}

reason = str(payload.get("reason") or "").strip()
if reason:
    print(reason)
PY
}

codex_auth_failure_cooldown_active() {
  local failure_file="$1"

  python3 - "$failure_file" "${CODEX_AUTH_FAILURE_COOLDOWN_SECONDS:-900}" <<'PY'
import os
import sys
import time

path = sys.argv[1]
try:
    cooldown_seconds = max(0, int(sys.argv[2] or "0"))
except ValueError:
    cooldown_seconds = 0

if cooldown_seconds <= 0 or not os.path.exists(path):
    print("0")
    raise SystemExit(0)

age_seconds = time.time() - os.path.getmtime(path)
print("1" if age_seconds < cooldown_seconds else "0")
PY
}

write_codex_auth_failure_state() {
  local failure_file="$1"
  local reason="$2"

  python3 - "$failure_file" "$reason" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, reason = sys.argv[1:]
payload = {
    "detected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "reason": reason,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

extract_codex_auth_failure_reason() {
  local raw_log_file="$1"
  [ -f "$raw_log_file" ] || return 1

  python3 - "$raw_log_file" <<'PY'
import re
import sys

path = sys.argv[1]
patterns = (
    r"401 Unauthorized.*",
    r"Missing bearer or basic authentication in header.*",
    r"missing api key.*",
    r"authentication .* failed.*",
)

with open(path, "r", encoding="utf-8", errors="ignore") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        lower = line.lower()
        for pattern in patterns:
            if re.search(pattern, line, re.IGNORECASE):
                print(line)
                raise SystemExit(0)
        if "unauthorized" in lower and "auth" in lower:
            print(line)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

codex_auth_reason_is_missing_credentials() {
  local reason="${1:-}"
  case "$reason" in
    *"Missing bearer or basic authentication in header"*|*"401 Unauthorized"*|*"Not logged in"*)
      return 0
      ;;
  esac
  return 1
}

recover_codex_runtime_auth_if_available() {
  local failure_file="$1"
  local reason="${2:-}"

  codex_auth_reason_is_missing_credentials "$reason" || return 1
  sync_codex_runtime_auth || return 1
  rm -f "$failure_file"
  return 0
}

agent_exec_timeout_seconds() {
  local raw_timeout="${AGENT_EXEC_TIMEOUT_SECONDS:-420}"
  case "$raw_timeout" in
    ''|*[!0-9]*)
      printf '120\n'
      ;;
    *)
      if [ "$raw_timeout" -lt 1 ]; then
        printf '1\n'
      else
        printf '%s\n' "$raw_timeout"
      fi
      ;;
  esac
}

codex_approval_mode() {
  printf 'on-request\n'
}

run_codex_exec() {
  local role="$1"
  local project_dir="$2"
  local prompt="$3"
  local output_file="$4"

  if [ "${CODEX_DISABLE:-0}" = "1" ]; then
    log_msg WARN "$role" "CODEX_DISABLE=1 set; using fallback logic"
    return 1
  fi

  if ! command -v codex >/dev/null 2>&1; then
    mark_provider_unavailable "codex" "codex CLI is not installed or not on PATH."
    log_msg WARN "$role" "codex CLI not available; using fallback logic"
    return 1
  fi

  ensure_runtime_dirs
  mkdir -p "$(dirname "$output_file")"
  local raw_log_file auth_failure_file auth_failure_reason exec_timeout runtime_home
  raw_log_file="${output_file}.codex.log"
  auth_failure_file="$(codex_auth_failure_file)"
  exec_timeout="$(agent_exec_timeout_seconds)"
  runtime_home="$(runtime_user_home)"

  if [ "$(codex_auth_failure_cooldown_active "$auth_failure_file")" = "1" ]; then
    auth_failure_reason="$(read_codex_auth_failure_reason "$auth_failure_file" || true)"
    if recover_codex_runtime_auth_if_available "$auth_failure_file" "$auth_failure_reason"; then
      log_msg INFO "$role" "Recovered Codex runtime auth from shared home; resuming live codex calls"
      auth_failure_reason=""
    fi
  fi

  if [ "$(codex_auth_failure_cooldown_active "$auth_failure_file")" = "1" ]; then
    auth_failure_reason="${auth_failure_reason:-$(read_codex_auth_failure_reason "$auth_failure_file" || true)}"
    mark_provider_unavailable "codex" "${auth_failure_reason:-Codex authentication is currently unavailable.}"
    log_msg WARN "$role" "Skipping codex exec because an authentication failure was detected recently${auth_failure_reason:+: $auth_failure_reason}"
    return 1
  fi

  sync_codex_runtime_auth >/dev/null 2>&1 || true
  rm -f "$auth_failure_file"

  local -a cmd
  cmd=(codex -a "$(codex_approval_mode)")
  if [ -n "${CODEX_MODEL:-}" ]; then
    cmd+=(-m "$CODEX_MODEL")
  fi
  cmd+=(exec --skip-git-repo-check --ephemeral --color never -C "$project_dir" --add-dir "$ROOT_DIR" -s workspace-write -o "$output_file" "$prompt")

  log_msg INFO "$role" "Calling codex exec in $(relative_path "$project_dir" "$ROOT_DIR")"
  : >"$raw_log_file"
  if HOME="$runtime_home" \
    CODEX_HOME="$CODEX_RUNTIME_HOME" \
    XDG_CONFIG_HOME="$runtime_home/.config" \
    XDG_CACHE_HOME="$runtime_home/.cache" \
    XDG_DATA_HOME="$runtime_home/.local/share" \
    python3 "$ROOT_DIR/scripts/run-with-timeout.py" "$exec_timeout" "${cmd[@]}" >"$raw_log_file" 2>&1 && [ -s "$output_file" ]; then
    if [ -s "$raw_log_file" ]; then
      log_msg INFO "$role" "codex exec completed successfully; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
    else
      rm -f "$raw_log_file"
      log_msg INFO "$role" "codex exec completed successfully"
    fi
    return 0
  fi

  auth_failure_reason="$(extract_codex_auth_failure_reason "$raw_log_file" || true)"
  if [ -n "$auth_failure_reason" ]; then
    write_codex_auth_failure_state "$auth_failure_file" "$auth_failure_reason"
    mark_provider_unavailable "codex" "$auth_failure_reason"
    log_msg WARN "$role" "Detected codex authentication failure; live codex calls will be skipped for ${CODEX_AUTH_FAILURE_COOLDOWN_SECONDS:-900}s"
  elif grep -q '^TIMEOUT after ' "$raw_log_file" 2>/dev/null; then
    log_msg WARN "$role" "codex exec timed out after ${exec_timeout}s; using fallback logic"
  fi

  log_msg WARN "$role" "codex exec failed or produced no output; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
  return 1
}

run_claude_exec() {
  local role="$1"
  local project_dir="$2"
  local prompt="$3"
  local output_file="$4"

  if [ "${CLAUDE_DISABLE:-0}" = "1" ]; then
    log_msg WARN "$role" "CLAUDE_DISABLE=1 set; skipping Claude execution"
    return 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    mark_provider_unavailable "claude" "claude CLI is not installed or not on PATH."
    log_msg WARN "$role" "claude CLI not available; skipping Claude execution"
    return 1
  fi

  ensure_runtime_dirs
  mkdir -p "$(dirname "$output_file")"
  local raw_log_file schema auth_failure_reason exec_timeout runtime_home
  raw_log_file="${output_file}.claude.log"
  schema="$(agent_json_schema)"
  exec_timeout="$(agent_exec_timeout_seconds)"
  runtime_home="$(runtime_user_home)"

  log_msg INFO "$role" "Calling claude print mode in $(relative_path "$project_dir" "$ROOT_DIR")"
  : >"$raw_log_file"
  # Use the real user HOME for claude CLI auth (runtime_home has stale tokens);
  # keep CODEX_HOME pointed at runtime_home so codex-agent state stays isolated.
  if CODEX_HOME="$runtime_home" \
    python3 "$ROOT_DIR/scripts/run-with-timeout.py" "$exec_timeout" claude -p \
    --output-format json \
    --permission-mode acceptEdits \
    --no-session-persistence \
    --add-dir "$project_dir" \
    --add-dir "$ROOT_DIR" \
    --json-schema "$schema" \
    "$prompt" >"$raw_log_file" 2>&1 && jq -e '.structured_output | type == "object"' "$raw_log_file" > /dev/null 2>&1; then
    jq -c '.structured_output' "$raw_log_file" >"$output_file"
    if [ -s "$raw_log_file" ]; then
      log_msg INFO "$role" "claude print completed successfully; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
    else
      rm -f "$raw_log_file"
      log_msg INFO "$role" "claude print completed successfully"
    fi
    return 0
  fi

  auth_failure_reason="$(extract_claude_auth_failure_reason "$raw_log_file" || true)"
  if [ -n "$auth_failure_reason" ]; then
    mark_provider_unavailable "claude" "$auth_failure_reason"
  elif grep -q '^TIMEOUT after ' "$raw_log_file" 2>/dev/null; then
    log_msg WARN "$role" "claude print timed out after ${exec_timeout}s; skipping Claude execution"
  fi

  log_msg WARN "$role" "claude print failed or produced no output; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
  return 1
}

run_agent_exec() {
  local role="$1"
  local project_dir="$2"
  local task="$3"
  local prompt="$4"
  local output_file="$5"
  local provider_info provider provider_reason provider_source project_name metadata_fatal

  provider_exec_reset_state
  clear_agent_exec_metadata "$output_file"
  project_name="$(basename "$project_dir")"
  provider_info="$(resolve_task_provider_info "$project_name" "$task")"
  provider="$(printf '%s\n' "$provider_info" | sed -n '1p')"
  provider_reason="$(printf '%s\n' "$provider_info" | sed -n '2p')"
  provider_source="$(printf '%s\n' "$provider_info" | sed -n '3p')"
  provider="$(normalize_provider_name "$provider")"
  [ -n "$provider" ] || provider="codex"

  AGENT_EXEC_PROVIDER="$provider"
  AGENT_EXEC_PROVIDER_REASON="${provider_reason:-Selected provider for task execution.}"
  log_msg INFO "$role" "Selected provider=$provider for task dispatch (${provider_source:-default}): ${AGENT_EXEC_PROVIDER_REASON}"

  # Try primary provider, then automatically failover to the other
  local primary_result=0
  case "$provider" in
    claude) run_claude_exec "$role" "$project_dir" "$prompt" "$output_file" || primary_result=$? ;;
    *) run_codex_exec "$role" "$project_dir" "$prompt" "$output_file" || primary_result=$? ;;
  esac

  if [ "$primary_result" -eq 0 ]; then
    write_agent_exec_metadata "$output_file" "$provider" "$provider" "false" "$AGENT_EXEC_PROVIDER_REASON"
    return 0
  fi

  # Automatic failover: try the other provider
  local fallback_provider
  case "$provider" in
    claude) fallback_provider="codex" ;;
    *) fallback_provider="claude" ;;
  esac

  log_msg WARN "$role" "Primary provider $provider failed (exit=$primary_result); attempting failover to $fallback_provider"
  AGENT_EXEC_PROVIDER="$fallback_provider"

  local fallback_result=0
  case "$fallback_provider" in
    claude) run_claude_exec "$role" "$project_dir" "$prompt" "$output_file" || fallback_result=$? ;;
    *) run_codex_exec "$role" "$project_dir" "$prompt" "$output_file" || fallback_result=$? ;;
  esac

  metadata_fatal="false"
  if provider_exec_requires_abort; then
    metadata_fatal="true"
  fi
  write_agent_exec_metadata "$output_file" "$AGENT_EXEC_PROVIDER" "$provider" "$metadata_fatal" "$AGENT_EXEC_PROVIDER_REASON"
  return "$fallback_result"
}

resolve_task_retry_state() {
  local project_name="$1"
  local queue_task="$2"
  local registry_file

  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


path, project_name, queue_task = sys.argv[1:]


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def safe_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def read_tasks(file_path: str) -> list[dict[str, Any]]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []

    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return [task for task in tasks if isinstance(task, dict)] if isinstance(tasks, list) else []


project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
status_rank = {
    "running": 6,
    "approved": 5,
    "failed": 4,
    "completed": 3,
    "rejected": 2,
    "pending_approval": 1,
}
selected: dict[str, Any] | None = None
selected_rank: tuple[int, str, str, str] | None = None

for task in read_tasks(path):
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue

    rank = (
        status_rank.get(str(task.get("status") or "").strip().lower(), 0),
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        str(task.get("id") or ""),
    )
    if selected_rank is None or rank > selected_rank:
        selected = task
        selected_rank = rank

selected_id = ""
attempt = 0
cumulative_attempts = 0
if isinstance(selected, dict):
    selected_id = str(selected.get("id") or "").strip()
    execution = selected.get("execution") if isinstance(selected.get("execution"), dict) else {}
    attempt = max(safe_int(execution.get("attempt")), 0)
    # cumulative_attempts tracks total attempts across re-approval cycles
    # to prevent infinite retry churn via repeated re-approvals
    cumulative_attempts = max(
        safe_int(selected.get("cumulative_attempts")),
        safe_int(execution.get("attempt")),
        0,
    )

if selected_id:
    retry_identity = f"task-id::{project_key}::{selected_id}"
else:
    retry_identity = f"task-text::{project_key}::{queue_task}"

legacy_identity = f"{project_name}::{queue_task}"
print(retry_identity)
print(attempt)
print(legacy_identity)
print(cumulative_attempts)
PY
}

task_retry_key_from_identity() {
  printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
}

task_retry_key() {
  local resolution retry_identity
  resolution="$(resolve_task_retry_state "$1" "$2")"
  retry_identity="$(printf '%s\n' "$resolution" | sed -n '1p')"
  printf '%s\n' "$(task_retry_key_from_identity "${retry_identity:-task-text::$1::$2}")"
}

task_retry_file() {
  local resolution retry_identity retry_key
  resolution="$(resolve_task_retry_state "$1" "$2")"
  retry_identity="$(printf '%s\n' "$resolution" | sed -n '1p')"
  retry_key="$(task_retry_key_from_identity "${retry_identity:-task-text::$1::$2}")"
  printf '%s/%s.retry\n' "$QUEUE_RETRY_DIR" "$retry_key"
}

task_retry_legacy_hashed_file() {
  local resolution legacy_identity legacy_key
  resolution="$(resolve_task_retry_state "$1" "$2")"
  legacy_identity="$(printf '%s\n' "$resolution" | sed -n '3p')"
  legacy_key="$(task_retry_key_from_identity "${legacy_identity:-$1::$2}")"
  printf '%s/%s.retry\n' "$QUEUE_RETRY_DIR" "$legacy_key"
}

get_task_retry_count() {
  local resolution retry_file fallback_attempt cumulative_attempts file_count effective_count
  resolution="$(resolve_task_retry_state "$1" "$2")"
  retry_file="$(task_retry_file "$1" "$2")"
  fallback_attempt="$(printf '%s\n' "$resolution" | sed -n '2p')"
  # cumulative_attempts is the 4th line — tracks total attempts across re-approval cycles
  cumulative_attempts="$(printf '%s\n' "$resolution" | sed -n '4p')"
  cumulative_attempts="${cumulative_attempts:-0}"
  if [ -f "$retry_file" ]; then
    file_count="$(cat "$retry_file")"
  else
    file_count="${fallback_attempt:-0}"
  fi
  # Use the higher of file-based retry count and cumulative_attempts
  # to prevent infinite retry churn via repeated re-approvals
  if [ "$cumulative_attempts" -gt "$file_count" ] 2>/dev/null; then
    effective_count="$cumulative_attempts"
  else
    effective_count="$file_count"
  fi
  printf '%s\n' "$effective_count"
}

set_task_retry_count() {
  local retry_file legacy_retry_file
  retry_file="$(task_retry_file "$1" "$2")"
  legacy_retry_file="$(task_retry_legacy_hashed_file "$1" "$2")"
  printf '%s\n' "$3" >"$retry_file"
  if [ "$legacy_retry_file" != "$retry_file" ]; then
    rm -f "$legacy_retry_file"
  fi
}

clear_task_retry_count() {
  local retry_file legacy_retry_file
  retry_file="$(task_retry_file "$1" "$2")"
  legacy_retry_file="$(task_retry_legacy_hashed_file "$1" "$2")"
  rm -f "$retry_file"
  if [ "$legacy_retry_file" != "$retry_file" ]; then
    rm -f "$legacy_retry_file"
  fi
}

sync_task_registry_execution_state() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local next_status="${3:-}"
  local action="${4:-execution_update}"
  local note="${5:-}"
  local attempt="${6:-0}"
  local max_retries="${7:-$MAX_AGENT_RETRIES}"
  local provider="${8:-}"
  local lane="${9:-}"
  local current_step_text="${10:-}"
  local current_step_index="${11:-0}"
  local task_id="${12:-}"
  local failure_kind="${13:-}"
  local registry_file

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0
  [ -n "$next_status" ] || return 0

  ensure_runtime_dirs
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$next_status" "$action" "$note" "$attempt" "$max_retries" "$provider" "$lane" "$current_step_text" "$current_step_index" "$task_id" "$failure_kind" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from typing import Any


args = sys.argv[1:]
path, project_name, queue_task, next_status, action, note, attempt, max_retries, provider, lane = args[:10]
current_step_text = args[10] if len(args) > 10 else ""
current_step_index_raw = args[11] if len(args) > 11 else "0"
target_task_id = str(args[12] if len(args) > 12 else "").strip()
explicit_failure_kind = str(args[13] if len(args) > 13 else "").strip()
try:
    current_step_index = int(current_step_index_raw)
except (ValueError, TypeError):
    current_step_index = 0


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_text(value: Any) -> str:
    return str(value or "").strip()


def normalize_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def normalize_failure_kind(value: Any) -> str:
    return re.sub(r"\s+", "_", str(value or "").strip().lower())


def first_non_empty_text(*values: Any) -> str:
    for value in values:
        candidate = normalize_text(value)
        if candidate:
            return candidate
    return ""


def build_failed_execution_context(task: dict[str, Any]) -> dict[str, Any]:
    existing_execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    existing_failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    repaired_execution_context = dict(existing_execution_context)

    run_id = first_non_empty_text(
        repaired_execution_context.get("run_id"),
        existing_failure_context.get("run_id"),
        execution.get("run_id"),
    )
    if run_id:
        repaired_execution_context["run_id"] = run_id

    provider_text = first_non_empty_text(
        provider,
        execution.get("provider"),
        repaired_execution_context.get("provider"),
        existing_failure_context.get("provider"),
        task.get("execution_provider"),
    )
    if provider_text:
        repaired_execution_context["provider"] = provider_text

    repaired_execution_context["result"] = "FAILURE"
    repaired_execution_context["attempts"] = max(
        attempt_count,
        normalize_int(repaired_execution_context.get("attempts")),
        normalize_int(existing_failure_context.get("attempts")),
        normalize_int(execution.get("attempt")),
    )
    repaired_execution_context["failed_step_index"] = max(
        current_step_index,
        normalize_int(repaired_execution_context.get("failed_step_index")),
        normalize_int(existing_failure_context.get("failed_step_index")),
    )
    repaired_execution_context["failed_step"] = first_non_empty_text(
        current_step_text,
        repaired_execution_context.get("failed_step"),
        existing_failure_context.get("failed_step"),
        note,
    )
    repaired_execution_context["updated_at"] = transition_at

    task_identifier = first_non_empty_text(
        task.get("id"),
        target_task_id,
        repaired_execution_context.get("task_id"),
        existing_failure_context.get("task_id"),
    )
    if task_identifier:
        repaired_execution_context["task_id"] = task_identifier

    failed_root_id = first_non_empty_text(
        task.get("original_failed_root_id"),
        repaired_execution_context.get("original_failed_root_id"),
        existing_failure_context.get("original_failed_root_id"),
        original_failed_root_id(task),
    )
    if failed_root_id:
        repaired_execution_context["original_failed_root_id"] = failed_root_id

    failure_kind_value = first_non_empty_text(
        normalize_failure_kind(explicit_failure_kind),
        normalize_failure_kind(execution.get("failure_kind")),
        normalize_failure_kind(repaired_execution_context.get("failure_kind")),
        normalize_failure_kind(existing_failure_context.get("failure_kind")),
        normalize_failure_kind(task.get("last_failure_kind")),
    )
    if failure_kind_value:
        repaired_execution_context["failure_kind"] = failure_kind_value

    return repaired_execution_context


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


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return str(task.get("id") or "").strip()


def read_payload(file_path: str) -> dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return {"tasks": []}


def write_payload(file_path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(file_path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, file_path)


payload = read_payload(path)
tasks = payload.get("tasks")
if not isinstance(tasks, list):
    tasks = []
    payload["tasks"] = tasks

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
target_task_key = normalize_identifier(target_task_id)

status_preference = {
    "running": {"running": 4, "approved": 3, "pending_approval": 2},
    "approved": {"running": 4, "approved": 3},
    "completed": {"running": 4, "approved": 3},
    "failed": {"running": 4, "approved": 3},
}.get(next_status, {})

selected_index: int | None = None
selected_rank: tuple[int, str, str, int] | None = None

for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue

    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue

    if target_task_key and normalize_identifier(task.get("id")) == target_task_key:
        selected_index = index
        selected_rank = None
        break

    if normalize_task(task_execution_text(task)) != task_key:
        continue

    current_status = str(task.get("status") or "pending_approval").strip().lower()
    status_rank = status_preference.get(current_status, 0)
    if status_rank <= 0:
        continue

    rank = (
        status_rank,
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected_index = index

if selected_index is None:
    raise SystemExit(0)

task = dict(tasks[selected_index])
transition_at = now_utc()
from_status = str(task.get("status") or "pending_approval").strip().lower()
attempt_count = int(attempt or 0)
max_retry_count = 2
will_retry = next_status == "approved" and attempt_count < max_retry_count
existing_failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}

execution = task.get("execution")
if not isinstance(execution, dict):
    execution = {}

# Preserve cumulative_attempts across re-approval cycles
# This prevents infinite retry loops when tasks are manually re-approved
cumulative_attempts_prior = max(
    int(task.get("cumulative_attempts") or 0),
    int(execution.get("attempt") or 0),
    0
)

# When transitioning to "approved" or incrementing attempts, update cumulative_attempts
cumulative_attempts_next = cumulative_attempts_prior
if next_status in {"approved", "failed"} or action in {"execute_retry", "execute_failure"}:
    # Increment cumulative_attempts when we're tracking a retry or re-approval
    cumulative_attempts_next = max(cumulative_attempts_prior, attempt_count)

execution_state = next_status
if will_retry and action == "execute_retry":
    execution_state = "retrying"

execution.update(
    {
        "state": execution_state,
        "attempt": attempt_count,
        "max_retries": max_retry_count,
        "provider": str(provider or task.get("execution_provider") or execution.get("provider") or "").strip(),
        "lane": str(lane or execution.get("lane") or "").strip(),
        "result": "SUCCESS" if next_status == "completed" else ("FAILURE" if next_status in {"approved", "failed"} else "RUNNING"),
        "updated_at": transition_at,
        "will_retry": will_retry,
        "current_step": current_step_text,
        "current_step_index": current_step_index,
    }
)
if str(task.get("id") or "").strip():
    execution["task_id"] = str(task.get("id") or "").strip()

if next_status == "failed":
    resolved_failure_kind = first_non_empty_text(
        normalize_failure_kind(explicit_failure_kind),
        normalize_failure_kind(execution.get("failure_kind")),
        normalize_failure_kind(existing_failure_context.get("failure_kind")),
        normalize_failure_kind(task.get("last_failure_kind")),
    )
    if resolved_failure_kind:
        execution["failure_kind"] = resolved_failure_kind

lease_ttl = 310
if next_status == "running":
    lane_label = str(lane or execution.get("lane") or "default").strip()
    lease_id = f"{lane_label}-{transition_at}"
    execution["lease_id"] = lease_id
    execution["lease_ttl_seconds"] = lease_ttl
    lease_dt = datetime.now(timezone.utc)
    execution["lease_expires_at"] = (lease_dt + timedelta(seconds=lease_ttl)).strftime("%Y-%m-%dT%H:%M:%SZ")
    execution["lease_state"] = "claimed"
    execution["lease_claimed_at"] = transition_at
elif next_status in {"approved", "completed", "failed"}:
    execution["lease_state"] = "released"
    execution["lease_released_at"] = transition_at

task["project"] = project_name
task["status"] = next_status
task["updated_at"] = transition_at
task["execution"] = execution
# Preserve cumulative_attempts across re-approval cycles to prevent infinite retries
task["cumulative_attempts"] = cumulative_attempts_next

if next_status == "failed":
    failure_execution_context = build_failed_execution_context(task)
    task["execution_context"] = failure_execution_context
    failure_context = {
        "run_id": first_non_empty_text(
            existing_failure_context.get("run_id"),
            failure_execution_context.get("run_id"),
            execution.get("run_id"),
        ),
        "attempts": max(
            attempt_count,
            normalize_int(failure_execution_context.get("attempts")),
            int(existing_failure_context.get("attempts") or 0),
            int(execution.get("attempt") or 0),
        ),
        "failed_step_index": max(
            current_step_index,
            normalize_int(failure_execution_context.get("failed_step_index")),
            int(existing_failure_context.get("failed_step_index") or 0),
        ),
        "failed_step": first_non_empty_text(
            failure_execution_context.get("failed_step"),
            existing_failure_context.get("failed_step"),
        ),
        "timestamp": first_non_empty_text(
            existing_failure_context.get("timestamp"),
            transition_at,
        ),
    }
    provider_text = first_non_empty_text(
        provider,
        failure_execution_context.get("provider"),
        execution.get("provider"),
        existing_failure_context.get("provider"),
        task.get("execution_provider"),
    )
    if provider_text:
        failure_context["provider"] = provider_text
    task_identifier = first_non_empty_text(
        task.get("id"),
        target_task_id,
        failure_execution_context.get("task_id"),
        existing_failure_context.get("task_id"),
    )
    if task_identifier:
        failure_context["task_id"] = task_identifier
    failed_root_id = first_non_empty_text(
        task.get("original_failed_root_id"),
        failure_execution_context.get("original_failed_root_id"),
        existing_failure_context.get("original_failed_root_id"),
        original_failed_root_id(task),
    )
    if failed_root_id:
        failure_context["original_failed_root_id"] = failed_root_id
    failure_kind_value = first_non_empty_text(
        normalize_failure_kind(failure_execution_context.get("failure_kind")),
        execution.get("failure_kind"),
        existing_failure_context.get("failure_kind"),
        task.get("last_failure_kind"),
    )
    if failure_kind_value:
        failure_context["failure_kind"] = failure_kind_value
        task["last_failure_kind"] = failure_kind_value
    task["failure_context"] = failure_context

if next_status == "running":
    task.setdefault("started_at", transition_at)
    task["last_started_at"] = transition_at
elif next_status == "approved":
    task["last_retry_at"] = transition_at
elif next_status == "completed":
    task["completed_at"] = transition_at
elif next_status == "failed":
    task["failed_at"] = transition_at

history = task.get("history")
if not isinstance(history, list):
    history = []

history.append(
    {
        "at": transition_at,
        "action": action,
        "from_status": from_status,
        "to_status": next_status,
        "project": project_name,
        "queue_task": queue_task,
        "note": note,
        "lane": str(lane or "").strip(),
    }
)
task["history"] = history[-20:]

tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
PY
}

claim_task_lease() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local lane="${3:-}"
  local lease_ttl="${4:-310}"
  local registry_file

  [ -n "$project_name" ] || return 1
  [ -n "$queue_task" ] || return 1
  [ -n "$lane" ] || return 1

  ensure_runtime_dirs
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$lane" "$lease_ttl" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from typing import Any

path, project_name, queue_task, lane, lease_ttl_str = sys.argv[1:]
lease_ttl = int(lease_ttl_str or 310)


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


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


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return str(task.get("id") or "").strip()


def read_payload(file_path: str) -> dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return {"tasks": []}


def write_payload(file_path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(file_path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, file_path)


payload = read_payload(path)
tasks = payload.get("tasks")
if not isinstance(tasks, list):
    tasks = []
    payload["tasks"] = tasks

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
now = datetime.now(timezone.utc)
now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")

selected_index: int | None = None
selected_rank: tuple[int, str, str, int] | None = None
for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    current_status = str(task.get("status") or "").strip().lower()
    if current_status not in {"queued", "approved", "running"}:
        continue
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    rank = (
        3 if current_status == "running" else (2 if current_status == "approved" else 1),
        str(task.get("updated_at") or execution.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_index = index
        selected_rank = rank

if selected_index is None:
    print("claim_task_lease: task not found", file=sys.stderr)
    raise SystemExit(1)

task = dict(tasks[selected_index])
execution = task.get("execution")
if not isinstance(execution, dict):
    execution = {}

# Check for an existing active lease held by a different lane
existing_state = str(execution.get("lease_state") or "").strip().lower()
existing_lane = str(execution.get("lane") or "").strip()
existing_expires = str(execution.get("lease_expires_at") or "").strip()

if existing_state == "claimed" and existing_lane and existing_lane != lane:
    # Check if the existing lease has expired
    if existing_expires:
        try:
            expires_dt = datetime.strptime(existing_expires, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            if expires_dt > now:
                print(f"claim_task_lease: active lease held by lane {existing_lane} until {existing_expires}", file=sys.stderr)
                raise SystemExit(1)
        except ValueError:
            pass

# Write the lease
lease_id = f"{lane}-{now_str}"
expires_at = (now + timedelta(seconds=lease_ttl)).strftime("%Y-%m-%dT%H:%M:%SZ")

execution["lease_id"] = lease_id
execution["lease_state"] = "claimed"
execution["lease_ttl_seconds"] = lease_ttl
execution["lease_expires_at"] = expires_at
execution["lease_claimed_at"] = now_str
execution["lane"] = lane
execution["updated_at"] = now_str
if str(task.get("id") or "").strip():
    execution["task_id"] = str(task.get("id") or "").strip()

task["execution"] = execution
task["updated_at"] = now_str
tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
print(
    json.dumps(
        {
            "lease_id": lease_id,
            "lane": lane,
            "expires_at": expires_at,
            "task_id": str(task.get("id") or "").strip(),
        }
    )
)
PY
}

queue_task_has_active_lease() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local registry_file

  [ -n "$project_name" ] || return 1
  [ -n "$queue_task" ] || return 1

  ensure_runtime_dirs
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from typing import Any

path, project_name, queue_task = sys.argv[1:]


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


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


def parse_utc(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def read_payload(file_path: str) -> dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return {"tasks": []}


payload = read_payload(path)
tasks = payload.get("tasks") if isinstance(payload.get("tasks"), list) else []
project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
now = datetime.now(timezone.utc)

for task in tasks:
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    status = str(task.get("status") or "").strip().lower()
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    lease_state = str(execution.get("lease_state") or "").strip().lower()
    lease_expires_at = parse_utc(execution.get("lease_expires_at"))
    execution_state = str(execution.get("state") or "").strip().lower()
    if lease_state != "claimed" or lease_expires_at is None or lease_expires_at <= now:
        continue
    if status == "running" or execution_state in {"running", "retrying"}:
        raise SystemExit(0)

raise SystemExit(1)
PY
}

release_task_lease() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local lane="${3:-}"
  local task_id="${4:-}"
  local registry_file

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0

  ensure_runtime_dirs
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$lane" "$task_id" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any

path, project_name, queue_task, lane, target_task_id = sys.argv[1:]


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


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


def read_payload(file_path: str) -> dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return {"tasks": []}


def write_payload(file_path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(file_path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, file_path)


payload = read_payload(path)
tasks = payload.get("tasks")
if not isinstance(tasks, list):
    tasks = []
    payload["tasks"] = tasks

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
target_task_key = normalize_identifier(target_task_id)
now_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

selected_index: int | None = None
selected_rank: tuple[int, str, str, int] | None = None
for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if target_task_key and normalize_identifier(task.get("id")) == target_task_key:
        selected_index = index
        selected_rank = None
        break
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    current_status = str(task.get("status") or "").strip().lower()
    if current_status not in {"approved", "running"}:
        continue
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    rank = (
        2 if current_status == "running" else 1,
        str(task.get("updated_at") or execution.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_index = index
        selected_rank = rank

if selected_index is None:
    # Task not found — nothing to release
    raise SystemExit(0)

task = dict(tasks[selected_index])
execution = task.get("execution")
if not isinstance(execution, dict):
    execution = {}

execution["lease_state"] = "released"
execution["lease_released_at"] = now_str
execution["updated_at"] = now_str
if lane:
    execution["released_by_lane"] = lane

task["execution"] = execution
task["updated_at"] = now_str
tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
PY
}

persist_task_run_context() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local result="${3:-UNKNOWN}"
  local run_id="${4:-}"
  local attempts="${5:-0}"
  local total_step_attempts="${6:-0}"
  local score="${7:-0}"
  local duration="${8:-0}"
  local step_count="${9:-0}"
  local completed_steps="${10:-0}"
  local failed_step_index="${11:-0}"
  local failed_step_text="${12:-}"
  local plan_file="${13:-}"
  local provider="${14:-}"
  local failure_timestamp="${15:-}"
  local task_id="${16:-}"
  local failure_kind="${17:-}"
  local registry_file

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0

  ensure_runtime_dirs
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$project_name" "$queue_task" "$result" "$run_id" "$attempts" "$total_step_attempts" "$score" "$duration" "$step_count" "$completed_steps" "$failed_step_index" "$failed_step_text" "$plan_file" "$provider" "$failure_timestamp" "$task_id" "$failure_kind" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any


(
    path,
    project_name,
    queue_task,
    result,
    run_id,
    attempts,
    total_step_attempts,
    score,
    duration,
    step_count,
    completed_steps,
    failed_step_index,
    failed_step_text,
    plan_file,
    provider,
    failure_timestamp,
    target_task_id,
    failure_kind,
) = sys.argv[1:]


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


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


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return str(task.get("id") or "").strip()


def read_payload(file_path: str) -> dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return {"tasks": []}


def write_payload(file_path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(file_path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, file_path)


def read_plan_steps(file_path: str) -> list[str]:
    if not file_path or not os.path.exists(file_path):
        return []
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    steps = (((payload or {}).get("data") or {}).get("steps") or [])
    if not isinstance(steps, list):
        return []
    return [str(step).strip() for step in steps if str(step).strip()]


def normalize_text(value: Any) -> str:
    return str(value or "").strip()


def normalize_failure_kind(value: Any) -> str:
    return re.sub(r"\s+", "_", str(value or "").strip().lower())


def normalize_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def normalize_json_array(value: Any) -> list[Any]:
    if not isinstance(value, list):
        return []
    try:
        return json.loads(json.dumps(value))
    except (TypeError, ValueError):
        return []


def first_non_empty_text(*values: Any) -> str:
    for value in values:
        candidate = normalize_text(value)
        if candidate:
            return candidate
    return ""


def build_failure_context(
    task: dict[str, Any],
    execution_context: dict[str, Any],
    failure_timestamp: Any,
    updated_at: str,
    target_task_id: str,
    failure_kind: str,
) -> dict[str, Any]:
    # Keep failure_context compact and deterministic. Richer terminal metrics stay
    # on execution_context; follow-up logic only needs the failed step, failure
    # timestamp, run/attempt lineage, and existing provider/task identifiers.
    failure_at = normalize_text(failure_timestamp) or updated_at
    failure_context = {
        "run_id": normalize_text(execution_context.get("run_id")),
        "attempts": normalize_int(execution_context.get("attempts")),
        "failed_step_index": normalize_int(execution_context.get("failed_step_index")),
        "failed_step": normalize_text(execution_context.get("failed_step")),
        "timestamp": failure_at,
    }

    existing_failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    existing_execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}

    provider = first_non_empty_text(
        execution_context.get("provider"),
        existing_failure_context.get("provider"),
        existing_execution_context.get("provider"),
        task.get("execution_provider"),
    )
    if provider:
        failure_context["provider"] = provider

    task_id = first_non_empty_text(
        execution_context.get("task_id"),
        target_task_id,
        task.get("id"),
        existing_failure_context.get("task_id"),
        existing_execution_context.get("task_id"),
    )
    if task_id:
        failure_context["task_id"] = task_id

    original_failed_root_id = first_non_empty_text(
        task.get("original_failed_root_id"),
        execution_context.get("original_failed_root_id"),
        existing_failure_context.get("original_failed_root_id"),
        existing_execution_context.get("original_failed_root_id"),
    )
    if original_failed_root_id:
        failure_context["original_failed_root_id"] = original_failed_root_id

    normalized_failure_kind = first_non_empty_text(
        normalize_failure_kind(failure_kind),
        normalize_failure_kind(execution_context.get("failure_kind")),
        normalize_failure_kind(existing_failure_context.get("failure_kind")),
        normalize_failure_kind(existing_execution_context.get("failure_kind")),
        normalize_failure_kind(task.get("last_failure_kind")),
    )
    if normalized_failure_kind:
        failure_context["failure_kind"] = normalized_failure_kind

    return failure_context


payload = read_payload(path)
tasks = payload.get("tasks")
if not isinstance(tasks, list):
    tasks = []
    payload["tasks"] = tasks

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
target_task_key = normalize_identifier(target_task_id)

selected_index: int | None = None
selected_rank: tuple[str, str, int] | None = None
for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if target_task_key and normalize_identifier(task.get("id")) == target_task_key:
        selected_index = index
        selected_rank = None
        break
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected_index = index

if selected_index is None:
    raise SystemExit(0)

task = dict(tasks[selected_index])
transition_at = now_utc()
plan_steps = read_plan_steps(plan_file)
failed_root_id = original_failed_root_id(task)
existing_execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
existing_execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
existing_status = normalize_text(task.get("status")).lower()
existing_execution_result = normalize_text(existing_execution.get("result")).upper()
existing_execution_context_result = normalize_text(existing_execution_context.get("result")).upper()
result_text = str(result or "").strip().upper()

# Late orchestrator writes can arrive after queue-worker already reconciled a task
# to completed from persisted success evidence. Preserve that terminal success.
if result_text == "FAILURE" and (
    existing_status in {"completed", "success"}
    or existing_execution_result == "SUCCESS"
    or existing_execution_context_result == "SUCCESS"
):
    raise SystemExit(0)

execution_context = {
    "run_id": normalize_text(run_id),
    "provider": normalize_text(provider or task.get("execution_provider")),
    "result": normalize_text(result),
    "attempts": normalize_int(attempts),
    "total_step_attempts": normalize_int(total_step_attempts),
    "score": normalize_int(score),
    "duration_seconds": normalize_int(duration),
    "step_count": normalize_int(step_count),
    "completed_steps": normalize_int(completed_steps),
    "failed_step_index": normalize_int(failed_step_index),
    "failed_step": normalize_text(failed_step_text),
    "plan_steps": plan_steps,
    "updated_at": transition_at,
}
normalized_failure_kind = normalize_failure_kind(failure_kind)
if normalized_failure_kind:
    execution_context["failure_kind"] = normalized_failure_kind
resolved_task_id = first_non_empty_text(task.get("id"), target_task_id)
if resolved_task_id:
    execution_context["task_id"] = resolved_task_id
if failed_root_id:
    execution_context["original_failed_root_id"] = failed_root_id

if result_text == "SUCCESS":
    previous_execution_context = existing_execution_context
    execution_context["acceptance_evidence"] = normalize_json_array(previous_execution_context.get("acceptance_evidence"))
    execution_context["regression_checks"] = normalize_json_array(previous_execution_context.get("regression_checks"))
task["execution_context"] = execution_context
if failed_root_id:
    task["original_failed_root_id"] = failed_root_id

if result_text == "SUCCESS":
    task.pop("failure_context", None)
    task.pop("last_failure_kind", None)
elif result_text == "FAILURE":
    task["failure_context"] = build_failure_context(
        task,
        execution_context,
        failure_timestamp,
        transition_at,
        target_task_id,
        normalized_failure_kind,
    )
    if normalized_failure_kind:
        task["last_failure_kind"] = normalized_failure_kind

task["updated_at"] = transition_at
tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
PY
}

task_registry_late_terminal_outcome() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local task_id="${3:-}"
  local registry_file

  [ -n "$project_name" ] || return 1
  [ -n "$queue_task" ] || return 1

  ensure_runtime_dirs
  registry_file="$(task_registry_file_for_project "$project_name")"

  python3 - "$registry_file" "$TASK_LOG" "$project_name" "$queue_task" "$task_id" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from typing import Any


path, task_log_path, project_name, queue_task, target_task_id = sys.argv[1:6]


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


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


def parse_timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def normalize_result(value: Any) -> str:
    return str(value or "").strip().upper()


def load_task_log_records(file_path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    record = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    records.append(record)
    except Exception:
        return []
    return records


try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(1)

tasks = payload.get("tasks")
if not isinstance(tasks, list):
    raise SystemExit(1)

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
target_task_key = normalize_identifier(target_task_id)

selected: dict[str, Any] | None = None
selected_rank: tuple[str, str, int] | None = None

for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if target_task_key and normalize_identifier(task.get("id")) == target_task_key:
        selected = task
        selected_rank = None
        break
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected = task

if not isinstance(selected, dict):
    raise SystemExit(1)

execution_context = selected.get("execution_context") if isinstance(selected.get("execution_context"), dict) else {}
execution = selected.get("execution") if isinstance(selected.get("execution"), dict) else {}
selected_task_id = normalize_identifier(selected.get("id"))

result_text = normalize_result(execution_context.get("result"))
execution_updated_at = parse_timestamp(execution_context.get("updated_at"))
lease_claimed_at = parse_timestamp(execution.get("lease_claimed_at"))
if lease_claimed_at and execution_updated_at and execution_updated_at < lease_claimed_at:
    result_text = ""

if result_text == "SUCCESS":
    step_count = int(execution_context.get("step_count") or 0)
    completed_steps = int(execution_context.get("completed_steps") or 0)
    if step_count <= 0 or completed_steps < step_count:
        result_text = ""
    else:
        print("SUCCESS")
        raise SystemExit(0)

if result_text == "FAILURE":
    print("FAILURE")
    raise SystemExit(0)

matching_records: list[tuple[datetime, str]] = []
for record in load_task_log_records(task_log_path):
    record_project = normalize_project(record.get("project") or "")
    if record_project != project_key:
        continue
    record_task_id = normalize_identifier(record.get("task_id"))
    if target_task_key:
        if record_task_id != target_task_key:
            continue
    elif selected_task_id and record_task_id and record_task_id != selected_task_id:
        continue
    elif normalize_task(record.get("task")) != task_key:
        continue
    record_timestamp = parse_timestamp(record.get("timestamp"))
    if record_timestamp is None:
        continue
    if lease_claimed_at and record_timestamp < lease_claimed_at:
        continue
    record_result = normalize_result(record.get("result"))
    if record_result not in {"SUCCESS", "FAILURE"}:
        continue
    matching_records.append((record_timestamp, record_result))

if matching_records:
    matching_records.sort(key=lambda item: item[0], reverse=True)
    print(matching_records[0][1])
    raise SystemExit(0)

raise SystemExit(1)
PY
}

task_registry_has_late_success_evidence() {
  local outcome
  outcome="$(task_registry_late_terminal_outcome "$1" "$2" "$3" 2>/dev/null || true)"
  [ "$outcome" = "SUCCESS" ]
}

await_task_registry_late_terminal_outcome() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local task_id="${3:-}"
  local max_polls="${QUEUE_TIMEOUT_LATE_TERMINAL_MAX_POLLS:-${QUEUE_TIMEOUT_LATE_SUCCESS_MAX_POLLS:-5}}"
  local poll_index=0
  local outcome=""

  case "$max_polls" in
    ''|*[!0-9]*)
      max_polls=5
      ;;
  esac

  if [ "$max_polls" -lt 1 ]; then
    max_polls=5
  fi

  while [ "$poll_index" -lt "$max_polls" ]; do
    outcome="$(task_registry_late_terminal_outcome "$project_name" "$queue_task" "$task_id" 2>/dev/null || true)"
    if [ -n "$outcome" ]; then
      printf '%s\n' "$outcome"
      return 0
    fi
    poll_index=$((poll_index + 1))
    if [ "$poll_index" -lt "$max_polls" ]; then
      sleep 1
    fi
  done

  return 1
}

await_task_registry_late_success_evidence() {
  local outcome
  outcome="$(await_task_registry_late_terminal_outcome "$1" "$2" "$3" 2>/dev/null || true)"
  [ "$outcome" = "SUCCESS" ]
}

update_provider_routing_rules() {
  local learning_dir="$ROOT_DIR/codex-learning"
  python3 - "$learning_dir" <<'PY'
from __future__ import annotations
import json, os, sys, tempfile

learning_dir = sys.argv[1]
stats_path = os.path.join(learning_dir, "provider-stats.json")
routing_path = os.path.join(learning_dir, "provider-routing.json")

try:
    with open(stats_path) as f:
        stats = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

# Collect per-category data across all providers
categories: dict[str, list[tuple[str, float, int, float]]] = {}
for provider, cats in stats.items():
    for cat, info in cats.items():
        tc = info.get("task_count", 0)
        sr = info.get("success_rate", 0.0)
        avg_total_step_attempts = info.get("avg_total_step_attempts", info.get("avg_attempts", 0.0))
        categories.setdefault(cat, []).append((provider, sr, tc, avg_total_step_attempts))

rules = []
for cat, entries in sorted(categories.items()):
    total_tasks = sum(tc for _, _, tc, _ in entries)
    if total_tasks < 2:
        continue
    # Check if all providers have 0% success
    all_zero = all(sr == 0.0 for _, sr, _, _ in entries)
    # Pick best: highest success rate, ties broken by task count, then lower aggregate loop effort
    best = max(entries, key=lambda e: (e[1], e[2], -float(e[3] or 0.0), e[0]))
    provider, sr, tc, avg_total_step_attempts = best
    if all_zero:
        best_zero = max(entries, key=lambda e: (e[2], -float(e[3] or 0.0), e[0]))
        rules.append({
            "category": cat,
            "provider": best_zero[0],
            "enabled": False,
            "reason": (
                f"all providers at 0% success - disabled "
                f"({best_zero[0]} has {best_zero[2]} tasks, {float(best_zero[3] or 0.0):.2f} avg total step attempts)"
            )
        })
    else:
        others = [
            f"{p} {r:.2f}/{c} @ {float(avg_total or 0.0):.2f}"
            for p, r, c, avg_total in entries
            if p != provider
        ]
        other_str = f" vs {', '.join(others)}" if others else ""
        rules.append({
            "category": cat,
            "provider": provider,
            "enabled": True,
            "reason": (
                f"{provider} success_rate {sr:.2f} on {tc} tasks "
                f"with {float(avg_total_step_attempts or 0.0):.2f} avg total step attempts{other_str}"
            )
        })

# Iteration 18 fix: Provider health override — never route to a provider with
# >100 consecutive failures. The routing algorithm picks the highest success_rate,
# but doesn't know the provider is currently broken. Check provider-stats for
# recent failure streaks and force-reroute to a healthy alternative.
broken_providers = set()
for provider_name, cats_data in stats.items():
    total_tasks = sum(c.get("task_count", 0) for c in cats_data.values())
    total_successes = sum(
        round(c.get("success_rate", 0) * c.get("task_count", 0))
        for c in cats_data.values()
    )
    # If a provider has 100+ tasks with <5% overall success, consider it broken
    if total_tasks >= 100 and (total_successes / max(total_tasks, 1)) < 0.05:
        broken_providers.add(provider_name)

for rule in rules:
    if rule["provider"] in broken_providers:
        # Find alternative provider
        cat_entries = categories.get(rule["category"], [])
        alternatives = [e for e in cat_entries if e[0] not in broken_providers]
        if alternatives:
            alt = max(alternatives, key=lambda e: (e[1], e[2], -float(e[3] or 0.0)))
            original = rule["provider"]
            rule["provider"] = alt[0]
            rule["reason"] = (
                f"Iteration 18: FORCED to {alt[0]} — {original} provider broken "
                f"(in broken_providers set). Original: {rule['reason'][:80]}"
            )

payload = {"rules": rules}
tmp_fd, tmp_path = tempfile.mkstemp(dir=learning_dir, suffix=".tmp")
try:
    with os.fdopen(tmp_fd, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, routing_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PY
}
