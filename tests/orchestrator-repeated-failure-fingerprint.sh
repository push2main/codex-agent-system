#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/orchestrator-repeat-failure"

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
      "id": "task-repeat-failure",
      "title": "repeat failure fingerprint task",
      "project": "orchestrator-repeat-failure",
      "status": "approved",
      "created_at": "2026-03-24T10:00:00Z",
      "updated_at": "2026-03-24T10:00:00Z",
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
{"status":"success","message":"deterministic planner","data":{"steps":["Run the deterministic verification command."]}}
JSON
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${7:-}"
attempt_label="$(basename "$output_file" .json)"
cat >"$output_file" <<JSON
{"status":"success","message":"coder output for $attempt_label","data":{"summary":"Execute the same deterministic verification command."}}
JSON
EOF

cat >"$TEST_ROOT/agents/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
cat >"$output_file" <<'JSON'
{"status":"retry","message":"verification still failing","data":{"step":"Execute the same deterministic verification command.","index":1,"kind":"verify","findings":[]}}
JSON
EOF

cat >"$TEST_ROOT/agents/evaluator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
cat >"$output_file" <<'JSON'
{"status":"fail","message":"verification command failed","data":{"step":"Execute the same deterministic verification command.","index":1,"kind":"verify","score":0,"reason":"verification command still fails the same way"}}
JSON
EOF

chmod +x \
  "$TEST_ROOT/agents/planner.sh" \
  "$TEST_ROOT/agents/coder.sh" \
  "$TEST_ROOT/agents/reviewer.sh" \
  "$TEST_ROOT/agents/evaluator.sh"

if (
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "repeat failure fingerprint task" \
    "task-repeat-failure" >/dev/null
); then
  echo "orchestrator unexpectedly succeeded for repeated failure fingerprint fixture" >&2
  exit 1
fi

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
assert record["result"] == "FAILURE"
assert record["attempts"] == 2
assert record["total_step_attempts"] == 2
assert record["failed_step_index"] == 1
assert record["failed_step"] == "Run the deterministic verification command."

payload = json.loads(Path(sys.argv[2]).read_text())
task = payload["tasks"][0]
execution = task["execution_context"]
failure = task["failure_context"]
assert execution["result"] == "FAILURE"
assert execution["attempts"] == 2
assert execution["total_step_attempts"] == 2
assert failure["failed_step_index"] == 1
assert failure["failed_step"] == "Run the deterministic verification command."
PY

if [ -e "$TEST_ROOT/codex-logs"/runs/*/step-1-coder-3.json ]; then
  echo "expected retry loop guard to stop before a third attempt" >&2
  exit 1
fi

echo "orchestrator repeated failure fingerprint test passed"
