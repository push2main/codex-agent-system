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

pipeline_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

recent_planning_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=70)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-recover-stale-pipeline",
      "title": "Recover stale pipeline",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$pipeline_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_planning_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.10,
  "recent_success_rate": 0.08,
  "first_pass_success_rate": 1.0,
  "timeout_failure_rate": 0.31,
  "zero_step_timeout_rate": 0.95,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 17,
  "retry_total_count": 17,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 2,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T09:00:00Z",
  "total_tasks": 349
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_PLANNING_BUDGET_RETRY_SECONDS=7200 \
  SELF_IMPROVE_PIPELINE_STALE_RETRY_SECONDS=14400 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

pending_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | [length, (.[0].title // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$pending_summary" != $'1\tRecover stale pipeline' ]; then
  echo "expected stale pipeline recovery to stay eligible during zero-step timeout emergencies after its retry window, got: $pending_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason,
      .metrics_snapshot.pipeline_stale,
      .metrics_snapshot.zero_step_timeout_rate
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'3\t1\tnone\ttrue\t0.95' ]; then
  echo "unexpected stale-pipeline plus zero-step artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve stale pipeline zero-step recovery test passed"
