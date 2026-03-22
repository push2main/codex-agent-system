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
      "project": "provider-balance-smoke",
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
      "id": "task-manual-learning",
      "title": "Learn task priority from real outcomes and predicted confidence drift",
      "project": "provider-balance-smoke",
      "status": "approved",
      "category": "learning",
      "effort": 3,
      "confidence": 0.86,
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

  balanced="$(select_balanced_queue_provider_info "provider-balance-smoke" "Tighten mobile dashboard spacing" "codex" "Default provider is Codex" "default" "1" "0")"
  [ "$(printf '%s\n' "$balanced" | sed -n '1p')" = "claude" ]
  [ "$(printf '%s\n' "$balanced" | sed -n '3p')" = "load_balance_overflow" ]

  unchanged="$(select_balanced_queue_provider_info "provider-balance-smoke" "Tighten mobile dashboard spacing" "codex" "Default provider is Codex" "default" "0" "1")"
  [ "$(printf '%s\n' "$unchanged" | sed -n '1p')" = "codex" ]

  manual="$(select_balanced_queue_provider_info "provider-balance-smoke" "Learn task priority from real outcomes and predicted confidence drift" "codex" "Keep this in the current runtime path." "manual_assessment" "1" "0")"
  [ "$(printf '%s\n' "$manual" | sed -n '1p')" = "codex" ]
  [ "$(printf '%s\n' "$manual" | sed -n '3p')" = "manual_assessment" ]
)

echo "queue provider balance test passed"
