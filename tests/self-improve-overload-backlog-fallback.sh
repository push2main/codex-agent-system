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

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-timeout-rate",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-26T01:00:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-retry-success",
      "title": "[self-improve:high] Improve retry success rate -- Retry attempts are failing 84% of the time",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-26T01:05:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-003-break-retry-churn",
      "title": "Break retry churn",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-26T01:10:00Z",
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
  "first_pass_success_rate": 0.85,
  "timeout_failure_rate": 0.17,
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
  SELF_IMPROVE_TITLE_FAMILY_FAILURE_STREAK_THRESHOLD=1 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=3600 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected overload gate to keep exactly one self-improve task when primary root-cause families are blocked" >&2
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
if [ "$task_title" != "Drain approval backlog" ]; then
  echo "expected overload gate to fall back to approval backlog drain when all root-cause families are blocked" >&2
  exit 1
fi

echo "self improve overload backlog fallback test passed"
