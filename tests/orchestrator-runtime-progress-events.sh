#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/session-progress"

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
  "$PROJECT_DIR"

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${3:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"deterministic planner","data":{"steps":["Inspect the fixture file for session progress coverage.","Verify the session activity trail stays deterministic."]}}
JSON
cat "$output_file"
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="${1:-}"
step_file="${3:-}"
output_file="${7:-}"
step_text="$(jq -r '.text // ""' "$step_file")"
if printf '%s' "$step_text" | grep -q 'Inspect the fixture file'; then
  printf 'checked\n' >"$project_dir/progress.txt"
fi
cat >"$output_file" <<JSON
{"status":"success","message":"ok","data":{"summary":"completed","changed":true}}
JSON
cat "$output_file"
EOF

cat >"$TEST_ROOT/agents/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
cat >"$output_file" <<'JSON'
{"status":"approved","message":"ok","data":{"findings":[]}}
JSON
cat "$output_file"
EOF

cat >"$TEST_ROOT/agents/evaluator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file="${6:-}"
cat >"$output_file" <<'JSON'
{"status":"success","message":"ok","data":{"score":9,"reason":"deterministic success"}}
JSON
cat "$output_file"
EOF

cat >"$TEST_ROOT/agents/learner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -cn '{status:"success",message:"stub",data:{}}'
EOF

cat >"$TEST_ROOT/agents/safety.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -cn '{status:"success",message:"stub",data:{}}'
EOF

chmod +x "$TEST_ROOT/agents/"*.sh

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" checkout -q -b main
printf 'fixture\n' >"$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Test User' -c user.email='test@example.com' commit -q -m 'initial'

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-session-progress",
      "title": "Track orchestrator session progress events",
      "project": "session-progress",
      "status": "approved",
      "created_at": "2026-04-01T09:00:00Z",
      "updated_at": "2026-04-01T09:00:00Z"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-learning/prompt-rules.md"
: >"$TEST_ROOT/codex-learning/rules.md"
: >"$TEST_ROOT/codex-memory/decisions.md"
: >"$TEST_ROOT/codex-memory/context.md"

(
  cd "$TEST_ROOT"
  NOTIFY_DISABLE=1 \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  TASK_LOG="$TEST_ROOT/codex-memory/tasks.log" \
  RULES_FILE="$TEST_ROOT/codex-learning/rules.md" \
  PROMPT_RULES_FILE="$TEST_ROOT/codex-learning/prompt-rules.md" \
  DECISIONS_FILE="$TEST_ROOT/codex-memory/decisions.md" \
  CONTEXT_FILE="$TEST_ROOT/codex-memory/context.md" \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "Track orchestrator session progress events" \
    "task-session-progress" >/dev/null
)

python3 - "$TEST_ROOT/codex-logs/runtime-sessions/session-progress/task-session-progress.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

assert payload["state"] == "completed"
assert payload["result"] == "SUCCESS"
assert payload["step_count"] == 2
assert payload["completed_steps"] == 2
assert payload["activity_history"][0]["type"] in {"session_complete", "step_success"}
assert any(item["type"] == "step_start" for item in payload["activity_history"])
assert any(item["type"] == "step_success" for item in payload["activity_history"])
assert payload["latest_activity"]["summary"]
PY

echo "orchestrator runtime progress events test passed"
