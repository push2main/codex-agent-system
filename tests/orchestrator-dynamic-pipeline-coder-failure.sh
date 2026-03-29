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
      "id": "task-dynamic-pipeline-coder-failure",
      "title": "Inspect queue execution path",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-27T20:00:00Z",
      "updated_at": "2026-03-27T20:00:00Z",
      "history": []
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-learning/rules.md"
: >"$TEST_ROOT/codex-learning/prompt-rules.md"
: >"$TEST_ROOT/codex-memory/decisions.md"

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${3:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"deterministic planner","data":{"steps":["Inspect `scripts/lib.sh` and report the current execution path."]}}
JSON
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${7:-}"
cat >"$output_file" <<'JSON'
{"status":"fail","message":"coder failed unexpectedly.","data":{"role":"coder"}}
JSON
EOF

chmod +x "$TEST_ROOT/agents/planner.sh" "$TEST_ROOT/agents/coder.sh"

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "Inspect queue execution path" \
    "task-dynamic-pipeline-coder-failure" >/dev/null || true
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys
from pathlib import Path

task_payload = json.loads(Path(sys.argv[1]).read_text())
task = task_payload["tasks"][0]
execution = task["execution_context"]
failure = task["failure_context"]

expected_step = "Inspect `scripts/lib.sh` and report the current execution path."

assert execution["result"] == "FAILURE", execution
assert execution["completed_steps"] == 0, execution
assert execution["failed_step_index"] == 1, execution
assert execution["failed_step"] == expected_step, execution
assert failure["failed_step_index"] == 1, failure
assert failure["failed_step"] == expected_step, failure

records = [
    json.loads(line)
    for line in Path(sys.argv[2]).read_text().splitlines()
    if line.strip()
]
assert len(records) == 1, records
record = records[0]
assert record["result"] == "FAILURE", record
assert record["failed_step_index"] == 1, record
assert record["failed_step"] == expected_step, record
assert record["failed_step"] != "plan: Created deterministic fallback plan.", record
PY

echo "orchestrator dynamic pipeline coder failure test passed"
