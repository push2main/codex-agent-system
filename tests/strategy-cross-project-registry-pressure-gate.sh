#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root/scripts" "$repo_root/agents" "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/projects" "$repo_root/queues"
  cp "$ROOT_DIR/scripts/lib.sh" "$repo_root/scripts/lib.sh"
  cp "$ROOT_DIR/scripts/strategy-loop.sh" "$repo_root/scripts/strategy-loop.sh"
  cp "$ROOT_DIR/scripts/sync-task-artifacts.py" "$repo_root/scripts/sync-task-artifacts.py"
  cp "$ROOT_DIR/scripts/task_metrics.py" "$repo_root/scripts/task_metrics.py"

  cat >"$repo_root/scripts/self-improve.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

  cat >"$repo_root/scripts/compact-registry.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

  cat >"$repo_root/agents/strategy.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_name="${1:-}"
output_file="${2:-}"
printf '%s\n' "$project_name" >>"$ROOT_DIR/strategy-invocations.log"
cat >"$output_file" <<'JSON'
{
  "status": "success",
  "data": {
    "board_tasks": []
  }
}
JSON
EOF

  chmod +x "$repo_root/scripts/self-improve.sh" "$repo_root/scripts/compact-registry.sh" "$repo_root/agents/strategy.sh"
  : >"$repo_root/codex-memory/tasks.log"
}

write_small_registry() {
  local registry_path="$1"
  cat >"$registry_path" <<'EOF'
{
  "tasks": []
}
EOF
}

write_large_registry() {
  local registry_path="$1"
  local project_name="$2"
  python3 - "$registry_path" "$project_name" <<'PY'
import json
import sys

path = sys.argv[1]
project_name = sys.argv[2]
payload = {
    "tasks": [
        {
            "id": f"{project_name}-pressure-task",
            "title": f"{project_name} registry pressure seed",
            "project": project_name,
            "status": "failed",
            "updated_at": "2026-03-25T11:00:00Z",
            "notes": "x" * 620000,
        }
    ]
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

run_once() {
  local repo_root="$1"
  (
    cd "$repo_root"
    bash scripts/strategy-loop.sh --once codex-agent-system >/dev/null
  )
}

REPO_CROSS="$TMP_DIR/repo-cross-project"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"
make_repo "$REPO_CROSS"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent" "$REPO_CROSS/projects/superheld"
write_small_registry "$REPO_CROSS/codex-memory/tasks.json"
write_large_registry "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" "superheld"

cat >"$REPO_CROSS/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

cat >"$REPO_CROSS/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "approved_tasks": 0
}
EOF

run_once "$REPO_CROSS"

if [ ! -f "$REPO_CROSS/strategy-invocations.log" ]; then
  echo "expected strategy run when registry pressure is dominated by another project" >&2
  exit 1
fi

if grep -q "Queue gate active" "$REPO_CROSS/codex-logs/system.log"; then
  echo "queue gate should not activate for cross-project registry pressure" >&2
  exit 1
fi

if ! grep -q "Ignoring shared registry pressure for codex-agent-system" "$REPO_CROSS/codex-logs/system.log"; then
  echo "expected strategy loop to log cross-project registry pressure suppression" >&2
  exit 1
fi

REPO_LOCAL="$TMP_DIR/repo-local-pressure"
make_repo "$REPO_LOCAL"
write_large_registry "$REPO_LOCAL/codex-memory/tasks.json" "codex-agent-system"

cat >"$REPO_LOCAL/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "approved_tasks": 0
}
EOF

run_once "$REPO_LOCAL"

if [ -f "$REPO_LOCAL/strategy-invocations.log" ]; then
  echo "expected local registry pressure to keep strategy gated" >&2
  exit 1
fi

if ! grep -q "Queue gate active: success_rate=0 queue_size=0 pressure=true" "$REPO_LOCAL/codex-logs/system.log"; then
  echo "expected queue gate to stay active for local registry pressure" >&2
  exit 1
fi

if ! grep -q "pressure_reason=local_registry_pressure" "$REPO_LOCAL/codex-logs/system.log"; then
  echo "expected queue gate log to surface local registry pressure reason" >&2
  exit 1
fi

echo "strategy cross-project registry pressure gate test passed"
