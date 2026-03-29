#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/finalize-exit"
OUTPUT_FILE="$TMP_DIR/orchestrator.out"

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
  "$TEST_ROOT/projects" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${3:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"Create a deterministic test artifact.","data":{"steps":["Step 1: In `.env`, add `TOKEN=test` so the commit guard sees a staged sensitive path. Expected: `.env` exists with deterministic test content.","Step 2 (verify): Run `test -f .env` and confirm the file exists. Expected: `.env` is present after the implementation step."]}}
JSON
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="${1:-}"
step_file="${3:-}"
output_file="${7:-}"
step_text="$(jq -r '.text // ""' "$step_file")"
if printf '%s' "$step_text" | grep -q 'Step 1:'; then
  printf 'TOKEN=test\n' >"$project_dir/.env"
fi
cat >"$output_file" <<'JSON'
{"status":"success","message":"Applied the requested deterministic step.","data":{"summary":"Created the expected test artifact."}}
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
cat >"$PROJECT_DIR/README.md" <<'EOF'
fixture
EOF
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Test User' -c user.email='test@example.com' commit -q -m 'initial'

set +e
(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  CLAUDE_DISABLE=1 \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "Force a finalize-stage commit rejection after successful steps" \
    "task-finalize-exit"
) >"$OUTPUT_FILE" 2>&1
status=$?
set -e

if [ "$status" -ne 1 ]; then
  echo "expected orchestrator to exit 1 after finalize_run flipped the result to failure, got $status" >&2
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

assert summary["result"] == "FAILURE", summary
assert summary["completed_steps"] == "2", summary
assert summary["failure_kind"] == "", summary
assert "Task execution succeeded but git commit automation failed" in stdout_text, stdout_text
PY

echo "orchestrator finalize failure exit-code test passed"
