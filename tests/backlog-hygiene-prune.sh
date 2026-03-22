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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-malformed-approved",
      "title": "Analyze itself and connected projects 2",
      "project": "codex-agent-system",
      "status": "approved",
      "prompt_intake": {
        "source": "dashboard_prompt_intake",
        "prompt_excerpt": "You are a senior AI systems engineer.\n1. Analyze itself and connected projects.\n2. Identify weaknesses and opportunities.\n3. Generate improvement tasks.",
        "index": 2,
        "total": 4
      },
      "history": []
    },
    {
      "id": "task-existing-artifact",
      "title": "Add `codex-learning/provider-routing.json` with learned routing policy",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "history": []
    },
    {
      "id": "task-valid",
      "title": "Add visible queue lane badges to the dashboard",
      "project": "codex-agent-system",
      "status": "approved",
      "history": []
    }
  ]
}
EOF

mkdir -p "$TEST_ROOT/codex-learning"
cat >"$TEST_ROOT/codex-learning/provider-routing.json" <<'EOF'
{
  "providers": []
}
EOF

cat >"$TEST_ROOT/queues/codex-agent-system.txt" <<'EOF'
Analyze itself and connected projects 2
Add `codex-learning/provider-routing.json` with learned routing policy
Add visible queue lane badges to the dashboard
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  prune_invalid_actionable_registry_tasks
) >"$TMP_DIR/pruned.txt"

grep -q $'codex-agent-system\tAnalyze itself and connected projects 2\tPrompt-intake task still contains numbered-list spillover from the source prompt.' "$TMP_DIR/pruned.txt"
grep -q $'codex-agent-system\tAdd `codex-learning/provider-routing.json` with learned routing policy\tTarget artifact already exists at codex-learning/provider-routing.json.' "$TMP_DIR/pruned.txt"

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/queues/codex-agent-system.txt" <<'PY'
import json
import sys
from pathlib import Path

registry_path = Path(sys.argv[1])
queue_path = Path(sys.argv[2])
payload = json.loads(registry_path.read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in payload["tasks"]}

assert tasks["task-malformed-approved"]["status"] == "rejected"
assert tasks["task-existing-artifact"]["status"] == "rejected"
assert tasks["task-valid"]["status"] == "approved"
assert tasks["task-malformed-approved"]["history"][-1]["action"] == "reject"
assert "backlog hygiene" in tasks["task-malformed-approved"]["history"][-1]["note"]
assert tasks["task-existing-artifact"]["history"][-1]["action"] == "reject"

queue_lines = [line.strip() for line in queue_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert queue_lines == ["Add visible queue lane badges to the dashboard"]
PY

echo "backlog hygiene prune test passed"
