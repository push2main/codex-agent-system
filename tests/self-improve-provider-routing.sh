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
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.11,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 24
}
EOF

cat >"$REPO_ROOT/codex-learning/provider-routing.json" <<'EOF'
{
  "rules": [
    {
      "category": "infra",
      "provider": "claude",
      "enabled": true,
      "reason": "claude success_rate 0.40 on 5 infra tasks with lower loop effort than codex"
    }
  ]
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

jq -e '
  .tasks
  | map(select((.task_intent.source // "") == "self-improve"))
  | length == 1
' "$REPO_ROOT/codex-memory/tasks.json" >/dev/null

jq -e '
  .tasks
  | map(select((.task_intent.source // "") == "self-improve"))
  | first
  | .title == "Reduce timeout rate"
' "$REPO_ROOT/codex-memory/tasks.json" >/dev/null

jq -e '
  .tasks
  | map(select((.task_intent.source // "") == "self-improve"))
  | first
  | .execution_provider == "claude"
' "$REPO_ROOT/codex-memory/tasks.json" >/dev/null

jq -e '
  .tasks
  | map(select((.task_intent.source // "") == "self-improve"))
  | first
  | .provider_selection.selected == "claude" and
    .provider_selection.source == "routing_rule" and
    (.provider_selection.reason | contains("inferred category")) and
    (.provider_selection.reason | contains("infra"))
' "$REPO_ROOT/codex-memory/tasks.json" >/dev/null

echo "self improve provider routing test passed"
