#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$ROOT_DIR/scripts" "$target/scripts"
  cp -R "$ROOT_DIR/agents" "$target/agents"
  mkdir -p "$target/codex-memory" "$target/codex-learning" "$target/codex-logs" "$target/queues" "$target/projects"
  cat >"$target/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": {
      "weight": 1.8,
      "success_rate": 0.76
    },
    "ui": {
      "weight": 1.35,
      "success_rate": 0.81
    },
    "performance": {
      "weight": 1.1,
      "success_rate": 0.7
    },
    "code_quality": {
      "weight": 1.05,
      "success_rate": 0.79
    }
  }
}
EOF
  : >"$target/codex-memory/tasks.log"
}

ACTIVE_ROOT_REPO="$TMP_DIR/active-root"
make_repo "$ACTIVE_ROOT_REPO"
cat >"$ACTIVE_ROOT_REPO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-root-stability",
      "title": "Strengthen queue recovery semantics",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 4,
      "confidence": 0.82,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-root-stability-child-pending",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "status": "pending_approval",
      "created_at": "2026-03-23T08:06:00Z",
      "updated_at": "2026-03-23T08:06:00Z",
      "source_task_id": "task-root-stability",
      "root_source_task_id": "task-root-stability",
      "original_failed_root_id": "task-root-stability",
      "strategy_template": "structured_failure_context"
    },
    {
      "id": "task-unrelated-approved-one",
      "title": "Keep queue runtime state visible",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "approved",
      "created_at": "2026-03-23T08:06:00Z",
      "updated_at": "2026-03-23T08:06:00Z"
    },
    {
      "id": "task-unrelated-running-two",
      "title": "Keep dashboard status panel aligned",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "running",
      "created_at": "2026-03-23T08:06:00Z",
      "updated_at": "2026-03-23T08:06:00Z"
    }
  ]
}
EOF

(
  cd "$ACTIVE_ROOT_REPO"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-root-active.json" >/dev/null
)

python3 - "$ACTIVE_ROOT_REPO" "$TMP_DIR/strategy-root-active.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
output = json.loads(Path(sys.argv[2]).read_text())
registry = json.loads((root / "codex-memory" / "tasks.json").read_text())

assert output["status"] == "success"
assert output["data"]["board_tasks"][0] == {
    "id": "task-root-stability-child-pending",
    "action": "updated",
    "source_task_id": "task-root-stability",
}
assert output["data"]["board_tasks"][1]["action"] == "created"
assert output["data"]["board_tasks"][1]["source_task_id"] == "enterprise-readiness"
assert len(registry["tasks"]) == 5
PY

CAPPED_ROOT_REPO="$TMP_DIR/capped-root"
make_repo "$CAPPED_ROOT_REPO"
cat >"$CAPPED_ROOT_REPO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-root-chain",
      "title": "Persist stable runtime restart signals",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 4,
      "confidence": 0.82,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-root-chain-child-1",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "status": "failed",
      "created_at": "2026-03-23T08:06:00Z",
      "updated_at": "2026-03-23T08:07:00Z",
      "source_task_id": "task-root-chain",
      "root_source_task_id": "task-root-chain",
      "original_failed_root_id": "task-root-chain",
      "strategy_template": "structured_failure_context"
    },
    {
      "id": "task-root-chain-child-2",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "status": "failed",
      "created_at": "2026-03-23T08:08:00Z",
      "updated_at": "2026-03-23T08:09:00Z",
      "source_task_id": "task-root-chain",
      "root_source_task_id": "task-root-chain",
      "original_failed_root_id": "task-root-chain",
      "strategy_template": "structured_failure_context"
    },
    {
      "id": "task-unrelated-approved-three",
      "title": "Keep queue lanes visible",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "approved",
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:10:00Z"
    },
    {
      "id": "task-unrelated-running-four",
      "title": "Keep dashboard learning status visible",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "running",
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:10:00Z"
    },
    {
      "id": "task-unrelated-approved-five",
      "title": "Keep runtime approval state visible",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "approved",
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:10:00Z"
    }
  ]
}
EOF

(
  cd "$CAPPED_ROOT_REPO"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-root-capped.json" >/dev/null
)

python3 - "$CAPPED_ROOT_REPO" "$TMP_DIR/strategy-root-capped.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
output = json.loads(Path(sys.argv[2]).read_text())
registry = json.loads((root / "codex-memory" / "tasks.json").read_text())

assert output["status"] == "success"
assert output["data"]["board_tasks"] == [
    {
        "id": "task-001-tighten-the-mobile-dashboard-into-an-ent",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    }
]
assert len(registry["tasks"]) == 7
PY

echo "strategy root dedupe test passed"
