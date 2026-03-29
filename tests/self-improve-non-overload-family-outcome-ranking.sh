#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

recent_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-timeout-rate",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-retry-churn",
      "title": "Recent retry churn evidence",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "failed_at": "$recent_failure_at",
      "execution": {
        "state": "failed",
        "attempt": 2,
        "total_step_attempts": 527,
        "max_retries": 2,
        "result": "FAILURE",
        "updated_at": "$recent_failure_at"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<EOF
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","total_step_attempts":0,"task_id":"task-001-timeout-rate","attempts":1,"score":0,"run_id":"run-timeout-family"}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Recent retry churn evidence","result":"FAILURE","failure_kind":"step_failure","total_step_attempts":527,"task_id":"task-002-retry-churn","attempts":2,"score":0,"run_id":"run-retry-family"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.17,
  "zero_step_timeout_rate": 0.92,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "approved_tasks": 2,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 63,
  "loop_effort_extra_step_attempts": 158,
  "external_signal_status": "fresh",
  "total_tasks": 476
}
EOF

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=3600 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=7200 \
  SELF_IMPROVE_OVERLOAD_FAMILY_OUTCOME_LOOKBACK_SECONDS=604800 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected non-overload submission limit to keep exactly one self-improve task" >&2
  exit 1
fi

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Break retry churn" ]; then
  echo "expected recent timeout-family failure to demote timeout remediation outside backlog overload" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.overload.active,
      .metrics_snapshot.zero_step_timeout_rate
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'4\t1\tfalse\t1.0' ]; then
  echo "unexpected self-improve artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve non-overload family outcome ranking test passed"
