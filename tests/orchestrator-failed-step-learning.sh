#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-dashboard-ownership",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "history": [],
      "task_intent": {
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "context_hint": "Surface one additional deterministic live-work ownership signal without changing queue semantics.",
        "constraints": [
          "Keep the change scoped to the dashboard read path.",
          "Do not change queue execution behavior."
        ],
        "affected_files": [
          "codex-dashboard/server.js",
          "codex-dashboard/index.html"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      }
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-memory/decisions.md"
: >"$TEST_ROOT/codex-learning/rules.md"
: >"$TEST_ROOT/codex-learning/prompt-rules.md"

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${3:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"deterministic planner","data":{"steps":["Implement the requested change with minimal modifications."]}}
JSON
EOF

chmod +x "$TEST_ROOT/agents/planner.sh"

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "Make active worker ownership and progress explicit in the dashboard" \
    "task-dashboard-ownership" >/dev/null || true
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]
execution = task["execution_context"]
failure = task["failure_context"]

expected = (
    "In `codex-dashboard/server.js`, `codex-dashboard/index.html`, implement the smallest safe change for: "
    "Make active worker ownership and progress explicit in the dashboard. Focus on Surface one additional deterministic "
    "live-work ownership signal without changing queue semantics. Keep these constraints: Keep the change scoped to "
    "the dashboard read path; Do not change queue execution behavior."
)

assert execution["result"] == "FAILURE"
assert execution["failure_kind"] == "evaluation_failure"
assert failure["failed_step"] == expected
assert failure["failure_kind"] == "evaluation_failure"
assert execution["failed_step"] == expected
assert failure["failed_step"] != "Implement the requested change with minimal modifications."
assert task["last_failure_kind"] == "evaluation_failure"
PY

python3 - "$TEST_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys
from pathlib import Path

records = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text().splitlines()
    if line.strip()
]
assert len(records) == 1
record = records[0]

expected = (
    "In `codex-dashboard/server.js`, `codex-dashboard/index.html`, implement the smallest safe change for: "
    "Make active worker ownership and progress explicit in the dashboard. Focus on Surface one additional deterministic "
    "live-work ownership signal without changing queue semantics. Keep these constraints: Keep the change scoped to "
    "the dashboard read path; Do not change queue execution behavior."
)

assert record["result"] == "FAILURE"
assert record["failure_kind"] == "evaluation_failure"
assert record["failed_step_index"] == 1
assert record["failed_step"] == expected
PY

echo "orchestrator failed step learning test passed"
