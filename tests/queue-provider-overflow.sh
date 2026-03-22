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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-default-ui",
      "title": "Tighten mobile dashboard spacing",
      "project": "provider-smoke",
      "status": "approved",
      "category": "ui",
      "effort": 2,
      "confidence": 0.82,
      "execution_provider": "codex",
      "provider_selection": {
        "selected": "codex",
        "source": "default",
        "reason": "Default provider is Codex when no explicit Claude hint is present."
      }
    },
    {
      "id": "task-manual-stability",
      "title": "Persist restart-needed runtime state when helper scripts change",
      "project": "provider-smoke",
      "status": "approved",
      "category": "stability",
      "effort": 2,
      "confidence": 0.9,
      "execution_provider": "codex",
      "provider_selection": {
        "selected": "codex",
        "source": "manual_assessment",
        "reason": "Keep this in the current runtime path."
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  lane_two="$(select_queue_provider_for_lane "provider-smoke" "Tighten mobile dashboard spacing" "lane-2")"
  [ "$(printf '%s\n' "$lane_two" | sed -n '1p')" = "claude" ]
  [ "$(printf '%s\n' "$lane_two" | sed -n '3p')" = "lane_overflow" ]

  lane_three="$(select_queue_provider_for_lane "provider-smoke" "Tighten mobile dashboard spacing" "lane-3")"
  [ "$(printf '%s\n' "$lane_three" | sed -n '1p')" = "claude" ]
  [ "$(printf '%s\n' "$lane_three" | sed -n '3p')" = "lane_overflow" ]

  lane_one="$(select_queue_provider_for_lane "provider-smoke" "Tighten mobile dashboard spacing" "lane-1")"
  [ "$(printf '%s\n' "$lane_one" | sed -n '1p')" = "codex" ]

  manual_task="$(select_queue_provider_for_lane "provider-smoke" "Persist restart-needed runtime state when helper scripts change" "lane-3")"
  [ "$(printf '%s\n' "$manual_task" | sed -n '1p')" = "codex" ]
  [ "$(printf '%s\n' "$manual_task" | sed -n '3p')" = "manual_assessment" ]
)

echo "queue provider overflow test passed"
