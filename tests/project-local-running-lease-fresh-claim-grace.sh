#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

recent_claimed_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

future_expires_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/projects/superheld" \
  "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-superheld-fresh-running",
      "title": "project local fresh running task",
      "project": "superheld",
      "status": "running",
      "updated_at": "$recent_claimed_at",
      "execution": {
        "state": "running",
        "attempt": 1,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "$recent_claimed_at",
        "will_retry": false,
        "lane": "lane-1",
        "lease_id": "lane-1-$recent_claimed_at",
        "lease_state": "claimed",
        "lease_claimed_at": "$recent_claimed_at",
        "lease_expires_at": "$future_expires_at"
      },
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

: >"$TEST_ROOT/queues/superheld.txt"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  printf '' | reconcile_running_registry_tasks_to_active_leases
) >"$TMP_DIR/reconciled.txt"

if [ -s "$TMP_DIR/reconciled.txt" ]; then
  echo "expected no reconciliation for freshly claimed lease" >&2
  cat "$TMP_DIR/reconciled.txt" >&2
  exit 1
fi

if [ -s "$TEST_ROOT/queues/superheld.txt" ]; then
  echo "expected no queue rehydrate during fresh-claim grace window" >&2
  exit 1
fi

python3 - "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]

assert task["status"] == "running"
assert task["execution"]["state"] == "running"
assert task["execution"]["lease_state"] == "claimed"
assert task.get("history") == []
PY

echo "project local running lease fresh claim grace test passed"
