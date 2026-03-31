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
  "$TEST_ROOT/workspaces/superheld/packages/playbooks" \
  "$TEST_ROOT/workspaces/superheld/apps/web" \
  "$TEST_ROOT/workspaces/superheld/.codex-agent"

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
  "spec_file": "$TEST_ROOT/projects/superheld/spec.md",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Milestone Seeds
```json
{
  "seeds": [
    {
      "milestone": "Satisfied seed.",
      "title": "Align credential recovery trigger coverage in account recovery playbook",
      "category": "code",
      "target_file": "packages/playbooks/account_recovery_after_credential_risk.json",
      "done_markers": [
        "credential_recovery_trigger"
      ],
      "reason_template": "Start with `{target_file}`."
    },
    {
      "milestone": "Next seed.",
      "title": "Define incident state contract in web dashboard blueprint",
      "category": "learning",
      "target_file": "apps/web/README.md",
      "done_markers": [
        "## Incident State Contract"
      ],
      "reason_template": "Start with `{target_file}`."
    }
  ]
}
```
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "trigger_event_types": [
    "credential_recovery_trigger"
  ]
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/apps/web/README.md" <<'EOF'
# Web

## Core Cards

- incident summary
EOF

cat >"$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-resolved-seed",
      "title": "Align credential recovery trigger coverage in account recovery playbook",
      "execution_task": "[self-improve:medium] Align credential recovery trigger coverage in account recovery playbook",
      "project": "superheld",
      "status": "pending_approval",
      "score": 4.6,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "self_improvement",
      "target_files": ["packages/playbooks/account_recovery_after_credential_risk.json"],
      "task_intent": {
        "source": "self-improve",
        "objective": "Align credential recovery trigger coverage in account recovery playbook",
        "project": "superheld",
        "category": "code",
        "affected_files": ["packages/playbooks/account_recovery_after_credential_risk.json"]
      }
    },
    {
      "id": "task-next-seed",
      "title": "Define incident state contract in web dashboard blueprint",
      "execution_task": "[self-improve:medium] Define incident state contract in web dashboard blueprint",
      "project": "superheld",
      "status": "pending_approval",
      "score": 4.0,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "self_improvement",
      "target_files": ["apps/web/README.md"],
      "task_intent": {
        "source": "self-improve",
        "objective": "Define incident state contract in web dashboard blueprint",
        "project": "superheld",
        "category": "learning",
        "affected_files": ["apps/web/README.md"]
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
  "pending_approval_tasks": 2,
  "approved_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 2
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

resolved_status="$(
  jq -r '.tasks[] | select(.id == "task-resolved-seed") | .status' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
resolved_reason="$(
  jq -r '.tasks[] | select(.id == "task-resolved-seed") | .shelved_reason' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
next_status="$(
  jq -r '.tasks[] | select(.id == "task-next-seed") | .status' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
queue_contents="$(
  tr -d '\r' <"$TEST_ROOT/queues/superheld.txt"
)"

if [ "$resolved_status" != "shelved" ]; then
  echo "expected resolved structured seed to be shelved, got: $resolved_status" >&2
  exit 1
fi

if [[ "$resolved_reason" != auto-shelved:\ structured\ spec\ seed\ markers\ already\ present* ]]; then
  echo "expected structured seed shelve reason, got: $resolved_reason" >&2
  exit 1
fi

if [ "$next_status" != "approved" ]; then
  echo "expected next unresolved seed to auto-approve, got: $next_status" >&2
  exit 1
fi

if [ "$queue_contents" != "[self-improve:medium] Define incident state contract in web dashboard blueprint" ]; then
  echo "expected next unresolved seed to be queued, got: $queue_contents" >&2
  exit 1
fi

if [[ "$auto_result" != AUTO_APPROVED:* ]]; then
  echo "expected AUTO_APPROVED output, got: $auto_result" >&2
  exit 1
fi

echo "strategy auto approve external resolved structured seed shelve test passed"
