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
}

write_recent_timeout_window() {
  local repo_root="$1"
  python3 - "$repo_root/codex-logs/system.log" "$repo_root/codex-logs/strategy-timeout-cooldown.state" <<'PY'
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys

system_log_path = Path(sys.argv[1])
state_path = Path(sys.argv[2])
now = datetime.now(timezone.utc)
markers = [
    (now - timedelta(minutes=4)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    (now - timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    (now - timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
]

system_log_path.write_text(
    "\n".join(
        f"[{marker}] [queue-worker] ERROR: Task timed out after 600s on lane-{index + 1} for superheld"
        for index, marker in enumerate(markers)
    )
    + "\n",
    encoding="utf-8",
)
state_path.write_text(f"last_timeout_marker={markers[-1]}\n", encoding="utf-8")
PY
}

run_once() {
  local repo_root="$1"
  (
    cd "$repo_root"
    bash scripts/strategy-loop.sh --once codex-agent-system >/dev/null
  )
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T11:05:00Z","project":"codex-agent-system","task":"Prior successful task","task_id":"prior-success","result":"SUCCESS","attempts":1,"score":7}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.42,
  "total_tasks": 1,
  "approved_tasks": 0,
  "retry_churn_detected": false,
  "loop_effort_detected": false,
  "pipeline_stale": false
}
EOF

write_recent_timeout_window "$REPO_ROOT"
printf '%s\n' "0" >"$REPO_ROOT/codex-logs/strategy-timeout-cooldown"

run_once "$REPO_ROOT"

if [ -f "$REPO_ROOT/codex-logs/strategy-timeout-cooldown" ]; then
  echo "expected expired timeout cooldown to stay cleared when no newer timeout evidence exists" >&2
  exit 1
fi

if ! grep -q "Recent timeout window unchanged since last cooldown trigger" "$REPO_ROOT/codex-logs/system.log"; then
  echo "expected strategy loop to log unchanged timeout window recovery message" >&2
  exit 1
fi

if [ ! -f "$REPO_ROOT/strategy-invocations.log" ]; then
  echo "expected strategy run when cooldown evidence is unchanged" >&2
  exit 1
fi

echo "strategy timeout cooldown edge trigger test passed"
