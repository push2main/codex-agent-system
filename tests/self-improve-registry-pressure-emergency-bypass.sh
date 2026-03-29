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

run_self_improve() {
  local repo_root="$1"
  (
    cd "$repo_root"
    IMPROVEMENT_COOLDOWN_SECONDS=0 \
    SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=3600 \
    SELF_IMPROVE_TITLE_FAMILY_SATURATION_COOLDOWN_SECONDS=86400 \
    bash scripts/self-improve.sh codex-agent-system >/dev/null
  )
}

REPO_RECOVERY="$TMP_DIR/repo-recovery"
make_repo "$REPO_RECOVERY"

cat >"$REPO_RECOVERY/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-registry-pressure",
      "title": "[self-improve:medium] Reduce registry pressure -- Task registry exceeds size threshold (678KB > 500KB). Run compact-registry.sh more aggressively.",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "2026-03-24T23:00:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_RECOVERY/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 1120000,
  "task_registry_pressure_bytes": 1120000,
  "task_registry_pressure_detected": true,
  "retry_churn_detected": false,
  "strategy_saturation": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

run_self_improve "$REPO_RECOVERY"

recovery_task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_RECOVERY/codex-memory/tasks.json"
)"
if [ "${recovery_task_count:-0}" -ne 2 ]; then
  echo "expected extreme local registry pressure to reopen the shelved registry-pressure family" >&2
  exit 1
fi

recovery_execution_task="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | last
    | .execution_task // ""
  ' "$REPO_RECOVERY/codex-memory/tasks.json"
)"

case "$recovery_execution_task" in
  "[self-improve:medium] Reduce registry pressure -- "*)
    ;;
  *)
    echo "expected reopened emergency task to stay in the stable registry-pressure family" >&2
    exit 1
    ;;
esac

REPO_ACTIVE="$TMP_DIR/repo-active"
make_repo "$REPO_ACTIVE"

cat >"$REPO_ACTIVE/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-registry-pressure",
      "title": "[self-improve:medium] Reduce registry pressure -- Task registry exceeds size threshold (678KB > 500KB). Run compact-registry.sh more aggressively.",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T05:00:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cp "$REPO_RECOVERY/codex-learning/metrics.json" "$REPO_ACTIVE/codex-learning/metrics.json"

run_self_improve "$REPO_ACTIVE"

active_task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_ACTIVE/codex-memory/tasks.json"
)"
if [ "${active_task_count:-0}" -ne 1 ]; then
  echo "expected active registry-pressure task to remain blocked even under extreme pressure" >&2
  exit 1
fi

echo "self improve registry pressure emergency bypass test passed"
