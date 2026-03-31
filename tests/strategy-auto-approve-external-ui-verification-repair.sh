#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/projects/superheld" \
  "$TEST_ROOT/workspaces/superheld/.codex-agent" \
  "$TEST_ROOT/workspaces/superheld/scripts" \
  "$TEST_ROOT/workspaces/superheld/apps/web"

created_at_90s_ago="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$TEST_ROOT/workspaces/superheld",
  "repo_url": "https://example.invalid/superheld",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
echo "baseline verification passed"
EOF
chmod +x "$TEST_ROOT/workspaces/superheld/scripts/verify-baseline.sh"

cat >"$TEST_ROOT/workspaces/superheld/apps/web/README.md" <<'EOF'
# Web

## Core Cards

- incident summary
EOF

cat >"$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-web-contract",
      "title": "Define incident state contract in web dashboard blueprint",
      "execution_task": "[self-improve:medium] Define incident state contract in web dashboard blueprint",
      "project": "superheld",
      "status": "pending_approval",
      "score": 4.2,
      "category": "ui",
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "self_improvement",
      "target_files": ["apps/web/README.md"],
      "task_intent": {
        "source": "self-improve",
        "objective": "Define incident state contract in web dashboard blueprint",
        "project": "superheld",
        "category": "ui",
        "context_hint": "Start with apps/web/README.md after ## Core Cards.",
        "affected_files": ["apps/web/README.md"]
      },
      "task_shape": {
        "approval_ready": true,
        "requires_split": false,
        "manual_review_required": false,
        "risk_profile": "high",
        "editable_files": ["apps/web/README.md"],
        "frozen_files": [],
        "verification_command": "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh",
        "updated_at": "__CREATED_AT_90S_AGO__"
      }
    }
  ]
}
EOF

python3 - "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" "$created_at_90s_ago" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
created_at = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("__CREATED_AT_90S_AGO__", created_at), encoding="utf-8")
PY

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pipeline_stale": false,
  "pipeline_stale_since": null,
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 1
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

auto_result="$(
  cd "$TEST_ROOT" &&
    python3 scripts/strategy-auto-approve.py \
      workspaces/superheld/.codex-agent/tasks.json \
      codex-learning/metrics.json \
      codex-memory/tasks.log
)"

status="$(
  jq -r '.tasks[] | select(.id == "task-web-contract") | .status' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
verification_command="$(
  jq -r '.tasks[] | select(.id == "task-web-contract") | .task_shape.verification_command' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
history_action="$(
  jq -r '.tasks[] | select(.id == "task-web-contract") | .history[0].action' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
queue_contents="$(
  tr -d '\r' <"$TEST_ROOT/queues/superheld.txt"
)"

if [ "$status" != "approved" ]; then
  echo "expected repaired task to auto-approve, got: $status" >&2
  exit 1
fi

if [ "$verification_command" != "bash scripts/verify-baseline.sh" ]; then
  echo "expected repaired verification command, got: $verification_command" >&2
  exit 1
fi

if [ "$history_action" != "auto_repair_verification_command" ]; then
  echo "expected verification repair history action, got: $history_action" >&2
  exit 1
fi

if [ "$queue_contents" != "[self-improve:medium] Define incident state contract in web dashboard blueprint" ]; then
  echo "expected repaired task to be queued, got: $queue_contents" >&2
  exit 1
fi

if [[ "$auto_result" != AUTO_APPROVED:* ]]; then
  echo "expected AUTO_APPROVED output, got: $auto_result" >&2
  exit 1
fi

echo "strategy auto approve external ui verification repair test passed"
