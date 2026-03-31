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
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent" \
  "$EXTERNAL_WORKSPACE/packages/schema" \
  "$EXTERNAL_WORKSPACE/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

created_at_90s_ago="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform.

## First Milestones

17. Add verification gates so `bash scripts/verify-baseline.sh` guards the dashboard status, payload, and approval-state schema fields.
EOF

cat >"$REPO_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "spec_file": "$REPO_ROOT/projects/superheld/spec.md",
  "policy_file": "$REPO_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "required": [
    "incident_id",
    "status",
    "approval_state",
    "learning_path"
  ],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["open", "pending_approval", "resolved"]
    },
    "approval_state": {
      "type": "string",
      "enum": ["pending", "approved", "denied", "postponed"]
    },
    "learning_path": {
      "type": "string",
      "minLength": 1
    }
  }
}
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

require_query() {
  :
}

require_query '.properties.status.enum | index("pending_approval")' \
  "packages/schema/incident.schema.json" \
  "dashboard incident status contract is missing"
require_query '.properties.approval_state.enum | index("postponed")' \
  "packages/schema/incident.schema.json" \
  "dashboard incident approval-state contract is missing"
require_query '. as $schema | ($schema.properties.status.type == "string") and ($schema.properties.approval_state.type == "string")' \
  "packages/schema/incident.schema.json" \
  "dashboard incident payload contract check is missing"
require_query '.properties.learning_path.type == "string"' \
  "packages/schema/incident.schema.json" \
  "dashboard incident payload fields are missing or not required"
EOF
chmod +x "$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh"

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-064",
      "title": "Add baseline verification for dashboard payload contract fields",
      "execution_task": "[self-improve:high] Add baseline verification for dashboard payload contract fields",
      "project": "superheld",
      "status": "failed",
      "score": 4.3,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "failed_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "self_improvement",
      "target_files": ["scripts/verify-baseline.sh"],
      "last_failure_kind": "missing_source_file",
      "task_intent": {
        "source": "self-improve",
        "objective": "Add baseline verification for dashboard payload contract fields",
        "project": "superheld",
        "category": "stability",
        "affected_files": ["scripts/verify-baseline.sh"]
      }
    }
  ]
}
EOF

python3 - "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" "$created_at_90s_ago" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
created_at = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("__CREATED_AT_90S_AGO__", created_at), encoding="utf-8")
PY

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pipeline_stale": false,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 1
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

generator_output="$(
  python3 "$REPO_ROOT/scripts/generate-milestone-seeds.py" --root "$REPO_ROOT" superheld --write
)"

printf '%s\n' "$generator_output" | jq -e '
  .status == "success" and
  .data.seed_count == 1 and
  (.data.unresolved_milestones | length) == 0
' >/dev/null

grep -Fq '"title": "Add baseline verification for dashboard payload contract fields"' "$REPO_ROOT/projects/superheld/spec.md"
grep -Fq 'dashboard incident payload contract check is missing' "$REPO_ROOT/projects/superheld/spec.md"
grep -Fq '"verification_command": "bash scripts/verify-baseline.sh"' "$REPO_ROOT/projects/superheld/spec.md"

(
  cd "$REPO_ROOT"
  python3 scripts/strategy-auto-approve.py \
    "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" \
    codex-learning/metrics.json \
    codex-memory/tasks.log >/dev/null
)

resolved_status="$(
  jq -r '.tasks[] | select(.id == "task-064") | .status' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
resolved_reason="$(
  jq -r '.tasks[] | select(.id == "task-064") | .shelved_reason' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if [ "$resolved_status" != "shelved" ]; then
  echo "expected verify-baseline seed task to be shelved once generated markers match, got: $resolved_status" >&2
  exit 1
fi

if [[ "$resolved_reason" != auto-shelved:\ structured\ spec\ seed\ markers\ already\ present\ in\ scripts/verify-baseline.sh* ]]; then
  echo "expected resolved verify-baseline seed to be auto-shelved, got: $resolved_reason" >&2
  exit 1
fi

echo "generate milestone seeds dashboard verify-baseline guards test passed"
