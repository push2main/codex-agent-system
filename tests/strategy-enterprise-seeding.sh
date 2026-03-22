#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
TMP_DIR_AUTO="$(mktemp -d)"
TEST_ROOT_AUTO="$TMP_DIR_AUTO/repo"

cleanup() {
  rm -rf "$TMP_DIR" "$TMP_DIR_AUTO"
}

trap cleanup EXIT

setup_repo() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$ROOT_DIR/scripts" "$target/scripts"
  cp -R "$ROOT_DIR/agents" "$target/agents"
  mkdir -p "$target/codex-memory" "$target/codex-learning" "$target/codex-logs" "$target/projects" "$target/queues"
  cat >"$target/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
  : >"$target/codex-memory/tasks.log"
}

setup_repo "$TEST_ROOT"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-first.json" >/dev/null
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-second.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-first.json" "$TMP_DIR/strategy-second.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
first_path = sys.argv[2]
second_path = sys.argv[3]

with open(first_path, "r", encoding="utf-8") as handle:
    first = json.load(handle)
with open(second_path, "r", encoding="utf-8") as handle:
    second = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert first["status"] == "success"
assert len(first["data"]["board_tasks"]) == 2
assert second["status"] == "success"
assert len(second["data"]["board_tasks"]) == 1

tasks = registry["tasks"]
assert len(tasks) == 3
assert [task["title"] for task in tasks] == [
    "Tighten the mobile dashboard into an enterprise control surface",
    "Make active worker ownership and progress explicit in the dashboard",
    "Surface security, audit, and governance readiness in the dashboard",
]
assert all(task["status"] == "pending_approval" for task in tasks)
assert all(task["source_task_id"] == "enterprise-readiness::codex-agent-system" for task in tasks)
PY

setup_repo "$TEST_ROOT_AUTO"

cat >"$TEST_ROOT_AUTO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$TEST_ROOT_AUTO/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "auto",
  "updated_at": "2026-03-22T20:45:00Z"
}
EOF

(
  cd "$TEST_ROOT_AUTO"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR_AUTO/strategy-auto.json" >/dev/null
)

python3 - "$TEST_ROOT_AUTO" "$TMP_DIR_AUTO/strategy-auto.json" <<'PY'
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

assert len(registry["tasks"]) == 2
assert all(task["status"] == "approved" for task in registry["tasks"])
assert all(task["queue_handoff"]["status"] == "queued" for task in registry["tasks"])
assert all(task["execution_brief"]["status"] == "queued" for task in registry["tasks"])
assert all(task["execution_provider"] == "codex" for task in registry["tasks"])

with open(os.path.join(root, "queues", "codex-agent-system.txt"), "r", encoding="utf-8") as handle:
    lines = [line.strip() for line in handle if line.strip()]

assert lines == [
    "Tighten the mobile dashboard into an enterprise control surface",
    "Make active worker ownership and progress explicit in the dashboard",
]
PY

echo "strategy enterprise seeding test passed"
