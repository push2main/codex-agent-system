#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/step-length"
OUTPUT_FILE="$TMP_DIR/plan.json"
MOCK_BIN="$TMP_DIR/bin"
MARKER_FILE="$TMP_DIR/provider-invoked"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$MOCK_BIN"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-step-len",
      "title": "add helper function to lib.sh",
      "project": "step-length",
      "status": "approved",
      "effort": 2,
      "created_at": "2026-03-29T09:00:00Z",
      "updated_at": "2026-03-29T09:00:00Z"
    }
  ]
}
EOF

cat >"$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'invoked\n' >>"${PLANNER_PROVIDER_MARKER:?}"
output_file=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ] && [ "$#" -ge 2 ]; then
    output_file="$2"
    shift 2
    continue
  fi
  shift
done
[ -n "$output_file" ] || exit 2

python3 - "$output_file" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
long_step = (
    "In `scripts/lib.sh`, extend the helper selection path so the planner keeps a single-file scope, "
    "names the exact existing anchor before edits, preserves the current verification path, avoids any new "
    "files, and keeps the implementation bounded to one narrow function or branch while documenting the same "
    "expectation in the step text for the coder. "
    "In `scripts/lib.sh`, extend the helper selection path so the planner keeps a single-file scope, names "
    "the exact existing anchor before edits, preserves the current verification path, avoids any new files, "
    "and keeps the implementation bounded to one narrow function or branch while documenting the same "
    "expectation in the step text for the coder. "
    "In `scripts/lib.sh`, extend the helper selection path so the planner keeps a single-file scope, names "
    "the exact existing anchor before edits, preserves the current verification path, avoids any new files, "
    "and keeps the implementation bounded to one narrow function or branch while documenting the same "
    "expectation in the step text for the coder."
)
payload = {
    "status": "success",
    "message": "mock planner plan",
    "data": {
        "steps": [
            long_step,
            "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome.",
        ]
    },
}
output_path.write_text(json.dumps(payload), encoding="utf-8")
PY
EOF
chmod +x "$MOCK_BIN/codex"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  CLAUDE_DISABLE=1 \
  PLANNER_PROVIDER_MARKER="$MARKER_FILE" \
  TASK_ID="task-step-len" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" \
    "$PROJECT_DIR" \
    "add helper function to lib.sh" \
    "$OUTPUT_FILE" >/dev/null
)

[ -e "$MARKER_FILE" ]

python3 - "$OUTPUT_FILE" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["status"] == "success"
assert payload["message"] == "mock planner plan"
steps = payload["data"]["steps"]
assert len(steps) == 2
assert all(len(step) <= 600 for step in steps), steps
assert "scripts/lib.sh" in steps[0]
assert steps[1] == "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."
PY

echo "planner step length limit test passed"
