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
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/bin" "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REPO_ROOT/bin/codex"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

python3 - "$REPO_ROOT/codex-logs/system.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("w", encoding="utf-8") as handle:
    for offset in range(20):
        handle.write(
            f"[2026-03-30T00:00:{offset:02d}Z] [self-improve] WARN: Repeated error pattern detected (200 times): claude print failed\n"
        )
PY

(
  cd "$REPO_ROOT"
  PATH="$REPO_ROOT/bin:$PATH" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

approval_mode="$(
  (
    cd "$REPO_ROOT"
    bash -lc 'source scripts/lib.sh; codex_approval_mode'
  )
)"
if [ "$approval_mode" != "on-request" ]; then
  echo "expected codex_approval_mode helper to return on-request" >&2
  exit 1
fi

if rg -q 'Invalid codex approval flag|Provider health check found issues' "$REPO_ROOT/codex-logs/system.log"; then
  echo "expected provider health check to use lib helper without false approval-flag errors" >&2
  exit 1
fi

echo "self improve provider health check test passed"
