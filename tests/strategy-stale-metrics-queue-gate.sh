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
}

write_metrics() {
  local repo_root="$1"
  local approved_tasks="$2"
  cat >"$repo_root/codex-learning/metrics.json" <<EOF
{
  "success_rate": 0.12,
  "approved_tasks": $approved_tasks
}
EOF
}

write_registry() {
  local repo_root="$1"
  local approved_count="$2"
  python3 - "$repo_root/codex-memory/tasks.json" "$approved_count" <<'PY'
import json
import sys

path = sys.argv[1]
approved_count = int(sys.argv[2])
tasks = []
for index in range(approved_count):
    tasks.append(
        {
            "id": f"task-{index + 1:03d}",
            "title": f"Approved task {index + 1}",
            "project": "codex-agent-system",
            "status": "approved",
            "updated_at": f"2026-03-24T22:00:{index:02d}Z",
        }
    )

with open(path, "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
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

REPO_STALE="$TMP_DIR/repo-stale"
make_repo "$REPO_STALE"
write_metrics "$REPO_STALE" 90
write_registry "$REPO_STALE" 3
run_once "$REPO_STALE"

if [ ! -f "$REPO_STALE/strategy-invocations.log" ]; then
  echo "expected strategy run when only metrics backlog is stale" >&2
  exit 1
fi

if grep -q "Queue gate active" "$REPO_STALE/codex-logs/system.log"; then
  echo "queue gate should not activate from stale approved-task metrics" >&2
  exit 1
fi

REPO_STALE_FLAGS="$TMP_DIR/repo-stale-flags"
make_repo "$REPO_STALE_FLAGS"
cat >"$REPO_STALE_FLAGS/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "approved_tasks": 111,
  "task_registry_total": 171,
  "task_registry_payload_bytes": 891142,
  "task_registry_pressure_detected": true,
  "strategy_saturation_detected": true
}
EOF
write_registry "$REPO_STALE_FLAGS" 3
run_once "$REPO_STALE_FLAGS"

if [ ! -f "$REPO_STALE_FLAGS/strategy-invocations.log" ]; then
  echo "expected strategy run when registry pressure and saturation metrics are stale" >&2
  exit 1
fi

if grep -q "Queue gate active" "$REPO_STALE_FLAGS/codex-logs/system.log"; then
  echo "queue gate should not activate from stale registry pressure or saturation metrics" >&2
  exit 1
fi

python3 - "$REPO_STALE_FLAGS/codex-learning/metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["approved_tasks"] == 3, metrics
assert metrics["task_registry_total"] == 3, metrics
assert metrics["task_registry_payload_bytes"] < 512000, metrics
assert metrics["task_registry_pressure_detected"] is False, metrics
assert metrics["strategy_saturation_detected"] is False, metrics
PY

REPO_LIVE="$TMP_DIR/repo-live"
make_repo "$REPO_LIVE"
write_metrics "$REPO_LIVE" 0
write_registry "$REPO_LIVE" 10
run_once "$REPO_LIVE"

if [ -f "$REPO_LIVE/strategy-invocations.log" ]; then
  echo "expected live approved backlog to block strategy run" >&2
  exit 1
fi

if ! grep -q "Queue gate active: success_rate=0 queue_size=10 pressure=false saturation=false source=task_registry" "$REPO_LIVE/codex-logs/system.log"; then
  echo "expected queue gate log to reflect live task-registry source" >&2
  exit 1
fi

echo "strategy stale metrics queue gate test passed"
