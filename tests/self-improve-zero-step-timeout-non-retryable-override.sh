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

timeout_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"))
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
      "updated_at": "$timeout_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T08:00:00Z","project":"codex-agent-system","task":"Reduce timeout rate","result":"FAILURE","failure_kind":"timeout","task_id":"task-001-timeout-rate","duration_seconds":900,"total_step_attempts":0}
{"timestamp":"2026-03-24T12:00:00Z","project":"codex-agent-system","task":"Reduce timeout rate","result":"FAILURE","failure_kind":"timeout","task_id":"task-001-timeout-rate","duration_seconds":900,"total_step_attempts":0}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "first_pass_success_rate": 0.85,
  "timeout_failure_rate": 0.17,
  "zero_step_timeout_rate": 0.92,
  "approved_tasks": 91,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 1043660,
  "task_registry_pressure_detected": true,
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
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=3600 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_OVERLOAD_FAMILY_OUTCOME_LOOKBACK_SECONDS=604800 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected zero-step timeout emergency to override timeout-family non-retryable suppression" >&2
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
if [ "$task_title" != "Cap pre-step planning budget" ]; then
  echo "expected zero-step timeout emergency to promote the planning-budget successor once timeout-family failures are known" >&2
  exit 1
fi

submission_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.submission_reason,
      .metrics_snapshot.zero_step_timeout_rate
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$submission_summary" != $'3\t1\tcritical_low_success_rate\t1.0' ]; then
  echo "unexpected self-improve artifact after timeout emergency override: $submission_summary" >&2
  exit 1
fi

reason_summary="$(
  jq -r '
    .tasks
    | map(select(.title == "Cap pre-step planning budget"))
    | first
    | [
        (.reason // ""),
        (.execution_task // ""),
        (.task_family // ""),
        (.strategy_playbook // ""),
        (.task_shape.playbook // "")
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [[ "$reason_summary" != *$'\tzero-step-timeouts\tplaybooks/zero-step-timeouts.md\tplaybooks/zero-step-timeouts.md' ]]; then
  echo "expected planning-budget task to carry the zero-step timeout playbook, got: $reason_summary" >&2
  exit 1
fi

if [[ "$reason_summary" != *"prior timeout-family outcomes already blocked or exhausted the generic timeout remediation."* ]]; then
  echo "expected planning-budget task reason to reflect prior timeout-family exhaustion, got: $reason_summary" >&2
  exit 1
fi

echo "self improve zero-step timeout non-retryable override test passed"
