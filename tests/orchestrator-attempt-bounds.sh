#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/orchestrator-attempts"

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
      "id": "task-orchestrator-attempts",
      "title": "bounded orchestrator attempt task",
      "project": "orchestrator-attempts",
      "status": "approved",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z",
      "history": []
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${3:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"deterministic planner","data":{"steps":["Implement the bounded change.","Verify the bounded change."]}}
JSON
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${7:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"deterministic coder","data":{"checks":["mock check"]}}
JSON
EOF

cat >"$TEST_ROOT/agents/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
status="approved"
message="deterministic review approval"
if [[ "$output_file" == *"step-1-reviewer-1.json" ]]; then
  status="retry"
  message="first step requires one retry"
fi
cat >"$output_file" <<JSON
{"status":"$status","message":"$message","data":{"step":"mock step","index":1,"kind":"implement","findings":[]}}
JSON
EOF

cat >"$TEST_ROOT/agents/evaluator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
status="success"
message="deterministic evaluation approval"
score="8"
reason="approved"
if [[ "$output_file" == *"step-1-evaluator-1.json" ]]; then
  status="fail"
  message="first step retry requested"
  score="3"
  reason="retry requested"
fi
cat >"$output_file" <<JSON
{"status":"$status","message":"$message","data":{"step":"mock step","index":1,"kind":"implement","score":$score,"reason":"$reason"}}
JSON
EOF

chmod +x \
  "$TEST_ROOT/agents/planner.sh" \
  "$TEST_ROOT/agents/coder.sh" \
  "$TEST_ROOT/agents/reviewer.sh" \
  "$TEST_ROOT/agents/evaluator.sh"

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "bounded orchestrator attempt task" \
    "task-orchestrator-attempts" >/dev/null
)

python3 - "$TEST_ROOT/codex-memory/tasks.log" "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
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
assert record["result"] == "SUCCESS"
assert record["attempts"] == 2
assert record["total_step_attempts"] == 3

payload = json.loads(Path(sys.argv[2]).read_text())
task = payload["tasks"][0]
execution = task["execution_context"]
assert execution["result"] == "SUCCESS"
assert execution["attempts"] == 2
assert execution["total_step_attempts"] == 3
assert "failure_context" not in task
PY

echo "orchestrator attempt bounds test passed"
