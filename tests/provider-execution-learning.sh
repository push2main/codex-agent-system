#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project-learning"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$MOCK_BIN" "$PROJECT_DIR"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues" "$TEST_ROOT/codex-dashboard"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-parent-failed",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "project-learning",
      "status": "failed",
      "execution_provider": "codex",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "updated_at": "2026-03-23T10:58:43Z",
      "created_at": "2026-03-23T10:55:00Z",
      "execution_context": {
        "provider": "codex",
        "result": "FAILURE",
        "score": 0,
        "failed_step": "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history.",
        "updated_at": "2026-03-23T10:58:43Z"
      },
      "failure_context": {
        "provider": "codex",
        "result": "FAILURE",
        "score": 0,
        "failed_step": "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history.",
        "updated_at": "2026-03-23T10:58:43Z"
      }
    },
    {
      "id": "task-parent-failed-repeat",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "project-learning",
      "status": "failed",
      "execution_provider": "codex",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "updated_at": "2026-03-23T11:02:43Z",
      "created_at": "2026-03-23T11:00:00Z",
      "execution_context": {
        "provider": "codex",
        "result": "FAILURE",
        "score": 1,
        "failed_step": "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history.",
        "updated_at": "2026-03-23T11:02:43Z"
      },
      "failure_context": {
        "provider": "codex",
        "result": "FAILURE",
        "score": 1,
        "failed_step": "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history.",
        "updated_at": "2026-03-23T11:02:43Z"
      }
    },
    {
      "id": "task-child-approved",
      "title": "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history",
      "project": "project-learning",
      "status": "approved",
      "execution_provider": "codex",
      "provider_selection": {
        "selected": "codex",
        "source": "default",
        "reason": "Default provider is Codex when no explicit Claude hint is present."
      },
      "source_task_id": "task-parent-failed",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "updated_at": "2026-03-23T11:05:00Z",
      "created_at": "2026-03-23T11:04:00Z",
      "task_intent": {
        "objective": "Feed execution learning back into future provider and task decisions"
      }
    }
  ]
}
EOF

cat >"$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >>"$TMP_DIR/claude.invoked"
printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"status":"success","message":"claude execution learning route","data":{}}}\n'
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
{"status":"success","message":"codex fallback","data":{}}
JSON
EOF

chmod +x "$MOCK_BIN/claude" "$MOCK_BIN/codex"

export PATH="$MOCK_BIN:$PATH"
export TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json"

source "$TEST_ROOT/scripts/lib.sh"

provider_info="$(resolve_task_provider_info "project-learning" "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history")"
[ "$(printf '%s\n' "$provider_info" | sed -n '1p')" = "claude" ]
[ "$(printf '%s\n' "$provider_info" | sed -n '3p')" = "execution_learning" ]
printf '%s\n' "$provider_info" | sed -n '2p' | grep -q "matching failure"

OUTPUT_FILE="$TMP_DIR/output.json"
run_agent_exec planner "$PROJECT_DIR" "Apply the smallest safe patch in the existing learning/selection path so future provider routing and task shaping deterministically consume execution-learning signals from persisted history" "Return deterministic JSON." "$OUTPUT_FILE"
[ "$(current_exec_provider)" = "claude" ]
jq -e '.message == "claude execution learning route"' "$OUTPUT_FILE" >/dev/null
[ -f "$TMP_DIR/claude.invoked" ]
[ ! -f "$TMP_DIR/codex.invoked" ]

echo "provider execution learning test passed"
