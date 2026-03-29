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

retry_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

retry_churn_shelved_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T19:34:11Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-retry-success",
      "title": "Improve retry success rate",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$retry_failure_at",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-003-break-retry-churn",
      "title": "Break retry churn",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "$retry_churn_shelved_at",
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
  "recent_success_rate": 0.10,
  "first_pass_success_rate": 0.67,
  "timeout_failure_rate": 0.33,
  "zero_step_timeout_rate": 0.97,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 1,
  "task_registry_payload_bytes": 1181185,
  "task_registry_pressure_bytes": 1181185,
  "task_registry_pressure_detected": true,
  "task_registry_pressure_sources": [
    {
      "project": "superheld",
      "file": "/tmp/superheld/tasks.json",
      "payload_bytes": 1082426
    },
    {
      "project": "codex-agent-system",
      "file": "/tmp/codex-agent-system/tasks.json",
      "payload_bytes": 98759
    }
  ],
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "loop_effort_task_count": 70,
  "loop_effort_extra_step_attempts": 163,
  "external_signal_status": "fresh",
  "total_tasks": 326
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=7200 \
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
if [ "$pending_titles" != $'Cap pre-step planning budget\nReduce timeout rate' ]; then
  echo "expected zero-step timeout emergency with active timeout family to add the planning-budget fallback, got: $pending_titles" >&2
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
if [ "$artifact_summary" != $'1\t1\ttitle_family_cooldown\ttitle_family_cooldown' ]; then
  echo "unexpected artifact summary for zero-step active-family fallback: $artifact_summary" >&2
  exit 1
fi

echo "self improve zero-step timeout active-family fallback test passed"
