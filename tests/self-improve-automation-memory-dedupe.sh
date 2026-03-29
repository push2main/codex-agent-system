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
  "success_rate": 0.13,
  "first_pass_success_rate": 0.0,
  "timeout_failure_rate": 0.35,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 100
}
EOF

touch -t 202603280900 "$REPO_ROOT/codex-logs/self-improve-paused"

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

EXTERNAL_MEMORY_FILE="$TMP_DIR/home/.codex/automations/push2main-codex-agent-system/memory.md"
MIRROR_MEMORY_FILE="$REPO_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"

[ -f "$EXTERNAL_MEMORY_FILE" ]
[ -f "$MIRROR_MEMORY_FILE" ]

external_count="$(grep -Ec '^-[[:space:]].*weakness=Long-lived self-improve pause \| improvement=none \| outcome=success submitted=0/0 detected=0 duration_s=[0-9]+ \| next=Remove self-improve pause gate \| external_sync_pending=false$' "$EXTERNAL_MEMORY_FILE")"
mirror_count="$(grep -Ec '^-[[:space:]].*weakness=Long-lived self-improve pause \| improvement=none \| outcome=success submitted=0/0 detected=0 duration_s=[0-9]+ \| next=Remove self-improve pause gate \| external_sync_pending=false$' "$MIRROR_MEMORY_FILE")"

if [ "$external_count" -ne 1 ]; then
  echo "expected duplicate paused no-op self-improve summary to be suppressed in external memory, got $external_count entries" >&2
  exit 1
fi

if [ "$mirror_count" -ne 1 ]; then
  echo "expected duplicate paused no-op self-improve summary to be suppressed in mirror memory, got $mirror_count entries" >&2
  exit 1
fi

echo "self improve automation memory dedupe test passed"
