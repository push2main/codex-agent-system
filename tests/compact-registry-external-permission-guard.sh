#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_ROOT="$TMP_DIR/external-project"

cleanup() {
  chmod -R u+w "$TMP_DIR" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/queues" "$TEST_ROOT/projects"
mkdir -p "$EXTERNAL_ROOT/.codex-agent"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": f"task-{index:03d}",
            "title": f"Completed task {index:03d}",
            "project": "codex-agent-system",
            "status": "completed",
            "created_at": f"2026-03-25T07:{index:02d}:00Z",
            "updated_at": f"2026-03-25T07:{index:02d}:30Z",
            "reason": "L" * 20000,
        }
        for index in range(20)
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

python3 - "$EXTERNAL_ROOT/.codex-agent/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": f"external-task-{index:03d}",
            "title": f"External completed task {index:03d}",
            "project": "superheld",
            "status": "completed",
            "created_at": f"2026-03-25T06:{index:02d}:00Z",
            "updated_at": f"2026-03-25T06:{index:02d}:30Z",
            "reason": "E" * 20000,
        }
        for index in range(20)
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

chmod 555 "$EXTERNAL_ROOT/.codex-agent"

: >"$TEST_ROOT/codex-memory/tasks.log"
cat >"$TEST_ROOT/codex-learning/metrics.json" <<EOF
{
  "success_rate": 0.5,
  "recent_success_rate": 0.5,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 0.5,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": 900000,
  "task_registry_pressure_sources": [
    {
      "project": "codex-agent-system",
      "file": "$TEST_ROOT/codex-memory/tasks.json",
      "payload_bytes": 450000
    },
    {
      "project": "superheld",
      "file": "$EXTERNAL_ROOT/.codex-agent/tasks.json",
      "payload_bytes": 450000
    }
  ],
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "zero_step_timeout_rate": 0.0,
  "total_tasks": 40
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-25T08:00:00Z",
  "signals": []
}
EOF

before_size="$(wc -c <"$TEST_ROOT/codex-memory/tasks.json")"

(
  cd "$TEST_ROOT"
  bash scripts/compact-registry.sh >/dev/null
)

after_size="$(wc -c <"$TEST_ROOT/codex-memory/tasks.json")"

if [ "$after_size" -ge "$before_size" ]; then
  echo "expected local registry to shrink despite external permission denial" >&2
  exit 1
fi

if [ -f "$EXTERNAL_ROOT/.codex-agent/tasks-archive.json" ]; then
  echo "expected external archive write to be skipped on permission error" >&2
  exit 1
fi

echo "compact registry external permission guard test passed"
