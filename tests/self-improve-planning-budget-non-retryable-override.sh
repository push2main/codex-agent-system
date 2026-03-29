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

planning_budget_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-000-reduce-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$planning_budget_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-001-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$planning_budget_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-27T20:35:08Z","project":"codex-agent-system","task":"Reduce timeout rate","result":"FAILURE","failure_kind":"timeout","task_id":"task-000-reduce-timeout-rate","duration_seconds":900,"total_step_attempts":0}
{"timestamp":"2026-03-27T23:40:08Z","project":"codex-agent-system","task":"Reduce timeout rate","result":"FAILURE","failure_kind":"timeout","task_id":"task-000-reduce-timeout-rate","duration_seconds":900,"total_step_attempts":0}
{"timestamp":"2026-03-27T20:35:08Z","project":"codex-agent-system","task":"Cap pre-step planning budget","result":"FAILURE","failure_kind":"timeout","task_id":"task-001-cap-pre-step-planning-budget","duration_seconds":900,"total_step_attempts":0}
{"timestamp":"2026-03-27T23:40:08Z","project":"codex-agent-system","task":"Cap pre-step planning budget","result":"FAILURE","failure_kind":"timeout","task_id":"task-001-cap-pre-step-planning-budget","duration_seconds":900,"total_step_attempts":0}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.10,
  "recent_success_rate": 0.02,
  "first_pass_success_rate": 1.0,
  "timeout_failure_rate": 0.31,
  "zero_step_timeout_rate": 0.95,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 19,
  "retry_total_count": 19,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 2,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 1,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-24T19:35:27Z",
  "total_tasks": 352
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_PLANNING_BUDGET_RETRY_SECONDS=7200 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

pending_titles="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | map(.title)
    | sort
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$pending_titles" != $'Cap pre-step planning budget' ]; then
  echo "expected planning-budget remediation to override its timeout non-retryable block after the retry window expires, got: $pending_titles" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason,
      .metrics_snapshot.zero_step_timeout_rate
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'3\t1\tnone\t1.0' ]; then
  echo "unexpected planning-budget non-retryable override artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve planning-budget non-retryable override test passed"
