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

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-approved",
      "title": "[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum",
      "execution_task": "[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2026-03-30T22:26:25Z",
      "approved_at": "2026-03-30T22:26:25Z",
      "execution": {
        "state": "approved",
        "attempt": 1,
        "max_retries": 2,
        "provider": "codex",
        "result": "FAILURE",
        "updated_at": "2026-03-30T22:26:25Z",
        "lane": "lane-4",
        "lease_id": "lane-4-2026-03-30T22:26:25Z",
        "lease_state": "claimed",
        "lease_claimed_at": "2026-03-30T22:26:25Z",
        "lease_expires_at": "2099-03-30T22:31:35Z",
        "lease_ttl_seconds": 310
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
  sync_task_registry_execution_state \
    "superheld" \
    "[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum" \
    "running" \
    "execute_start" \
    "Queue execution started." \
    "1" \
    "2" \
    "codex" \
    "lane-4" \
    "" \
    "0" \
    "task-superheld-approved"
  printf 'lane-4\tlane-4-2026-03-30T22:26:25Z\tsuperheld\t[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum\n' \
    | reconcile_running_registry_tasks_to_active_leases
) >"$TMP_DIR/reconcile-output.txt"

if [ -s "$TMP_DIR/reconcile-output.txt" ]; then
  echo "expected no reconciliation output when execute_start preserves the claimed lease" >&2
  cat "$TMP_DIR/reconcile-output.txt" >&2
  exit 1
fi

python3 - "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]

assert task["status"] == "running", task
assert task["execution"]["state"] == "running", task["execution"]
assert task["execution"]["lease_id"] == "lane-4-2026-03-30T22:26:25Z", task["execution"]
assert task["execution"]["lease_claimed_at"] == "2026-03-30T22:26:25Z", task["execution"]
assert task["execution"]["lease_expires_at"] == "2099-03-30T22:31:35Z", task["execution"]
assert task["history"][-1]["action"] == "execute_start", task["history"][-1]
PY

echo "project local claimed lease preserved on execute start test passed"
