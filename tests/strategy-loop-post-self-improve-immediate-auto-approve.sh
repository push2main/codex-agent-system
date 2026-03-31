#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/agents" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/projects/superheld" \
  "$REPO_ROOT/queues" \
  "$EXTERNAL_WORKSPACE/.codex-agent" \
  "$EXTERNAL_WORKSPACE/packages/schema"

cp "$ROOT_DIR/scripts/lib.sh" "$REPO_ROOT/scripts/lib.sh"
cp "$ROOT_DIR/scripts/strategy-loop.sh" "$REPO_ROOT/scripts/strategy-loop.sh"
cp "$ROOT_DIR/scripts/strategy-auto-approve.py" "$REPO_ROOT/scripts/strategy-auto-approve.py"
cp "$ROOT_DIR/scripts/strategy-approved-queue-sync.py" "$REPO_ROOT/scripts/strategy-approved-queue-sync.py"
cp "$ROOT_DIR/scripts/strategy-timeout-snapshot.py" "$REPO_ROOT/scripts/strategy-timeout-snapshot.py"
cp "$ROOT_DIR/scripts/strategy-chronic-tasks.py" "$REPO_ROOT/scripts/strategy-chronic-tasks.py"
cp "$ROOT_DIR/scripts/sync-task-artifacts.py" "$REPO_ROOT/scripts/sync-task-artifacts.py"
cp "$ROOT_DIR/scripts/task_metrics.py" "$REPO_ROOT/scripts/task_metrics.py"

cat >"$REPO_ROOT/scripts/compact-registry.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

cat >"$REPO_ROOT/scripts/self-improve.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

project_name="${1:-codex-agent-system}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
registry_path="$ROOT_DIR/../superheld-repo/.codex-agent/tasks.json"
target_path="$ROOT_DIR/../superheld-repo/packages/schema/incident.schema.json"

if [ "$project_name" != "superheld" ]; then
  exit 0
fi

python3 - "$registry_path" "$target_path" <<'PY'
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

registry_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

task = {
    "id": "task-seeded-during-strategy-loop",
    "title": "[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum",
    "execution_task": "[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum",
    "project": "superheld",
    "status": "pending_approval",
    "score": 4.8,
    "created_at": now,
    "updated_at": now,
    "strategy_template": "self_improvement",
    "target_files": [target_path.relative_to(target_path.parents[2]).as_posix()],
    "task_intent": {
        "source": "self-improve",
        "objective": "Align incident status enum with dashboard contract",
        "project": "superheld",
        "category": "code",
        "affected_files": [target_path.relative_to(target_path.parents[2]).as_posix()],
    },
    "task_shape": {
        "approval_ready": True,
        "manual_review_required": False,
        "editable_files": [target_path.relative_to(target_path.parents[2]).as_posix()],
        "frozen_files": [],
        "verification_command": "bash scripts/verify-baseline.sh",
    },
}

registry = {"tasks": [task]}
registry_path.write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")
PY
EOF

cat >"$REPO_ROOT/agents/strategy.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
project_name="${1:-}"
output_file="${2:-}"
cat >"$output_file" <<JSON
{
  "status": "success",
  "data": {
    "project": "$project_name",
    "board_tasks": []
  }
}
JSON
EOF

chmod +x \
  "$REPO_ROOT/scripts/compact-registry.sh" \
  "$REPO_ROOT/scripts/self-improve.sh" \
  "$REPO_ROOT/agents/strategy.sh"

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "policy_file": "$REPO_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

cat >"$REPO_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "title": "Incident schema fixture"
}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pipeline_stale": false,
  "pipeline_stale_since": null,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-30T22:20:00Z","project":"superheld","task":"Prior success","task_id":"task-prior-success","result":"SUCCESS","attempts":1,"score":5}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/strategy-loop.sh --once superheld >/dev/null
)

python3 - "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" "$REPO_ROOT/queues/superheld.txt" "$REPO_ROOT/codex-logs/system.log" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = registry["tasks"][0]
assert task["status"] == "approved", task
assert task["history"][-1]["action"] == "auto_approve_stale_pipeline", task["history"][-1]

queue_lines = [
    line.strip()
    for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert queue_lines == [
    "[self-improve:high] Align incident status enum with dashboard contract -- Start with packages/schema/incident.schema.json at the status enum"
], queue_lines

log_text = Path(sys.argv[3]).read_text(encoding="utf-8")
assert "Post self-improve auto-approval: AUTO_APPROVED:" in log_text, log_text
PY

echo "strategy loop post self-improve immediate auto approve test passed"
