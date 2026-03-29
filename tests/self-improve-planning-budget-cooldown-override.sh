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

recent_active_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-003-queue-health-check",
      "title": "Queue health check",
      "project": "codex-agent-system",
      "status": "queued",
      "updated_at": "$recent_active_at"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.10,
  "recent_success_rate": 0.12,
  "first_pass_success_rate": 1.0,
  "timeout_failure_rate": 0.31,
  "zero_step_timeout_rate": 0.96,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 17,
  "retry_total_count": 17,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "queued_tasks": 1,
  "running_tasks": 0,
  "task_registry_total": 3,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "pipeline_stale": false,
  "total_tasks": 349
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
  echo "expected planning-budget remediation to bypass its cooldown during a sustained zero-step timeout emergency, got: $pending_titles" >&2
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
if [ "$artifact_summary" != $'2\t1\tnone\t0.96' ]; then
  echo "unexpected planning-budget cooldown override artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve planning-budget cooldown override test passed"
