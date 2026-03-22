#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TASKS_FILE="$TMP_DIR/tasks.json"
MOCK_BIN="$TMP_DIR/bin"
PROJECT_CLAUDE="$TMP_DIR/project-claude"
PROJECT_CODEX="$TMP_DIR/project-codex"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN" "$PROJECT_CLAUDE" "$PROJECT_CODEX"

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-provider-claude",
      "title": "Use Claude for provider routing",
      "project": "project-claude",
      "status": "approved",
      "execution_provider": "claude",
      "provider_selection": {
        "selected": "claude",
        "source": "input",
        "reason": "Provider was selected explicitly from the task payload: claude."
      },
      "updated_at": "2026-03-22T18:00:00Z",
      "created_at": "2026-03-22T17:59:00Z"
    },
    {
      "id": "task-provider-codex",
      "title": "Generic provider routing task",
      "project": "project-codex",
      "status": "approved",
      "updated_at": "2026-03-22T18:00:00Z",
      "created_at": "2026-03-22T17:59:00Z"
    }
  ]
}
EOF

cat >"$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >>"$TMP_DIR/claude.invoked"
case "\${CLAUDE_MOCK_MODE:-success}" in
  success)
    printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"status":"success","message":"claude mock","data":{}}}\n'
    ;;
  auth_fail)
    printf '%s\n' 'Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired. Please obtain a new token or refresh your existing token."}}' >&2
    exit 1
    ;;
  *)
    printf '%s\n' 'unexpected CLAUDE_MOCK_MODE' >&2
    exit 2
    ;;
esac
EOF

cat >"$MOCK_BIN/codex" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >>"$TMP_DIR/codex.invoked"
output_file=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      output_file="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "\$output_file" ] || exit 2
cat >"\$output_file" <<'JSON'
{"status":"success","message":"codex mock","data":{}}
JSON
EOF

chmod +x "$MOCK_BIN/claude" "$MOCK_BIN/codex"

export TASK_REGISTRY_FILE="$TASKS_FILE"
export PATH="$MOCK_BIN:$PATH"
source "$ROOT_DIR/scripts/lib.sh"

CLAUDE_OUTPUT="$TMP_DIR/claude-output.json"
CLAUDE_MOCK_MODE=success run_agent_exec planner "$PROJECT_CLAUDE" "Use Claude for provider routing" "Return deterministic JSON." "$CLAUDE_OUTPUT"
[ "$(current_exec_provider)" = "claude" ]
jq -e '.status == "success" and .message == "claude mock"' "$CLAUDE_OUTPUT" >/dev/null
[ -f "$TMP_DIR/claude.invoked" ]
[ ! -f "$TMP_DIR/codex.invoked" ]

rm -f "$TMP_DIR/claude.invoked" "$TMP_DIR/codex.invoked"
CODEX_OUTPUT="$TMP_DIR/codex-output.json"
run_agent_exec planner "$PROJECT_CODEX" "Generic provider routing task" "Return deterministic JSON." "$CODEX_OUTPUT"
[ "$(current_exec_provider)" = "codex" ]
jq -e '.status == "success" and .message == "codex mock"' "$CODEX_OUTPUT" >/dev/null
[ -f "$TMP_DIR/codex.invoked" ]
[ ! -f "$TMP_DIR/claude.invoked" ]

rm -f "$TMP_DIR/claude.invoked" "$TMP_DIR/codex.invoked" "$CLAUDE_OUTPUT"
if CLAUDE_MOCK_MODE=auth_fail run_agent_exec planner "$PROJECT_CLAUDE" "Use Claude for provider routing" "Return deterministic JSON." "$CLAUDE_OUTPUT"; then
  echo "expected Claude auth failure to abort provider dispatch" >&2
  exit 1
fi
provider_exec_requires_abort
[ "$(current_exec_provider)" = "claude" ]
printf '%s' "$(provider_exec_failure_reason)" | grep -Eq 'Failed to authenticate|OAuth token has expired'

echo "provider routing test passed"
