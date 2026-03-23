#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 },
    "learning": { "weight": 1.2, "success_rate": 0.75 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-stale-running-root",
      "title": "Ghost running task blocks new planning",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.8,
      "status": "running",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "execution": {
        "state": "running",
        "lease_state": "claimed",
        "lease_expires_at": "2026-03-23T08:06:00Z",
        "lane": "lane-1"
      }
    }
  ]
}
EOF

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.log"
import json
for i in range(12):
    print(json.dumps({
        "project": "codex-agent-system",
        "task": f"failing-task-{i}",
        "result": "FAILURE",
        "score": 0,
    }))
print(json.dumps({
    "project": "codex-agent-system",
    "task": "rare-success",
    "result": "SUCCESS",
    "score": 1,
}))
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-anomaly.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-anomaly.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 2
source_ids = {entry["source_task_id"] for entry in output["data"]["board_tasks"]}
assert source_ids == {"enterprise-readiness"}

reconciled = registry["tasks"][0]
assert reconciled["id"] == "task-stale-running-root"
assert reconciled["status"] == "running"
assert reconciled["execution"]["state"] == "running"

titles = {task["title"] for task in registry["tasks"]}
assert "Tighten the mobile dashboard into an enterprise control surface" in titles
assert "Make active worker ownership and progress explicit in the dashboard" in titles
PY

echo "strategy anomaly seeding test passed"
