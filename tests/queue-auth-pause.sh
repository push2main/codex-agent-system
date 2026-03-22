#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
QUEUES_BACKUP_DIR="$TMP_DIR/queues-backup"
STATUS_BACKUP_FILE="$TMP_DIR/status.txt.backup"
SYSTEM_LOG_BACKUP_FILE="$TMP_DIR/system.log.backup"
AUTH_FAILURE_BACKUP_FILE="$TMP_DIR/codex-auth-failure.json.backup"
TEST_TASK_REGISTRY="$TMP_DIR/tasks.json"
TEST_TASK_LOG="$TMP_DIR/tasks.log"
TEST_METRICS_FILE="$TMP_DIR/metrics.json"
SYSTEM_LOG_SNAPSHOT="$TMP_DIR/system.log.after"
TEST_TASK="Require explicit external workspaces for managed projects"

cleanup() {
  if [ -f "$STATUS_BACKUP_FILE" ]; then
    cp "$STATUS_BACKUP_FILE" "$ROOT_DIR/status.txt"
  else
    rm -f "$ROOT_DIR/status.txt"
  fi

  if [ -f "$SYSTEM_LOG_BACKUP_FILE" ]; then
    mkdir -p "$ROOT_DIR/codex-logs"
    cp "$SYSTEM_LOG_BACKUP_FILE" "$ROOT_DIR/codex-logs/system.log"
  else
    rm -f "$ROOT_DIR/codex-logs/system.log"
  fi

  if [ -f "$AUTH_FAILURE_BACKUP_FILE" ]; then
    mkdir -p "$ROOT_DIR/codex-logs"
    cp "$AUTH_FAILURE_BACKUP_FILE" "$ROOT_DIR/codex-logs/codex-auth-failure.json"
  else
    rm -f "$ROOT_DIR/codex-logs/codex-auth-failure.json"
  fi

  rm -rf "$ROOT_DIR/queues"
  mkdir -p "$ROOT_DIR/queues"
  if [ -d "$QUEUES_BACKUP_DIR" ]; then
    cp -R "$QUEUES_BACKUP_DIR/." "$ROOT_DIR/queues" 2>/dev/null || true
  fi

  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

source "$ROOT_DIR/scripts/lib.sh"

ensure_runtime_dirs

if [ -f "$ROOT_DIR/status.txt" ]; then
  cp "$ROOT_DIR/status.txt" "$STATUS_BACKUP_FILE"
fi
if [ -f "$ROOT_DIR/codex-logs/system.log" ]; then
  cp "$ROOT_DIR/codex-logs/system.log" "$SYSTEM_LOG_BACKUP_FILE"
fi
if [ -f "$ROOT_DIR/codex-logs/codex-auth-failure.json" ]; then
  cp "$ROOT_DIR/codex-logs/codex-auth-failure.json" "$AUTH_FAILURE_BACKUP_FILE"
fi
mkdir -p "$QUEUES_BACKUP_DIR"
if [ -d "$ROOT_DIR/queues" ]; then
  cp -R "$ROOT_DIR/queues/." "$QUEUES_BACKUP_DIR" 2>/dev/null || true
fi

write_status "idle" "" "" "NONE" "queue_auth_pause_test"

rm -rf "$ROOT_DIR/queues"
mkdir -p "$ROOT_DIR/queues"
printf '%s\n' "$TEST_TASK" >"$ROOT_DIR/queues/codex-agent-system.txt"

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

SYSTEM_LOG_LINE_COUNT="$(wc -l <"$ROOT_DIR/codex-logs/system.log" 2>/dev/null || printf '0')"
write_codex_auth_failure_state "$(codex_auth_failure_file)" "401 Unauthorized: Missing bearer or basic authentication in header"

TASK_REGISTRY_FILE="$TEST_TASK_REGISTRY" \
TASK_LOG="$TEST_TASK_LOG" \
METRICS_FILE="$TEST_METRICS_FILE" \
bash "$ROOT_DIR/scripts/multi-queue.sh" --once

tail -n +"$((SYSTEM_LOG_LINE_COUNT + 1))" "$ROOT_DIR/codex-logs/system.log" >"$SYSTEM_LOG_SNAPSHOT" 2>/dev/null || true

grep -qx "$TEST_TASK" "$ROOT_DIR/queues/codex-agent-system.txt"
grep -q '^state=blocked$' "$ROOT_DIR/status.txt"
grep -q '^last_result=DEGRADED$' "$ROOT_DIR/status.txt"
grep -q '^note=waiting_for_codex_auth' "$ROOT_DIR/status.txt"
! grep -q . "$TEST_TASK_LOG"
grep -q 'Queue execution paused because Codex authentication is unavailable' "$SYSTEM_LOG_SNAPSHOT"

echo "queue auth pause test passed"
