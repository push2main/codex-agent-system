#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project-failover"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$REPO_ROOT" "$MOCK_BIN" "$PROJECT_DIR"
cp -R "$ROOT_DIR/scripts" "$REPO_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$REPO_ROOT/agents"
mkdir -p "$REPO_ROOT/codex-memory" "$REPO_ROOT/codex-learning" "$REPO_ROOT/codex-logs" "$REPO_ROOT/projects" "$REPO_ROOT/queues" "$REPO_ROOT/codex-dashboard"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-provider-failover",
      "title": "Create hello world shell script",
      "project": "project-failover",
      "status": "approved",
      "updated_at": "2026-03-28T01:00:00Z",
      "created_at": "2026-03-28T00:59:00Z",
      "task_intent": {
        "objective": "Create hello world shell script"
      }
    }
  ]
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

cat >"$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$TMP_DIR/codex.invoked"
exit 1
EOF

cat >"$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$TMP_DIR/claude.invoked"
prompt="$*"

if printf '%s' "$prompt" | grep -q "You are a planner agent"; then
  payload='{"status":"success","message":"planner ok","data":{"steps":["Step 1: In hello.sh, write a shell script that prints Hello, World!. Expected: the file exists and echoes the greeting.","Step 2 (verify): Run `bash hello.sh` and confirm it prints Hello, World!."]}}'
elif printf '%s' "$prompt" | grep -q "You are a coder agent"; then
  payload='{"status":"success","message":"coder ok","data":{"step":"Step 1: In hello.sh, write a shell script that prints Hello, World!. Expected: the file exists and echoes the greeting.","index":1,"kind":"implement","summary":"Prepared implementation.","files":["hello.sh"],"checks":["bash -n hello.sh"],"changed":true}}'
elif printf '%s' "$prompt" | grep -q "You are the reviewer agent"; then
  payload='{"status":"approved","message":"review ok","data":{"step":"Step 1: In hello.sh, write a shell script that prints Hello, World!. Expected: the file exists and echoes the greeting.","index":1,"kind":"implement","findings":[]}}'
elif printf '%s' "$prompt" | grep -q "You are the evaluator agent"; then
  payload='{"status":"success","message":"evaluation ok","data":{"step":"Step 1: In hello.sh, write a shell script that prints Hello, World!. Expected: the file exists and echoes the greeting.","index":1,"kind":"implement","score":8,"reason":"Looks good."}}'
else
  payload='{"status":"success","message":"default ok","data":{}}'
fi

printf '{"type":"result","subtype":"success","is_error":false,"structured_output":%s}\n' "$payload"
EOF

chmod +x "$MOCK_BIN/codex" "$MOCK_BIN/claude"

export TMP_DIR
export PATH="$MOCK_BIN:$PATH"
export TASK_REGISTRY_FILE="$REPO_ROOT/codex-memory/tasks.json"
export TASK_LOG="$REPO_ROOT/codex-memory/tasks.log"

(
  cd "$REPO_ROOT"
  bash agents/orchestrator.sh "$PROJECT_DIR" "Create hello world shell script" >/dev/null || true
)

[ -f "$TMP_DIR/codex.invoked" ]
[ -f "$TMP_DIR/claude.invoked" ]

last_provider="$(
  python3 - "$REPO_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys

provider = ""
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        provider = json.loads(line).get("provider", "")
print(provider)
PY
)"
if [ "$last_provider" != "claude" ]; then
  echo "expected task log to persist claude after failover, got: $last_provider" >&2
  exit 1
fi

jq -e '
  (.tasks[] | select(.id == "task-provider-failover")) as $task |
  $task.execution_context.provider == "claude" and
  $task.failure_context.provider == "claude"
' "$REPO_ROOT/codex-memory/tasks.json" >/dev/null

(
  cd "$REPO_ROOT"
  source scripts/lib.sh
  compute_provider_stats
)

jq -e '.claude.general.task_count == 1' "$REPO_ROOT/codex-learning/provider-stats.json" >/dev/null

echo "orchestrator provider failover persistence test passed"
