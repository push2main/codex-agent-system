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
RECENT_SUCCESS_AT="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "$RECENT_SUCCESS_AT",
      "completed_at": "$RECENT_SUCCESS_AT",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.33,
  "zero_step_timeout_rate": 0.94,
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 1,
  "approved_backlog": 1,
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
  "total_tasks": 240
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

timeout_title_count="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.title // "") == "Reduce timeout rate"))
    | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$timeout_title_count" != "0" ]; then
  echo "expected recent successful planning-budget remediation to suppress generic timeout regeneration, found $timeout_title_count timeout tasks" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1' ]; then
  echo "unexpected artifact summary when recent planning-budget success should suppress generic timeout follow-up: $artifact_summary" >&2
  exit 1
fi

echo "self improve recent planning-budget success suppression test passed"
