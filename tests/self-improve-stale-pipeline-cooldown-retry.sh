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

retry_failed_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
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
      "updated_at": "$retry_failed_at",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.25,
  "recent_success_rate": 0.20,
  "first_pass_success_rate": 0.40,
  "timeout_failure_rate": 0.04,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 5,
  "retry_total_count": 5,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T09:00:00Z",
  "total_tasks": 200
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
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
  echo "expected stale pipeline retry override to requeue recovery before lower-priority work, got: $pending_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason,
      .gating.dominant_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
case "$artifact_summary" in
  $'3\t1\tnone\tsubmission_limit'|$'2\t1\tnone\tsubmission_limit')
    ;;
  *)
    echo "unexpected stale pipeline retry artifact summary: $artifact_summary" >&2
    exit 1
    ;;
esac

echo "self improve stale pipeline cooldown retry test passed"
