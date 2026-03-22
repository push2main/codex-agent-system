#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
TEST_TASK_REGISTRY="$TEST_ROOT/codex-memory/tasks.json"
TEST_TASK_LOG="$TEST_ROOT/codex-memory/tasks.log"
TEST_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json"
SYSTEM_LOG_SNAPSHOT="$TMP_DIR/system.log.after"
TEST_TASK="Require explicit external workspaces for managed projects"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/codex-dashboard"

source "$TEST_ROOT/scripts/lib.sh"

CODEX_SHARED_HOME="$TMP_DIR/shared-home"
ensure_runtime_dirs

write_status "idle" "" "" "NONE" "queue_auth_pause_test"

printf '%s\n' "$TEST_TASK" >"$TEST_ROOT/queues/codex-agent-system.txt"

cat >"$TEST_TASK_REGISTRY" <<'EOF'
{
  "tasks": []
}
EOF
: >"$TEST_TASK_LOG"
cat >"$TEST_METRICS_FILE" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0
}
EOF

SYSTEM_LOG_LINE_COUNT="$(wc -l <"$TEST_ROOT/codex-logs/system.log" 2>/dev/null || printf '0')"
write_codex_auth_failure_state "$(codex_auth_failure_file)" "401 Unauthorized: Missing bearer or basic authentication in header"

(
  cd "$TEST_ROOT"
  TASK_REGISTRY_FILE="$TEST_TASK_REGISTRY" \
  TASK_LOG="$TEST_TASK_LOG" \
  METRICS_FILE="$TEST_METRICS_FILE" \
  CODEX_SHARED_HOME="$CODEX_SHARED_HOME" \
  bash "$TEST_ROOT/scripts/multi-queue.sh" --once
)

tail -n +"$((SYSTEM_LOG_LINE_COUNT + 1))" "$TEST_ROOT/codex-logs/system.log" >"$SYSTEM_LOG_SNAPSHOT" 2>/dev/null || true

grep -qx "$TEST_TASK" "$TEST_ROOT/queues/codex-agent-system.txt"
grep -q '^state=blocked$' "$TEST_ROOT/status.txt"
grep -q '^last_result=DEGRADED$' "$TEST_ROOT/status.txt"
grep -q '^note=waiting_for_codex_auth' "$TEST_ROOT/status.txt"
! grep -q . "$TEST_TASK_LOG"
grep -q 'Queue execution paused because Codex authentication is unavailable' "$SYSTEM_LOG_SNAPSHOT"

echo "queue auth pause test passed"
