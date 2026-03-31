#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/project"
OUTPUT_FILE="$TMP_DIR/orchestrator.out"
ARTIFACT_PATH="codex-memory/self-improve-inventory-add-credential-recovery-trigger-coverage-to-telemetry-event-sche.md"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/agents/planner.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="\${3:-}"
cat >"\$output_file" <<'JSON'
{"status":"success","message":"Create a deterministic inventory artifact.","data":{"steps":["Step 1: In \`$ARTIFACT_PATH\`, write a compact inventory note describing the exact existing telemetry schema anchor for credential recovery trigger coverage. Expected: the file exists with deterministic markdown content.","Step 2 (verify): Run \`test -s $ARTIFACT_PATH\` and confirm the exact pass/fail outcome."]}}
JSON
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="\${1:-}"
step_file="\${3:-}"
output_file="\${7:-}"
step_text="\$(jq -r '.text // ""' "\$step_file")"
if printf '%s' "\$step_text" | grep -q 'Step 1:'; then
  mkdir -p "\$project_dir/codex-memory"
  cat >"\$project_dir/$ARTIFACT_PATH" <<'MARKDOWN'
# Inventory

- Primary file: \`packages/schema/telemetry-event.schema.json\`
- Anchor: root \`examples\` array
MARKDOWN
fi
cat >"\$output_file" <<'JSON'
{"status":"success","message":"Applied the requested deterministic step.","data":{"summary":"Created the expected inventory artifact."}}
JSON
EOF

cat >"$TEST_ROOT/agents/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
cat >"$output_file" <<'JSON'
{"status":"approved","message":"Review approved.","data":{"findings":[]}}
JSON
EOF

cat >"$TEST_ROOT/agents/evaluator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"Evaluation passed.","data":{"score":8}}
JSON
EOF

chmod +x \
  "$TEST_ROOT/agents/planner.sh" \
  "$TEST_ROOT/agents/coder.sh" \
  "$TEST_ROOT/agents/reviewer.sh" \
  "$TEST_ROOT/agents/evaluator.sh"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" checkout -q -b main
git -C "$PROJECT_DIR" config user.name 'Test User'
git -C "$PROJECT_DIR" config user.email 'test@example.com'
cat >"$PROJECT_DIR/README.md" <<'EOF'
fixture
EOF
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" commit -q -m 'initial'

set +e
(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  CLAUDE_DISABLE=1 \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "Write inventory artifact for credential recovery trigger coverage" \
    "task-inventory-success"
) >"$OUTPUT_FILE" 2>&1
status=$?
set -e

if [ "$status" -ne 0 ]; then
  echo "expected orchestrator to exit 0, got $status" >&2
  cat "$OUTPUT_FILE" >&2 || true
  exit 1
fi

latest_run_dir="$(find "$TEST_ROOT/codex-logs/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
if [ -z "$latest_run_dir" ]; then
  echo "expected orchestrator run directory to be created" >&2
  exit 1
fi

python3 - "$latest_run_dir/result.txt" "$OUTPUT_FILE" <<'PY'
import sys
from pathlib import Path

summary = {}
for raw_line in Path(sys.argv[1]).read_text().splitlines():
    line = raw_line.strip()
    if not line or "=" not in line:
        continue
    key, value = line.split("=", 1)
    summary[key] = value

stdout_text = Path(sys.argv[2]).read_text()

assert summary["result"] == "SUCCESS", summary
assert summary["completed_steps"] == "2", summary
assert "Task execution succeeded but git commit automation failed" not in stdout_text, stdout_text
PY

git -C "$PROJECT_DIR" ls-tree -r --name-only HEAD | grep -Fqx "$ARTIFACT_PATH"

echo "orchestrator inventory artifact credential commit test passed"
