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
    IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
  )
}

REPO_ONE="$TMP_DIR/repo-one"
make_repo "$REPO_ONE"

cat >"$REPO_ONE/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ONE/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 530000,
  "task_registry_pressure_bytes": 530000,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

run_self_improve "$REPO_ONE"

queued_line="$(
  jq -r '
    .tasks
    | map(select(.task_intent.source == "self-improve"))
    | first
    | .execution_task // ""
  ' "$REPO_ONE/codex-memory/tasks.json"
)"

case "$queued_line" in
  "[self-improve:medium] Reduce registry pressure -- "*)
    ;;
  *)
    echo "expected stable registry-pressure title in registry task" >&2
    exit 1
    ;;
esac

case "$queued_line" in
  *"Reduce registry pressure ("*)
    echo "expected registry-pressure metrics to stay in reason, not title" >&2
    exit 1
    ;;
esac

REPO_TWO="$TMP_DIR/repo-two"
make_repo "$REPO_TWO"

cat >"$REPO_TWO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-registry-pressure",
      "title": "[self-improve:medium] Reduce registry pressure (498KB > 400KB threshold) — Task registry exceeds size threshold. Run compact-registry.sh more aggressively.",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-20T20:00:00Z"
    }
  ]
}
EOF

cp "$REPO_ONE/codex-learning/metrics.json" "$REPO_TWO/codex-learning/metrics.json"

run_self_improve "$REPO_TWO"

task_count_two="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_TWO/codex-memory/tasks.json"
)"
if [ "${task_count_two:-0}" -ne 0 ]; then
  echo "expected active registry-pressure task to block duplicate improvement" >&2
  exit 1
fi

REPO_THREE="$TMP_DIR/repo-three"
make_repo "$REPO_THREE"

cat >"$REPO_THREE/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-registry-pressure",
      "title": "[self-improve:medium] Reduce registry pressure (498KB > 400KB threshold) — Task registry exceeds size threshold. Run compact-registry.sh more aggressively.",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-24T23:00:00Z"
    }
  ]
}
EOF

cp "$REPO_ONE/codex-learning/metrics.json" "$REPO_THREE/codex-learning/metrics.json"

(
  cd "$REPO_THREE"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=86400 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count_three="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_THREE/codex-memory/tasks.json"
)"
if [ "${task_count_three:-0}" -ne 0 ]; then
  echo "expected recent terminal registry-pressure task to stay in cooldown" >&2
  exit 1
fi

REPO_FOUR="$TMP_DIR/repo-four"
make_repo "$REPO_FOUR"

cat >"$REPO_FOUR/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-registry-pressure",
      "title": "[self-improve:medium] Reduce registry pressure (498KB > 400KB threshold) — Task registry exceeds size threshold. Run compact-registry.sh more aggressively.",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-20T20:00:00Z"
    }
  ]
}
EOF

cp "$REPO_ONE/codex-learning/metrics.json" "$REPO_FOUR/codex-learning/metrics.json"

(
  cd "$REPO_FOUR"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=3600 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count_four="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_FOUR/codex-memory/tasks.json"
)"
if [ "${task_count_four:-0}" -ne 1 ]; then
  echo "expected stale terminal registry-pressure task to allow a fresh improvement" >&2
  exit 1
fi

echo "self improve title family dedupe test passed"
