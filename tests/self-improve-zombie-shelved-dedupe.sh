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
      "id": "task-001-first-pass-zombie",
      "title": "Inventory current decision path for improve first-pass success rate",
      "execution_task": "[self-improve:critical] Inventory current decision path for improve first-pass success rate -- stale zombie copy",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "2026-03-27T08:00:00Z",
      "shelved_reason": "zombie_guard: 5 prior failures exceed threshold of 5"
    },
    {
      "id": "task-002-first-pass-zombie",
      "title": "Inventory current decision path for improve first-pass success rate",
      "execution_task": "[self-improve:critical] Inventory current decision path for improve first-pass success rate -- newer zombie copy",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "2026-03-27T09:00:00Z",
      "shelved_reason": "auto-shelved: task family already failed 5 times and is permanently blocked",
      "history": [
        {
          "at": "2026-03-27T09:00:00Z",
          "action": "auto_shelve",
          "note": "Task was automatically retired because this self-improve family already crossed the zombie threshold: task family already failed 5 times and is permanently blocked."
        }
      ]
    },
    {
      "id": "task-003-first-pass-zombie",
      "title": "Inventory current decision path for improve first-pass success rate",
      "execution_task": "[self-improve:critical] Inventory current decision path for improve first-pass success rate -- latest zombie copy",
      "project": "codex-agent-system",
      "status": "shelved",
      "updated_at": "2026-03-27T10:00:00Z",
      "shelved_reason": "zombie_guard: 5 prior failures exceed threshold of 5"
    },
    {
      "id": "task-004-unrelated",
      "title": "Review external signal: OpenAI Python releases - v2.30.0",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-27T11:00:00Z"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.90,
  "first_pass_success_rate": 0.90,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

touch "$REPO_ROOT/codex-memory/tasks.log"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

zombie_summary="$(
  jq -r '
    [
      (.tasks | map(select(.title == "Inventory current decision path for improve first-pass success rate")) | length),
      (.tasks | map(select(.title == "Inventory current decision path for improve first-pass success rate")) | .[0].id // ""),
      (.tasks | map(select(.id == "task-004-unrelated")) | length)
    ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"

if [ "$zombie_summary" != $'1\ttask-003-first-pass-zombie\t1' ]; then
  echo "expected zombie-shelved duplicates to compact to the newest survivor, got: $zombie_summary" >&2
  exit 1
fi

dedupe_count="$(
  jq -r '.gating.deduped_zombie_shelved_tasks // empty' \
    "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "${dedupe_count:-}" != "2" ]; then
  echo "expected run artifact to record two deduped zombie-shelved tasks, got: ${dedupe_count:-missing}" >&2
  exit 1
fi

echo "self improve zombie shelved dedupe test passed"
